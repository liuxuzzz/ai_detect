use crate::{
    error::{err, AppError, ErrorKind},
    models::Claims,
    services::auth,
    state::AppState,
};
use axum::{
    extract::FromRequestParts,
    http::{header, request::Parts, Method},
    Router,
};
use tower_http::{
    cors::{Any, CorsLayer},
    trace::TraceLayer,
};

#[cfg(test)]
mod tests;

pub(crate) fn apply(router: Router) -> Router {
    router
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods([
                    Method::GET,
                    Method::POST,
                    Method::PUT,
                    Method::PATCH,
                    Method::DELETE,
                    Method::OPTIONS,
                ])
                // Browsers require Authorization to be listed explicitly;
                // a wildcard does not cover it in a cross-origin preflight.
                .allow_headers([
                    header::AUTHORIZATION,
                    header::CONTENT_TYPE,
                    header::ACCEPT,
                    header::CACHE_CONTROL,
                    header::PRAGMA,
                    header::HeaderName::from_static("x-client-key"),
                ]),
        )
        .layer(TraceLayer::new_for_http().make_span_with(|request: &axum::http::Request<axum::body::Body>| {
            // OAuth authorization codes and email tokens must never enter request logs.
            tracing::info_span!("http", method = %request.method(), path = %request.uri().path())
        }))
}

pub(crate) struct Authenticated(pub(crate) Claims);
pub(crate) struct OptionalUser(pub(crate) Option<Claims>);
pub(crate) struct Administrator;
pub(crate) struct ClientOwner(pub(crate) i64);

impl FromRequestParts<AppState> for Authenticated {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, AppError> {
        let token = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .ok_or_else(|| err(ErrorKind::Unauthenticated, "缺少登录令牌"))?;
        auth::authenticate(state, token).await.map(Self)
    }
}

impl FromRequestParts<AppState> for OptionalUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, AppError> {
        if parts.headers.contains_key(header::AUTHORIZATION) {
            let Authenticated(claims) = Authenticated::from_request_parts(parts, state).await?;
            Ok(Self(Some(claims)))
        } else {
            Ok(Self(None))
        }
    }
}

impl FromRequestParts<AppState> for Administrator {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, AppError> {
        let Authenticated(claims) = Authenticated::from_request_parts(parts, state).await?;
        if !claims.admin {
            return Err(err(ErrorKind::Forbidden, "需要管理员权限"));
        }
        Ok(Self)
    }
}

impl FromRequestParts<AppState> for ClientOwner {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, AppError> {
        let key = parts
            .headers
            .get("x-client-key")
            .and_then(|value| value.to_str().ok())
            .ok_or_else(|| err(ErrorKind::Unauthenticated, "缺少 X-Client-Key"))?;
        auth::key_owner(state, key).await.map(Self)
    }
}
