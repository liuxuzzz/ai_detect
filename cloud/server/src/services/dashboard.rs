use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::{Claims, DashboardQuery},
    services::{
        cache::{dashboard_key, dashboard_version, get, set},
        reports::metric_number,
    },
    state::AppState,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use tokio_postgres::{types::ToSql, Row};

const REPORT_FILTER: &str = "r.deleted_at IS NULL
    AND ($1::bigint IS NULL OR r.owner_id=$1)
    AND ($2='' OR r.api_domain=$2)
    AND ($3='' OR r.model=$3)
    AND ($4='' OR COALESCE(r.metadata->>'status','success')=$4)
    AND ($5::timestamptz IS NULL OR r.created_at >= $5)
    AND ($6::double precision IS NULL OR COALESCE((r.metadata->>'ttft_ms')::double precision,0) >= $6)
    AND ($7::double precision IS NULL OR COALESCE((r.metadata->>'ttft_ms')::double precision,0) <= $7)
    AND ($8::double precision IS NULL OR COALESCE((r.metadata->>'tokens_per_second')::double precision,0) >= $8)
    AND ($9::double precision IS NULL OR COALESCE((r.metadata->>'tokens_per_second')::double precision,0) <= $9)";

pub(crate) async fn dashboard(
    state: &AppState,
    claims: &Claims,
    query: DashboardQuery,
) -> ServiceResult<Value> {
    let key = dashboard_key(claims, &query, dashboard_version(state).await);
    if let Some(value) = get(state, &key).await {
        return Ok(value);
    }
    let limit = query.limit.clamp(1, 100);
    let page = query.page.max(0);
    let offset = page
        .checked_mul(limit)
        .ok_or_else(|| err(ErrorKind::InvalidInput, "页码超出范围"))?;
    let owner = Some(claims.sub);
    let period_start = match query.period.as_str() {
        "today" => Some(Utc::now() - Duration::days(1)),
        "week" => Some(Utc::now() - Duration::days(7)),
        "month" => Some(Utc::now() - Duration::days(30)),
        _ => None,
    };
    let sort = match query.sort.as_str() {
        "tps" => "COALESCE((r.metadata->>'tokens_per_second')::double precision,0) DESC",
        "ttft" => "COALESCE((r.metadata->>'ttft_ms')::double precision,0) ASC",
        "duration" => "COALESCE((r.metadata->>'duration_ms')::double precision,0) ASC",
        _ => "r.created_at DESC",
    };
    let domain = query.api_domain.to_lowercase();
    let filters: [&(dyn ToSql + Sync); 9] = [
        &owner,
        &domain,
        &query.model,
        &query.status,
        &period_start,
        &query.min_ttft_ms,
        &query.max_ttft_ms,
        &query.min_tps,
        &query.max_tps,
    ];
    let db = state.connection().await?;
    let count_sql = format!("SELECT count(*) FROM reports r WHERE {REPORT_FILTER}");
    let total: i64 = db
        .query_one(&count_sql, &filters)
        .await
        .map_err(AppError::internal)?
        .get(0);
    let list_sql = format!(
        "SELECT r.id,r.owner_id,u.email,r.slug,r.api_domain,r.model,r.prompt_name,r.metadata,r.created_at,
            r.ranking_public, COALESCE(r.ranking_public, u.public_reports)
         FROM reports r JOIN users u ON u.id=r.owner_id WHERE {REPORT_FILTER}
         ORDER BY {sort}, r.id DESC LIMIT $10 OFFSET $11",
    );
    let mut params = filters.to_vec();
    params.extend([&limit as &(dyn ToSql + Sync), &offset]);
    let rows = db
        .query(&list_sql, &params)
        .await
        .map_err(AppError::internal)?;
    let items: Vec<Value> = rows
        .iter()
        .map(|row| {
            let metadata = row.get::<_, Value>(7);
            json!({
                "id": row.get::<_, i64>(0), "owner_id": row.get::<_, i64>(1),
                "owner_email": row.get::<_, String>(2), "slug": row.get::<_, String>(3),
                "api_domain": row.get::<_, String>(4), "model": row.get::<_, String>(5),
                "prompt_name": row.get::<_, String>(6), "metadata": metadata,
                "status": metadata.get("status").and_then(Value::as_str).unwrap_or("success"),
                "duration_ms": metric_number(&metadata, "duration_ms"),
                "first_byte_ms": metric_number(&metadata, "first_byte_ms"),
                "ttft_ms": metric_number(&metadata, "ttft_ms"),
                "total_tokens": metric_number(&metadata, "total_tokens"),
                "tokens_per_second": metric_number(&metadata, "tokens_per_second"),
                "created_at": row.get::<_, DateTime<Utc>>(8),
                "ranking_public": row.get::<_, Option<bool>>(9),
                "ranking_enabled": row.get::<_, bool>(10),
            })
        })
        .collect();
    let channel_rows = db
        .query(
            "SELECT api_domain,count(*),max(created_at) FROM reports WHERE deleted_at IS NULL
         AND ($1::bigint IS NULL OR owner_id=$1) GROUP BY api_domain
         ORDER BY count(*) DESC, max(created_at) DESC LIMIT 100",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?;
    let model_rows = db
        .query(
            "SELECT model,count(*),max(created_at) FROM reports WHERE deleted_at IS NULL
         AND ($1::bigint IS NULL OR owner_id=$1) GROUP BY model
         ORDER BY count(*) DESC, max(created_at) DESC LIMIT 100",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?;
    let summary = db
        .query_one(
            "SELECT count(*) FILTER (WHERE created_at >= date_trunc('day',now())),
                count(*) FILTER (WHERE COALESCE(metadata->>'status','success')='success')
         FROM reports WHERE deleted_at IS NULL AND ($1::bigint IS NULL OR owner_id=$1)",
            &[&owner],
        )
        .await
        .map_err(AppError::internal)?;
    let value = json!({
        "summary": {"total": total, "today": summary.get::<_, i64>(0), "success": summary.get::<_, i64>(1)},
        "items": items,
        "total": total,
        "page": page,
        "limit": limit,
        "channels": channel_rows.iter().map(facet).collect::<Vec<_>>(),
        "models": model_rows.iter().map(facet).collect::<Vec<_>>(),
    });
    drop(db);
    set(state, &key, &value).await;
    Ok(value)
}

fn facet(row: &Row) -> Value {
    json!({
        "name": row.get::<_, String>(0),
        "count": row.get::<_, i64>(1),
        "last_test": row.get::<_, DateTime<Utc>>(2),
    })
}
