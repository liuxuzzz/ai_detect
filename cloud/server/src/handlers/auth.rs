use crate::{
    error::{ApiResult, ServiceResult},
    middleware::Authenticated,
    models::{Credentials, PasswordChange, ReportVisibilityUpdate},
    services::{auth, site_settings},
    state::AppState,
};
use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::Value;

pub(crate) async fn register(
    State(state): State<AppState>,
    Json(credentials): Json<Credentials>,
) -> ApiResult<Value> {
    auth::register(&state, credentials).await.map(Json)
}

pub(crate) async fn login(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(credentials): Json<Credentials>,
) -> ApiResult<Value> {
    let session = auth::login(&state, credentials).await?;
    if session["user"]["is_admin"] == true {
        if let Some(origin) = headers
            .get(header::ORIGIN)
            .and_then(|value| value.to_str().ok())
        {
            site_settings::remember_frontend(
                &state,
                session["user"]["id"].as_i64().expect("user id"),
                origin,
            )
            .await?;
        }
    }
    Ok(Json(session))
}

pub(crate) async fn me(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    headers: HeaderMap,
) -> ApiResult<Value> {
    if claims.admin {
        if let Some(origin) = headers
            .get(header::ORIGIN)
            .and_then(|value| value.to_str().ok())
        {
            site_settings::remember_frontend(&state, claims.sub, origin).await?;
        }
    }
    auth::me(&state, &claims).await.map(Json)
}

pub(crate) async fn change_password(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<PasswordChange>,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(auth::change_password(&state, &claims, input).await?),
    ))
}

pub(crate) async fn report_visibility(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(auth::report_visibility(&state, claims.sub).await?),
    ))
}

pub(crate) async fn update_report_visibility(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Json(input): Json<ReportVisibilityUpdate>,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(auth::update_report_visibility(&state, claims.sub, input).await?),
    ))
}

pub(crate) async fn list_keys(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(auth::list_keys(&state, claims.sub).await?),
    ))
}

pub(crate) async fn create_key(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(auth::create_key(&state, claims.sub).await?),
    ))
}

pub(crate) async fn revoke_key(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<StatusCode> {
    auth::revoke_key(&state, claims.sub, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn reveal_key(
    State(state): State<AppState>,
    Authenticated(claims): Authenticated,
    Path(id): Path<i64>,
) -> ServiceResult<impl IntoResponse> {
    let key = auth::reveal_key(&state, claims.sub, id).await?;
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(serde_json::json!({"key": key})),
    ))
}
