use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;

#[derive(Serialize)]
struct ApiErrorBody {
    error: String,
}

#[derive(Debug)]
pub struct AppError {
    kind: ErrorKind,
    message: String,
}

#[derive(Debug)]
pub(crate) enum ErrorKind {
    InvalidInput,
    Unauthenticated,
    Forbidden,
    NotFound,
    Gone,
    Conflict,
    QuotaExceeded,
    Upstream,
    Internal,
}

impl AppError {
    pub(crate) fn internal(error: impl std::fmt::Display) -> Self {
        err(ErrorKind::Internal, error.to_string())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match self.kind {
            ErrorKind::InvalidInput => StatusCode::BAD_REQUEST,
            ErrorKind::Unauthenticated => StatusCode::UNAUTHORIZED,
            ErrorKind::Forbidden => StatusCode::FORBIDDEN,
            ErrorKind::NotFound => StatusCode::NOT_FOUND,
            ErrorKind::Gone => StatusCode::GONE,
            ErrorKind::Conflict => StatusCode::CONFLICT,
            ErrorKind::QuotaExceeded => StatusCode::TOO_MANY_REQUESTS,
            ErrorKind::Upstream => StatusCode::BAD_GATEWAY,
            ErrorKind::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (
            status,
            Json(ApiErrorBody {
                error: self.message,
            }),
        )
            .into_response()
    }
}

pub(crate) type ServiceResult<T> = Result<T, AppError>;
pub(crate) type ApiResult<T> = ServiceResult<Json<T>>;

pub(crate) fn err(kind: ErrorKind, message: impl Into<String>) -> AppError {
    AppError {
        kind,
        message: message.into(),
    }
}
