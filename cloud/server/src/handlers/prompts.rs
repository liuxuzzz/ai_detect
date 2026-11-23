use crate::{
    error::{ApiResult, ServiceResult},
    middleware::{Administrator, Authenticated},
    models::{PageQuery, PromptInput},
    services::prompts,
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde_json::Value;

pub(crate) async fn available(
    State(state): State<AppState>,
    _user: Authenticated,
) -> ApiResult<Vec<Value>> {
    prompts::available(&state).await.map(Json)
}
pub(crate) async fn list(
    State(state): State<AppState>,
    _admin: Administrator,
    Query(query): Query<PageQuery>,
) -> ApiResult<Value> {
    prompts::list(&state, query).await.map(Json)
}
pub(crate) async fn create(
    State(state): State<AppState>,
    _admin: Administrator,
    Json(input): Json<PromptInput>,
) -> ApiResult<Value> {
    prompts::save(&state, None, input).await.map(Json)
}
pub(crate) async fn update(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
    Json(input): Json<PromptInput>,
) -> ApiResult<Value> {
    prompts::save(&state, Some(id), input).await.map(Json)
}
pub(crate) async fn delete(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
) -> ServiceResult<StatusCode> {
    prompts::delete(&state, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
