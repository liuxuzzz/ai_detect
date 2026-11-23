use crate::{
    error::{err, ErrorKind, ServiceResult},
    middleware::{Administrator, Authenticated},
    services::{email_auth, identity_settings, mail, oauth, site_settings},
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap},
    response::{IntoResponse, Redirect, Response},
    Json,
};
use serde_json::{json, Value};

fn no_store(value: Value) -> impl IntoResponse {
    ([(header::CACHE_CONTROL, "no-store")], Json(value))
}

pub(crate) async fn options(State(state): State<AppState>) -> ServiceResult<impl IntoResponse> {
    Ok(no_store(oauth::options(&state).await?))
}

pub(crate) async fn settings(
    State(state): State<AppState>,
    _admin: Administrator,
) -> ServiceResult<impl IntoResponse> {
    let config = identity_settings::load(&state).await?;
    Ok(no_store(
        identity_settings::public_admin_view(&state, &config).await?,
    ))
}

pub(crate) async fn update_settings(
    State(state): State<AppState>,
    _admin: Administrator,
    Json(input): Json<identity_settings::IdentityUpdate>,
) -> ServiceResult<impl IntoResponse> {
    Ok(no_store(identity_settings::update(&state, input).await?))
}

pub(crate) async fn test_mail(
    State(state): State<AppState>,
    _admin: Administrator,
    Authenticated(claims): Authenticated,
) -> ServiceResult<impl IntoResponse> {
    let config = identity_settings::load(&state).await?;
    mail::send(
        &config.smtp,
        &claims.email,
        "AI质量检测 · SMTP 测试",
        "您的邮件服务配置测试成功。",
    )
    .await?;
    Ok(no_store(json!({"ok":true})))
}

pub(crate) async fn send_code(
    State(state): State<AppState>,
    Json(input): Json<email_auth::EmailCodeRequest>,
) -> ServiceResult<impl IntoResponse> {
    Ok(no_store(email_auth::send_code(&state, input).await?))
}

pub(crate) async fn reset_password(
    State(state): State<AppState>,
    Json(input): Json<email_auth::PasswordReset>,
) -> ServiceResult<impl IntoResponse> {
    Ok(no_store(email_auth::reset_password(&state, input).await?))
}

pub(crate) async fn oauth_start(
    State(state): State<AppState>,
    Path(provider): Path<String>,
) -> ServiceResult<Response> {
    let auth = oauth::start(&state, &provider).await?;
    Ok((
        [
            (header::SET_COOKIE, auth.cookie),
            (header::CACHE_CONTROL, "no-store".into()),
            (header::REFERRER_POLICY, "no-referrer".into()),
        ],
        Redirect::to(&auth.url),
    )
        .into_response())
}

pub(crate) async fn oauth_callback(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    Query(input): Query<oauth::Callback>,
    headers: HeaderMap,
) -> Response {
    let cookies = headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    let result = oauth::callback(&state, &provider, input, cookies).await;
    let address = match site_settings::page_url(&state, "/auth/callback").await {
        Ok(address) => address,
        Err(error) => return error.into_response(),
    };
    let mut url = match reqwest::Url::parse(&address) {
        Ok(url) => url,
        Err(_) => return err(ErrorKind::Internal, "站点地址配置错误").into_response(),
    };
    let fragment = match result {
        Ok(code) => format!("code={code}"),
        Err(_) => "error=oauth_failed".into(),
    };
    url.set_fragment(Some(&fragment));
    (
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::REFERRER_POLICY, "no-referrer"),
        ],
        Redirect::to(url.as_str()),
    )
        .into_response()
}

pub(crate) async fn oauth_exchange(
    State(state): State<AppState>,
    Json(input): Json<oauth::TicketExchange>,
) -> ServiceResult<impl IntoResponse> {
    Ok(no_store(oauth::exchange_ticket(&state, input).await?))
}
