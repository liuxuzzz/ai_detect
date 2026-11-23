use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{
        CommentInput, PageQuery, RatingInput, RatingResult, ReportDetails, ShareInput, Upload,
    },
    services::{auth::random_token, cache::clear},
    state::AppState,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};

pub(crate) async fn details(
    state: &AppState,
    id: i64,
    user_id: Option<i64>,
) -> ServiceResult<ReportDetails> {
    let row = state
        .connection()
        .await?
        .query_opt(
            "SELECT r.id,r.slug,r.api_domain,r.model,r.prompt_name,r.created_at,r.metadata,r.data,
                (SELECT avg(score)::double precision FROM report_ratings WHERE report_id=r.id),
                (SELECT count(*) FROM report_ratings WHERE report_id=r.id),
                (SELECT score FROM report_ratings WHERE report_id=r.id AND user_id=$2)
         FROM reports r WHERE r.id=$1 AND r.deleted_at IS NULL",
            &[&id, &user_id],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "报告不存在"))?;
    let metadata: Value = row.get(6);
    let data: Value = row.get(7);
    Ok(ReportDetails {
        id: row.get(0),
        slug: row.get(1),
        api_domain: row.get(2),
        model: row.get(3),
        prompt_name: row.get(4),
        created_at: row.get(5),
        metrics: detail_metrics(&metadata),
        data: serde_json::from_value(data).map_err(AppError::internal)?,
        average_score: row.get(8),
        rating_count: row.get(9),
        my_score: row.get(10),
    })
}

pub(crate) async fn add_rating(
    state: &AppState,
    id: i64,
    user_id: i64,
    input: RatingInput,
) -> ServiceResult<RatingResult> {
    if !(1..=5).contains(&input.score) {
        return Err(err(ErrorKind::InvalidInput, "评分必须是 1 到 5 分"));
    }
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    let saved = transaction
        .execute(
            "INSERT INTO report_ratings(report_id,user_id,score)
         SELECT id,$2,$3 FROM reports WHERE id=$1 AND deleted_at IS NULL FOR UPDATE
         ON CONFLICT(report_id,user_id) DO UPDATE SET score=EXCLUDED.score",
            &[&id, &user_id, &input.score],
        )
        .await
        .map_err(AppError::internal)?;
    if saved == 0 {
        return Err(err(ErrorKind::NotFound, "报告不存在"));
    }
    let summary = transaction
        .query_one(
            "SELECT avg(score)::double precision, count(*) FROM report_ratings WHERE report_id=$1",
            &[&id],
        )
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(RatingResult {
        ok: true,
        score: input.score,
        average_score: summary.get(0),
        rating_count: summary.get(1),
    })
}

pub(crate) async fn upload(
    state: &AppState,
    owner: i64,
    mut input: Upload,
) -> ServiceResult<Value> {
    input.data.source = "client".into();
    validate(&input)?;
    let mut db = state.connection().await?;
    let transaction = db.transaction().await.map_err(AppError::internal)?;
    // Serialize uploads per account across all Client Keys and server instances.
    // A shared policy lock makes a saved limit effective for subsequent uploads.
    let policy = transaction.query_one(
        "SELECT upload_limit,upload_window_seconds FROM site_settings WHERE singleton FOR SHARE", &[],
    ).await.map_err(AppError::internal)?;
    let user = transaction
        .query_one(
            "SELECT disabled FROM users WHERE id=$1 FOR UPDATE",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?;
    if user.get::<_, bool>(0) {
        return Err(err(ErrorKind::Forbidden, "账号已禁用"));
    }
    let limit: i64 = policy.get(0);
    let window: i64 = policy.get(1);
    let count: i64 = transaction
        .query_one(
            "SELECT count(*) FROM reports WHERE owner_id=$1
         AND created_at >= clock_timestamp() - ($2::bigint * interval '1 second')
         AND data->>'source' IS DISTINCT FROM 'cloud'",
            &[&owner, &window],
        )
        .await
        .map_err(AppError::internal)?
        .get(0);
    if count >= limit {
        return Err(err(
            ErrorKind::QuotaExceeded,
            format!("上传次数已达上限：每 {window} 秒最多 {limit} 次，请稍后重试"),
        ));
    }
    let row = insert(&transaction, owner, &input)
        .await
        .map_err(AppError::internal)?;
    transaction.commit().await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({
        "id": row.get::<_, i64>(0), "slug": row.get::<_, String>(1),
        "owner_url": super::site_settings::page_url(state,&format!("/r/{}",row.get::<_,String>(1))).await?,
        "created_at": row.get::<_, DateTime<Utc>>(2)
    }))
}

