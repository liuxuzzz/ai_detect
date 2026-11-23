use crate::{
    error::ApiResult,
    middleware::Authenticated,
    models::{ChannelTestResult, ModelDiscovery, ModelDiscoveryInput, UpstreamInput},
    services::upstreams,
    state::AppState,
};
use axum::{
    extract::{Path, State},
    Json,
};
use serde_json::Value;

pub(crate) async fn list(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> ApiResult<Vec<Value>> {
    upstreams::list(&state, &claims).await.map(Json)
}

pub(crate) async fn add(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<UpstreamInput>,
) -> ApiResult<Value> {
    upstreams::add(&state, &claims, input).await.map(Json)
}

pub(crate) async fn update(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
    Json(input): Json<UpstreamInput>,
) -> ApiResult<Value> {
    upstreams::update(&state, &claims, id, input)
        .await
        .map(Json)
}

pub(crate) async fn delete(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ApiResult<Value> {
    upstreams::delete(&state, &claims, id).await.map(Json)
}

pub(crate) async fn discover_models(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<ModelDiscoveryInput>,
) -> ApiResult<ModelDiscovery> {
    upstreams::discover_models(&state, &claims, input)
        .await
        .map(Json)
}

pub(crate) async fn sync_models(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ApiResult<Value> {
    upstreams::sync_models(&state, &claims, id).await.map(Json)
}

pub(crate) async fn test_draft(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<ModelDiscoveryInput>,
) -> ApiResult<ChannelTestResult> {
    upstreams::test_draft(&state, &claims, input)
        .await
        .map(Json)
}

pub(crate) async fn test(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ApiResult<ChannelTestResult> {
    upstreams::test(&state, &claims, id).await.map(Json)
}
