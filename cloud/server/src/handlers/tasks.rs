use crate::{
    error::{ApiResult, ServiceResult},
    middleware::Authenticated,
    models::TaskInput,
    services::tasks,
    state::AppState,
};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde_json::Value;

pub(crate) async fn create(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<TaskInput>,
) -> ApiResult<Value> {
    tasks::create(&state, &claims, input).await.map(Json)
}

pub(crate) async fn list(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> ApiResult<Vec<Value>> {
    tasks::list(&state, &claims).await.map(Json)
}

pub(crate) async fn retry(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ApiResult<Value> {
    tasks::retry(&state, &claims, id).await.map(Json)
}

pub(crate) async fn delete(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<StatusCode> {
    tasks::delete(&state, &claims, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