pub(crate) async fn delete(state: &AppState, owner: i64, id: i64) -> ServiceResult<()> {
    let updated = state
        .connection()
        .await?
        .execute(
            "UPDATE reports SET deleted_at=now() WHERE id=$1 AND owner_id=$2 AND deleted_at IS NULL",
            &[&id, &owner],
        )
        .await
        .map_err(AppError::internal)?;
    if updated == 0 {
        return Err(err(ErrorKind::NotFound, "报告不存在"));
    }
    clear(state).await;
    Ok(())
}

pub(crate) async fn insert(
    db: &impl deadpool_postgres::GenericClient,
    owner: i64,
    input: &Upload,
) -> Result<tokio_postgres::Row, tokio_postgres::Error> {
    let slug = random_token(24);
    db.query_one(
        "INSERT INTO reports(owner_id,slug,api_domain,model,prompt_name,metadata,data)
         VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id,slug,created_at",
        &[
            &owner,
            &slug,
            &input.api_domain.to_lowercase(),
            &input.model,
            &input.prompt_name,
            &input.metadata,
            &serde_json::to_value(&input.data).expect("validated report data"),
        ],
    )
    .await
}

pub(crate) async fn create_share(
    state: &AppState,
    owner: i64,
    id: i64,
    input: ShareInput,
) -> ServiceResult<Value> {
    let owned = state
        .connection()
        .await?
        .query_opt(
            "SELECT id FROM reports WHERE id=$1 AND owner_id=$2 AND deleted_at IS NULL",
            &[&id, &owner],
        )
        .await
        .map_err(AppError::internal)?;
    if owned.is_none() {
        return Err(err(ErrorKind::NotFound, "报告不存在"));
    }
    let token = random_token(32);
    state.connection().await?.execute(
        "INSERT INTO shares(report_id,token,expires_at,allowed_domain,allow_any_iframe) VALUES($1,$2,$3,$4,$5)",
        &[&id, &token, &input.expires_at, &input.allowed_domain, &input.allow_any_iframe],
    ).await.map_err(AppError::internal)?;
    Ok(
        json!({"token": token, "url": super::site_settings::page_url(state,&format!("/share/{token}")).await?}),
    )
}

pub(crate) async fn public_comments(
    state: &AppState,
    id: i64,
    query: PageQuery,
) -> ServiceResult<Value> {
    let limit = query.limit.clamp(1, 50);
    let offset = query.page.max(0) * limit;
    let db = state.connection().await?;
    let total: i64 = db
        .query_one(
            "SELECT count(*) FROM report_comments c JOIN reports r ON r.id=c.report_id
         WHERE c.report_id=$1 AND r.deleted_at IS NULL",
            &[&id],
        )
        .await
        .map_err(AppError::internal)?
        .get(0);
    let rows = db.query(
        "SELECT c.id,u.email,c.content,c.created_at FROM report_comments c JOIN users u ON u.id=c.user_id
         JOIN reports r ON r.id=c.report_id WHERE c.report_id=$1 AND r.deleted_at IS NULL
         ORDER BY c.created_at DESC LIMIT $2 OFFSET $3", &[&id, &limit, &offset]
    ).await.map_err(AppError::internal)?;
    Ok(json!({
        "items": rows.iter().map(|row| json!({
            "id": row.get::<_, i64>(0), "email": row.get::<_, String>(1),
            "content": row.get::<_, String>(2), "created_at": row.get::<_, DateTime<Utc>>(3)
        })).collect::<Vec<_>>(),
        "total": total, "page": query.page.max(0), "limit": limit
    }))
}

