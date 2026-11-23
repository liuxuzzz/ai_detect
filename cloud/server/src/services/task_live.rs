use crate::{
    error::{err, AppError, ErrorKind, ServiceResult},
    models::Claims,
    state::AppState,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};

pub(crate) async fn snapshot(state: &AppState, claims: &Claims, id: i64) -> ServiceResult<Value> {
    // Recheck viewer permissions on every event, including account disablement and session revocation.
    let row = state.connection().await?.query_opt(
        "SELECT t.id,t.owner_id,t.model,t.reasoning_effort,t.prompt_name,t.status,t.started_at,t.finished_at,
            t.error,t.live,t.attempt,t.scheduled_for,u.name AS channel_name,r.slug
         FROM async_tasks t
         JOIN users viewer ON viewer.id=$2 AND NOT viewer.disabled AND viewer.auth_version=$3
         LEFT JOIN cloud_upstreams u ON u.id=t.upstream_id
         LEFT JOIN reports r ON r.id=t.report_id AND r.deleted_at IS NULL
         WHERE t.id=$1 AND (t.owner_id=viewer.id OR viewer.is_admin)",
        &[&id, &claims.sub, &claims.auth_version],
    ).await.map_err(AppError::internal)?.ok_or_else(|| err(ErrorKind::NotFound, "任务不存在或无权查看"))?;
    let started: Option<DateTime<Utc>> = row.get("started_at");
    let finished: Option<DateTime<Utc>> = row.get("finished_at");
    let elapsed = started.map(|start| {
        (finished.unwrap_or_else(Utc::now) - start)
            .num_milliseconds()
            .max(0)
    });
    Ok(json!({
        "id": row.get::<_, i64>("id"), "owner_id": row.get::<_, i64>("owner_id"),
        "model": row.get::<_, String>("model"), "reasoning_effort": row.get::<_, String>("reasoning_effort"),
        "prompt_name": row.get::<_, Option<String>>("prompt_name"), "status": row.get::<_, String>("status"),
        "started_at": started, "finished_at": finished, "elapsed_ms": elapsed,
        "error": row.get::<_, Option<String>>("error"), "live": row.get::<_, Value>("live"),
        "attempt": row.get::<_, i32>("attempt"), "channel_name": row.get::<_, Option<String>>("channel_name"),
        "scheduled_for": row.get::<_, DateTime<Utc>>("scheduled_for"), "report_slug": row.get::<_, Option<String>>("slug"),
    }))
}
