use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{ChannelTestResult, Claims, ModelDiscovery, ModelDiscoveryInput, UpstreamInput},
    services::{cache::clear, upstream_http},
    state::AppState,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashSet, time::Duration};
use tokio::time::timeout;

const MODEL_REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const MODEL_RESPONSE_LIMIT: usize = 2 * 1024 * 1024;

pub(crate) async fn list(state: &AppState, claims: &Claims) -> ServiceResult<Vec<Value>> {
    let owner = (!claims.admin).then_some(claims.sub);
    let rows = state
        .connection()
        .await?
        .query(
            "SELECT id,owner_id,name,base_url,model,prompt,schedule,enabled,created_at,
                description,provider_type,pinned,models,synced_at
         FROM cloud_upstreams WHERE ($1::bigint IS NULL OR owner_id=$1)
         ORDER BY pinned DESC,id DESC",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?;
    Ok(rows.iter().map(|row| json!({
        "id": row.get::<_, i64>(0), "owner_id": row.get::<_, i64>(1), "name": row.get::<_, String>(2),
        "base_url": row.get::<_, String>(3), "model": row.get::<_, String>(4), "prompt": row.get::<_, String>(5),
        "schedule": row.get::<_, Option<String>>(6), "enabled": row.get::<_, bool>(7), "created_at": row.get::<_, DateTime<Utc>>(8),
        "description": row.get::<_, String>(9), "provider_type": row.get::<_, String>(10), "pinned": row.get::<_, bool>(11),
        "models": row.get::<_, Value>(12), "synced_at": row.get::<_, Option<DateTime<Utc>>>(13)
    })).collect())
}

pub(crate) async fn add(
    state: &AppState,
    claims: &Claims,
    mut input: UpstreamInput,
) -> ServiceResult<Value> {
    prepare_input(&mut input)?;
    let models = json!(input.models);
    let row = state.connection().await?.query_one(
        "INSERT INTO cloud_upstreams(owner_id,name,base_url,api_key_ciphertext,model,prompt,schedule,enabled,description,provider_type,pinned,models)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id",
        &[&claims.sub, &input.name, &input.base_url, &input.api_key, &input.model, &input.prompt, &input.schedule, &input.enabled, &input.description, &provider_type(&input), &input.pinned, &models],
    ).await.map_err(AppError::internal)?;
    clear(state).await;
    Ok(json!({"id": row.get::<_, i64>(0)}))
}

pub(crate) async fn update(
    state: &AppState,
    claims: &Claims,
    id: i64,
    mut input: UpstreamInput,
) -> ServiceResult<Value> {
    prepare_input(&mut input)?;
    let owner = (!claims.admin).then_some(claims.sub);
    let models = json!(input.models);
    let saved = saved_channel(state, claims, id).await?;
    if input.api_key.is_empty() {
        check_key_reuse(&saved, &input.base_url)?;
    }
    let updated = state
        .connection()
        .await?
        .execute(
            "UPDATE cloud_upstreams SET name=$1,base_url=$2,
                api_key_ciphertext=CASE WHEN $3='' THEN api_key_ciphertext ELSE $3 END,
                model=$4,prompt=$5,schedule=$6,enabled=$7,description=$8,
                provider_type=$10,pinned=$11,models=$12
         WHERE id=$13 AND ($9::bigint IS NULL OR owner_id=$9) AND base_url=$14",
            &[
                &input.name,
                &input.base_url,
                &input.api_key,
                &input.model,
                &input.prompt,
                &input.schedule,
                &input.enabled,
                &input.description,
                &owner,
                &provider_type(&input),
                &input.pinned,
                &models,
                &id,
                &saved.base_url,
            ],
        )
        .await
        .map_err(AppError::internal)?;
    if updated == 0 {
        return Err(err(ErrorKind::Conflict, "渠道已变更，请刷新后重试"));
    }
    clear(state).await;
    Ok(json!({"ok": true}))
}

pub(crate) async fn delete(state: &AppState, claims: &Claims, id: i64) -> ServiceResult<Value> {
    let owner = (!claims.admin).then_some(claims.sub);
    state
        .connection()
        .await?
        .execute(
            "DELETE FROM cloud_upstreams WHERE id=$1 AND ($2::bigint IS NULL OR owner_id=$2)",
            &[&id, &owner],
        )
        .await
        .map_err(AppError::internal)?;
    clear(state).await;
    Ok(json!({"ok": true}))
}

pub(crate) async fn discover_models(
    state: &AppState,
    claims: &Claims,
    input: ModelDiscoveryInput,
) -> ServiceResult<ModelDiscovery> {
    let (base_url, key) = form_credentials(state, claims, input).await?;
    let models = fetch_models(&base_url, &key).await?;
    Ok(ModelDiscovery { models })
}

async fn form_credentials(
    state: &AppState,
    claims: &Claims,
    input: ModelDiscoveryInput,
) -> ServiceResult<(String, String)> {
    let mut key = input.api_key;
    if let Some(id) = input.channel_id {
        let saved = saved_channel(state, claims, id).await?;
        if key.is_empty() {
            check_key_reuse(&saved, &input.base_url)?;
            key = saved.key;
        }
    }
    Ok((input.base_url, key))
}

pub(crate) async fn sync_models(
    state: &AppState,
    claims: &Claims,
    id: i64,
) -> ServiceResult<Value> {
    let saved = saved_channel(state, claims, id).await?;
    let models = fetch_models(&saved.base_url, &saved.key).await?;
    let value = json!(models);
    let updated = state
        .connection()
        .await?
        .execute(
            "UPDATE cloud_upstreams SET models=$1,model=CASE WHEN model='' THEN $2 ELSE model END,
                synced_at=now() WHERE id=$3 AND base_url=$4 AND api_key_ciphertext=$5",
            &[&value, &models[0], &id, &saved.base_url, &saved.key],
        )
        .await
        .map_err(AppError::internal)?;
    if updated == 0 {
        return Err(err(ErrorKind::Conflict, "渠道已变更，请刷新后重试"));
    }
    clear(state).await;
    Ok(json!({"models": models, "synced_at": Utc::now()}))
}

pub(crate) async fn test_draft(
    state: &AppState,
    claims: &Claims,
    input: ModelDiscoveryInput,
) -> ServiceResult<ChannelTestResult> {
    let (base_url, key) = form_credentials(state, claims, input).await?;
    test_connection(&base_url, &key, String::new()).await
}

pub(crate) async fn test(
    state: &AppState,
    claims: &Claims,
    id: i64,
) -> ServiceResult<ChannelTestResult> {
    let saved = saved_channel(state, claims, id).await?;
    test_connection(&saved.base_url, &saved.key, saved.model).await
}

async fn test_connection(
    base_url: &str,
    key: &str,
    model: String,
) -> ServiceResult<ChannelTestResult> {
    let started = std::time::Instant::now();
    let response = timeout(MODEL_REQUEST_TIMEOUT, models_response(base_url, key))
        .await
        .map_err(|_| err(ErrorKind::Upstream, "渠道连接超时"))??;
    Ok(ChannelTestResult {
        ok: response.status().is_success(),
        status: response.status().as_u16(),
        latency_ms: started.elapsed().as_millis(),
        model,
    })
}

struct SavedChannel {
    base_url: String,
    key: String,
    model: String,
}

async fn saved_channel(state: &AppState, claims: &Claims, id: i64) -> ServiceResult<SavedChannel> {
    let owner = (!claims.admin).then_some(claims.sub);
    let row = state
        .connection()
        .await?
        .query_opt(
            "SELECT base_url,api_key_ciphertext,model FROM cloud_upstreams
         WHERE id=$1 AND ($2::bigint IS NULL OR owner_id=$2)",
            &[&id, &owner],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "渠道不存在"))?;
    Ok(SavedChannel {
        base_url: row.get("base_url"),
        key: row.get("api_key_ciphertext"),
        model: row.get("model"),
    })
}

