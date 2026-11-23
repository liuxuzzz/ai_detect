use crate::{
    error::{err, ErrorKind, ServiceResult},
    middleware::Administrator,
    models::{RegistrationSettings, SiteSettingsUpdate},
    services::site_settings,
    state::AppState,
};
use axum::{
    extract::{rejection::JsonRejection, State},
    http::header,
    response::IntoResponse,
    Json,
};

pub(crate) async fn registration(
    State(state): State<AppState>,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(RegistrationSettings {
            registration_enabled: site_settings::get(&state).await?.registration_enabled,
        }),
    ))
}

pub(crate) async fn get(
    State(state): State<AppState>,
    _admin: Administrator,
) -> ServiceResult<impl IntoResponse> {
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(site_settings::get(&state).await?),
    ))
}

pub(crate) async fn update(
    State(state): State<AppState>,
    _admin: Administrator,
    input: Result<Json<SiteSettingsUpdate>, JsonRejection>,
) -> ServiceResult<impl IntoResponse> {
    let Json(settings) = input.map_err(|_| {
        err(
            ErrorKind::InvalidInput,
            "站点设置格式不正确：注册开关须为布尔值，上传次数和时间窗口须为整数",
        )
    })?;
    let settings = site_settings::update(&state, settings).await?;
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(settings)))
}
