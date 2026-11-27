use crate::{
    error::{err, ApiResult, AppError, ErrorKind, ServiceResult},
    middleware::{Authenticated, ClientOwner, OptionalUser},
    models::{
        CommentInput, PageQuery, RatingInput, RatingResult, ReportRankingVisibility, ShareInput,
        Upload,
    },
    services::reports,
    state::AppState,
};
use axum::{
    extract::{rejection::JsonRejection, Path, Query, State},
    http::{header, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::Value;

pub(crate) async fn details(
    State(state): State<AppState>,
    OptionalUser(user): OptionalUser,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, AppError> {
    let details = reports::details(&state, id, user.map(|claims| claims.sub)).await?;
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(details),
    ))
}

pub(crate) async fn add_rating(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
    Json(input): Json<RatingInput>,
) -> ApiResult<RatingResult> {
    reports::add_rating(&state, id, claims.sub, input)
        .await
        .map(Json)
}

pub(crate) async fn upload(
    State(state): State<AppState>,
    ClientOwner(owner): ClientOwner,
    input: Result<Json<Upload>, JsonRejection>,
) -> ApiResult<Value> {
    let Json(input) = input.map_err(|_| {
        err(
            ErrorKind::InvalidInput,
            "请上传 version=1 的结构化报告数据；旧客户端需升级后重新上传",
        )
    })?;
    reports::upload(&state, owner, input).await.map(Json)
}

pub(crate) async fn delete(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<StatusCode> {
    reports::delete(&state, claims.sub, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn update_ranking_visibility(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
    Json(visibility): Json<ReportRankingVisibility>,
) -> ApiResult<Value> {
    reports::update_ranking_visibility(&state, claims.sub, id, visibility)
        .await
        .map(Json)
}

pub(crate) async fn create_share(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
    Json(input): Json<ShareInput>,
) -> ApiResult<Value> {
    reports::create_share(&state, claims.sub, id, input)
        .await
        .map(Json)
}

pub(crate) async fn public_comments(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Query(query): Query<PageQuery>,
) -> ApiResult<Value> {
    reports::public_comments(&state, id, query).await.map(Json)
}

pub(crate) async fn add_comment(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
    Json(input): Json<CommentInput>,
) -> ApiResult<Value> {
    reports::add_comment(&state, claims.sub, id, input)
        .await
        .map(Json)
}

pub(crate) async fn report(
    State(state): State<AppState>,
    OptionalUser(user): OptionalUser,
    Path(slug): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let report = reports::report(&state, slug, user.map(|claims| claims.sub)).await?;
    Ok(([(header::CACHE_CONTROL, "private, no-store")], Json(report)))
}

pub(crate) async fn share(
    State(state): State<AppState>,
    OptionalUser(user): OptionalUser,
    Path(token): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let report = reports::share(&state, token, user.map(|claims| claims.sub)).await?;
    Ok(([(header::CACHE_CONTROL, "private, no-store")], Json(report)))
}