fn check_key_reuse(saved: &SavedChannel, base_url: &str) -> ServiceResult<()> {
    if !saved.key.is_empty()
        && base_url.trim().trim_end_matches('/') != saved.base_url.trim().trim_end_matches('/')
    {
        return Err(err(
            ErrorKind::InvalidInput,
            "渠道地址已修改，请重新输入 API Key",
        ));
    }
    Ok(())
}

async fn models_response(base_url: &str, key: &str) -> ServiceResult<reqwest::Response> {
    let url = upstream_http::api_endpoint(base_url, "models")
        .map_err(|error| err(ErrorKind::InvalidInput, error.to_string()))?;
    let (client, _) = upstream_http::public_client(&url)
        .await
        .map_err(|error| err(ErrorKind::InvalidInput, error.to_string()))?;
    let mut request = client.get(url);
    if !key.is_empty() {
        request = request.bearer_auth(key);
    }
    request
        .send()
        .await
        .map_err(|_| err(ErrorKind::Upstream, "无法连接上游模型列表接口"))
}

async fn fetch_models(base_url: &str, key: &str) -> ServiceResult<Vec<String>> {
    timeout(MODEL_REQUEST_TIMEOUT, async {
        let mut response = models_response(base_url, key).await?;
        if !response.status().is_success() {
            return Err(err(
                ErrorKind::Upstream,
                format!("模型列表返回 HTTP {}", response.status().as_u16()),
            ));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| err(ErrorKind::Upstream, "无法读取上游模型列表"))?
        {
            if chunk.len() > MODEL_RESPONSE_LIMIT - body.len() {
                return Err(err(ErrorKind::Upstream, "上游模型列表超过大小限制"));
            }
            body.extend_from_slice(&chunk);
        }
        parse_models(&body)
    })
    .await
    .map_err(|_| err(ErrorKind::Upstream, "拉取模型列表超时"))?
}