pub(crate) async fn add_comment(
    state: &AppState,
    user_id: i64,
    id: i64,
    input: CommentInput,
) -> ServiceResult<Value> {
    let content = input.content.trim();
    if content.is_empty() || content.chars().count() > 2000 {
        return Err(err(
            ErrorKind::InvalidInput,
            "评论不能为空且不能超过 2000 字",
        ));
    }
    let db = state.connection().await?;
    if db
        .query_opt(
            "SELECT id FROM reports WHERE id=$1 AND deleted_at IS NULL",
            &[&id],
        )
        .await
        .map_err(AppError::internal)?
        .is_none()
    {
        return Err(err(ErrorKind::NotFound, "报告不存在"));
    }
    let row = db.query_one(
        "INSERT INTO report_comments(report_id,user_id,content) VALUES($1,$2,$3) RETURNING id,created_at",
        &[&id, &user_id, &content]
    ).await.map_err(AppError::internal)?;
    drop(db);
    clear(state).await;
    Ok(json!({"id": row.get::<_, i64>(0), "created_at": row.get::<_, DateTime<Utc>>(1)}))
}

fn validate(input: &Upload) -> ServiceResult<()> {
    if input.data.version != 1 || !input.metadata.is_object() {
        return Err(err(ErrorKind::InvalidInput, "报告数据版本或指标格式无效"));
    }
    if input.model.trim().is_empty() || input.api_domain.trim().is_empty() {
        return Err(err(ErrorKind::InvalidInput, "模型和 API 域名不能为空"));
    }
    let mut previous = -1.0;
    for sample in &input.data.samples {
        if !sample.seconds.is_finite()
            || !sample.tps.is_finite()
            || sample.seconds < 0.0
            || sample.tps < 0.0
            || sample.seconds < previous
        {
            return Err(err(
                ErrorKind::InvalidInput,
                "曲线采样必须按时间排列且为非负数",
            ));
        }
        previous = sample.seconds;
    }
    Ok(())
}

fn detail_metrics(metadata: &Value) -> Map<String, Value> {
    const KEYS: &[&str] = &[
        "ttft_ms",
        "tokens_per_second",
        "total_tokens",
        "input_tokens",
        "output_tokens",
        "rpm",
        "tpm",
        "first_byte_ms",
        "average_latency_ms",
        "tcp_connect_ms",
        "cache_read_tokens",
        "cache_write_tokens",
        "cache_hit_rate",
        "duration_ms",
        "retry_count",
    ];
    KEYS.iter()
        .filter_map(|&key| {
            let number = metric_number(metadata, key)?;
            (number.is_finite() && number >= 0.0 && (key != "first_byte_ms" || number > 0.0))
                .then(|| (key.to_owned(), json!(number)))
        })
        .collect()
}

pub(crate) fn metric_number(metadata: &Value, key: &str) -> Option<f64> {
    metadata
        .get(key)
        .and_then(Value::as_f64)
        .filter(|value| !matches!(key, "ttft_ms" | "tokens_per_second") || *value > 0.0)
}

pub(crate) async fn report(
    state: &AppState,
    slug: String,
    user_id: Option<i64>,
) -> ServiceResult<ReportDetails> {
    let id: i64 = state
        .connection()
        .await?
        .query_opt(
            "SELECT id FROM reports WHERE slug=$1 AND deleted_at IS NULL",
            &[&slug],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "报告不存在"))?
        .get(0);
    details(state, id, user_id).await
}

pub(crate) async fn share(
    state: &AppState,
    token: String,
    user_id: Option<i64>,
) -> ServiceResult<Value> {
    let row = state
        .connection()
        .await?
        .query_opt(
            "SELECT r.id,s.expires_at,s.allow_any_iframe,s.allowed_domain
         FROM shares s JOIN reports r ON r.id=s.report_id
         WHERE s.token=$1 AND r.deleted_at IS NULL",
            &[&token],
        )
        .await
        .map_err(AppError::internal)?
        .ok_or_else(|| err(ErrorKind::NotFound, "分享不存在"))?;
    let expires_at: Option<DateTime<Utc>> = row.get(1);
    if expires_at.is_some_and(|expires| expires < Utc::now()) {
        return Err(err(ErrorKind::Gone, "分享已过期"));
    }
    let report = details(state, row.get(0), user_id).await?;
    Ok(json!({"report": report, "sharing": {
        "expires_at": expires_at, "allow_any_iframe": row.get::<_, bool>(2),
        "allowed_domain": row.get::<_, Option<String>>(3),
    }}))
}
