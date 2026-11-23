use crate::{
    error::{ApiResult, ServiceResult},
    middleware::Administrator,
    models::{PageQuery, TaskControl, UserPatch},
    services::{admin, task_control},
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde_json::Value;

pub(crate) async fn users(
    State(state): State<AppState>,
    _admin: Administrator,
    Query(query): Query<PageQuery>,
) -> ApiResult<Value> {
    admin::users(&state, query).await.map(Json)
}

pub(crate) async fn patch_user(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
    Json(patch): Json<UserPatch>,
) -> ApiResult<Value> {
    admin::patch_user(&state, id, patch).await.map(Json)
}

pub(crate) async fn reports(
    State(state): State<AppState>,
    _admin: Administrator,
    Query(query): Query<PageQuery>,
) -> ApiResult<Value> {
    admin::reports(&state, query).await.map(Json)
}

pub(crate) async fn delete_report(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
) -> ApiResult<Value> {
    admin::delete_report(&state, id).await.map(Json)
}

pub(crate) async fn tasks(
    State(state): State<AppState>,
    _admin: Administrator,
    Query(query): Query<PageQuery>,
) -> ApiResult<Value> {
    admin::tasks(&state, query).await.map(Json)
}

pub(crate) async fn control_task(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
    Json(input): Json<TaskControl>,
) -> ApiResult<Value> {
    task_control::control(&state, id, input.action)
        .await
        .map(Json)
}

pub(crate) async fn delete_task(
    State(state): State<AppState>,
    _admin: Administrator,
    Path(id): Path<i64>,
) -> ServiceResult<StatusCode> {
    task_control::delete(&state, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
