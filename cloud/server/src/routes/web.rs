use super::router;
use crate::state::AppState;
use axum::{
    http::{header, HeaderValue},
    Router,
};
use std::path::Path;
use tower_http::{
    services::{ServeDir, ServeFile},
    set_header::SetResponseHeader,
};

/// Serve the Vue application and JSON API from the same origin.
pub fn application(state: AppState, directory: impl AsRef<Path>) -> Router {
    let directory = directory.as_ref();
    let index = SetResponseHeader::overriding(
        ServeFile::new(directory.join("index.html")),
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache"),
    );
    router(state)
        .route_service("/", index.clone())
        .route_service("/r/{slug}", index.clone())
        .route_service("/r/{slug}/", index.clone())
        .route_service("/share/{token}", index.clone())
        .route_service("/share/{token}/", index.clone())
        .route_service("/auth/callback", index)
        .fallback_service(ServeDir::new(directory))
}
