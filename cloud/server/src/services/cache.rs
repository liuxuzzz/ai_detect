use crate::{
    models::{Claims, DashboardQuery},
    state::AppState,
};
use serde_json::Value;

pub(crate) const PUBLIC_RANKINGS_VERSION: &str = "aijiance:public:v2:version";
const DASHBOARD_VERSION: &str = "aijiance:dashboard:version";

pub async fn get(state: &AppState, key: &str) -> Option<Value> {
    let client = state.cache.as_ref()?;
    let mut connection = client.get_multiplexed_async_connection().await.ok()?;
    let raw: Option<String> = redis::cmd("GET")
        .arg(key)
        .query_async(&mut connection)
        .await
        .ok()?;
    serde_json::from_str(&raw?).ok()
}

pub async fn set(state: &AppState, key: &str, value: &Value) {
    if let Some(client) = &state.cache {
        if let Ok(mut connection) = client.get_multiplexed_async_connection().await {
            let _: Result<(), _> = redis::cmd("SETEX")
                .arg(key)
                .arg(20)
                .arg(value.to_string())
                .query_async(&mut connection)
                .await;
        }
    }
}

pub async fn clear(state: &AppState) {
    if let Some(client) = &state.cache {
        if let Ok(mut connection) = client.get_multiplexed_async_connection().await {
            let _: Result<(), _> = redis::cmd("INCR")
                .arg(DASHBOARD_VERSION)
                .query_async(&mut connection)
                .await;
            let _: Result<(), _> = redis::cmd("INCR")
                .arg(PUBLIC_RANKINGS_VERSION)
                .query_async(&mut connection)
                .await;
        }
    }
}

pub async fn dashboard_version(state: &AppState) -> u64 {
    let Some(client) = &state.cache else { return 0 };
    let Ok(mut connection) = client.get_multiplexed_async_connection().await else {
        return 0;
    };
    redis::cmd("GET")
        .arg(DASHBOARD_VERSION)
        .query_async::<Option<u64>>(&mut connection)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

pub fn dashboard_key(claims: &Claims, query: &DashboardQuery, version: u64) -> String {
    format!(
        "aijiance:dashboard:personal:{version}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}",
        claims.sub,
        query.period,
        query.api_domain,
        query.model,
        query.status,
        query.page,
        query.limit,
        query.min_ttft_ms.unwrap_or(-1.0),
        query.max_ttft_ms.unwrap_or(-1.0),
        query.min_tps.unwrap_or(-1.0),
        query.max_tps.unwrap_or(-1.0),
        query.sort
    )
}
