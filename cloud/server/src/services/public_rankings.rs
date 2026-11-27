use crate::{
    error::{err, ErrorKind, ServiceResult},
    models::PublicQuery,
    services::{
        cache::{get as cache_get, set as cache_set, PUBLIC_RANKINGS_VERSION},
        reports::metric_number,
    },
    state::AppState,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

const REPORT_FILTER: &str = "r.deleted_at IS NULL
    AND EXISTS (SELECT 1 FROM users owner WHERE owner.id=r.owner_id AND NOT owner.disabled
        AND COALESCE(r.ranking_public, owner.public_reports))
    AND COALESCE(r.metadata->>'status', 'success') = 'success'
    AND ($1 = 'latest' OR r.created_at >= date_trunc(NULLIF($1, 'latest'), now(), 'Asia/Shanghai'))
    AND ($2 = '' OR strpos(lower(concat_ws(' ', r.api_domain, r.model, r.prompt_name)), lower($2)) > 0)
    AND ($3 = '' OR r.api_domain = $3)
    AND ($4 = '' OR r.model = $4)";

pub(crate) async fn list(state: &AppState, mut query: PublicQuery) -> ServiceResult<Value> {
    query.period = match query.period.as_str() {
        "" | "latest" => "latest",
        "today" => "day",
        "week" => "week",
        "month" => "month",
        _ => return Err(err(ErrorKind::InvalidInput, "无效的榜单周期")),
    }
    .into();
    let facet = match query.facet.as_str() {
        "" => None,
        "api_domain" => {
            query.api_domain.clear();
            Some("api_domain")
        }
        "model" => {
            query.model.clear();
            Some("model")
        }
        _ => return Err(err(ErrorKind::InvalidInput, "无效的筛选类型")),
    };
    query.search = query.search.trim().chars().take(200).collect();
    query.api_domain = query.api_domain.to_lowercase();
    query.page = query.page.max(0);
    let page_size: i64 = if facet.is_some() { 100 } else { 20 };
    let offset = query
        .page
        .checked_mul(page_size)
        .ok_or_else(|| err(ErrorKind::InvalidInput, "页码超出范围"))?;
    let version = cache_get(state, PUBLIC_RANKINGS_VERSION)
        .await
        .and_then(|value| value.as_u64())
        .unwrap_or(0);
    let date = (Utc::now() + chrono::Duration::hours(8)).date_naive();
    let cache_key = format!("aijiance:public:v5:{version}:{date}:{}", json!(query));
    if let Some(value) = cache_get(state, &cache_key).await {
        return Ok(value);
    }

    let sql = if let Some(column) = facet {
        format!(
            "SELECT r.{column}, count(*) AS test_count
            FROM reports r WHERE {REPORT_FILTER} AND r.{column} <> ''
            GROUP BY r.{column} ORDER BY test_count DESC, r.{column} COLLATE \"C\" ASC
            LIMIT $5 OFFSET $6"
        )
    } else {
        let order = if query.period == "latest" {
            ""
        } else {
            "rt.average_score DESC NULLS LAST,"
        };
        format!("SELECT r.id, r.slug, r.api_domain, r.model, r.prompt_name, r.metadata, r.created_at,
                rt.average_score, rt.rating_count, rc.comment_count
            FROM reports r
            LEFT JOIN LATERAL (SELECT avg(score)::double precision AS average_score, count(*) AS rating_count
                FROM report_ratings WHERE report_id = r.id) rt ON true
            LEFT JOIN LATERAL (SELECT count(*) AS comment_count FROM report_comments WHERE report_id = r.id) rc ON true
            WHERE {REPORT_FILTER} ORDER BY {order} r.created_at DESC, r.id DESC LIMIT $5 OFFSET $6")
    };
    let rows = state
        .connection()
        .await?
        .query(
            &sql,
            &[
                &query.period,
                &query.search,
                &query.api_domain,
                &query.model,
                &(page_size + 1),
                &offset,
            ],
        )
        .await
        .map_err(|error| {
            tracing::error!(%error, "public rankings query failed");
            err(ErrorKind::Internal, "读取公开测试结果失败")
        })?;

    let items: Vec<_> = rows.iter().take(page_size as usize).map(|row| {
        if facet.is_some() { return json!({"name": row.get::<_, String>(0), "count": row.get::<_, i64>(1)}); }
        let metadata = row.get::<_, Value>(5);
        json!({
            "id": row.get::<_, i64>(0), "slug": row.get::<_, String>(1),
            "api_domain": row.get::<_, String>(2), "model": row.get::<_, String>(3),
            "prompt_name": row.get::<_, String>(4), "created_at": row.get::<_, DateTime<Utc>>(6),
            "duration_ms": metric_number(&metadata, "duration_ms"),
            "first_byte_ms": metric_number(&metadata, "first_byte_ms"),
            "ttft_ms": metric_number(&metadata, "ttft_ms"),
            "total_tokens": metric_number(&metadata, "total_tokens"),
            "tokens_per_second": metric_number(&metadata, "tokens_per_second"),
            "average_score": row.get::<_, Option<f64>>(7), "rating_count": row.get::<_, i64>(8),
            "comment_count": row.get::<_, i64>(9),
        })
    }).collect();
    let value = json!({"items": items, "has_more": rows.len() > page_size as usize});
    cache_set(state, &cache_key, &value).await;
    Ok(value)
}
