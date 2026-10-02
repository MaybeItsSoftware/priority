use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

/// Anything a request can fail with.
///
/// One type, because every failure ends the same way: a status and an
/// `{"error": "..."}` body. Clients branch on the status alone (401 means
/// re-pair, 400 means a bug in the client, 5xx means retry later), so the
/// variants are cut along those lines rather than along where they came from.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("missing or unknown bearer token")]
    Unauthorized,
    #[error("{0}")]
    Forbidden(String),
    /// Logged in full, reported vaguely: a database message can carry row
    /// contents, and the client can do nothing with it but retry.
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match &self {
            AppError::BadRequest(_) => StatusCode::BAD_REQUEST,
            AppError::Unauthorized => StatusCode::UNAUTHORIZED,
            AppError::Forbidden(_) => StatusCode::FORBIDDEN,
            AppError::Database(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        let message = match &self {
            AppError::Database(error) => {
                tracing::error!(%error, "request failed in the database");
                "internal error".to_owned()
            }
            other => other.to_string(),
        };
        (status, Json(json!({ "error": message }))).into_response()
    }
}

pub type Result<T> = std::result::Result<T, AppError>;