fn parse_models(body: &[u8]) -> ServiceResult<Vec<String>> {
    #[derive(Deserialize)]
    struct ModelList {
        data: Vec<ModelItem>,
    }

    #[derive(Deserialize)]
    struct ModelItem {
        id: Option<String>,
    }

    let response: ModelList = serde_json::from_slice(body).map_err(|_| {
        err(
            ErrorKind::Upstream,
            "上游接口未返回有效的 OpenAI 兼容模型列表",
        )
    })?;
    let mut models: Vec<_> = response
        .data
        .into_iter()
        .filter_map(|item| item.id)
        .collect();
    normalize_models(&mut models);
    if models.is_empty() {
        return Err(err(ErrorKind::Upstream, "上游接口未返回可用模型"));
    }
    models.sort_unstable();
    Ok(models)
}

fn prepare_input(input: &mut UpstreamInput) -> ServiceResult<()> {
    input.name = input.name.trim().to_owned();
    input.base_url = input.base_url.trim().to_owned();
    input.model = input.model.trim().to_owned();
    if input.name.is_empty() || input.base_url.is_empty() {
        return Err(err(ErrorKind::InvalidInput, "渠道名称和 Base URL 不能为空"));
    }
    normalize_models(&mut input.models);
    if input.models.is_empty() && !input.model.is_empty() {
        input.models.push(input.model.clone());
    } else if let Some(first) = input.models.first() {
        if input.model.is_empty() {
            input.model = first.clone();
        } else if !input.models.contains(&input.model) {
            return Err(err(ErrorKind::InvalidInput, "默认模型必须是已选模型之一"));
        }
    }
    Ok(())
}

fn normalize_models(models: &mut Vec<String>) {
    let mut seen = HashSet::new();
    models.retain_mut(|model| {
        *model = model.trim().to_owned();
        !model.is_empty() && seen.insert(model.clone())
    });
}

fn provider_type(input: &UpstreamInput) -> String {
    if input.provider_type.is_empty() {
        "openai-compatible".to_string()
    } else {
        input.provider_type.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::parse_models;

    #[test]
    fn discovers_distinct_model_ids() {
        let body = br#"{"data":[{"id":"second"},{"id":"first"},{"id":"second"},{"id":" "},{}]}"#;
        assert_eq!(parse_models(body).unwrap(), ["first", "second"]);
        assert!(parse_models(br#"{"error":{"message":"not authorized"}}"#).is_err());
        assert!(parse_models(br#"{"data":[]}"#).is_err());
    }
}
