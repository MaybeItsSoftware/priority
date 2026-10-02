//! Device tokens: minting, hashing and checking them.
//!
//! A device is paired once and then identifies itself with an opaque bearer
//! token for good. Only the token's sha256 is stored, so a leaked database
//! cannot be replayed against the server. sha256 rather than a password hash
//! is enough because the token is 256 random bits, not something guessable.

use crate::AppState;
use crate::error::{AppError, Result};
use axum::extract::{Request, State};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::middleware::Next;
use axum::response::Response;
use rand::RngCore;
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// The paired device a request came from, put in the request's extensions by
/// [`require_device`].
#[derive(Debug, Clone, Copy)]
pub struct Device(pub Uuid);

/// A fresh device token: 32 random bytes, hex.
pub fn new_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    hex(&bytes)
}

pub fn hash_token(token: &str) -> String {
    hex(&Sha256::digest(token.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Whether `candidate` is the admin token, compared over the hashes so the
/// time taken says nothing about how much of it matched.
pub fn is_admin_token(state: &AppState, candidate: &str) -> bool {
    let Some(admin) = state.admin_token.as_deref() else {
        return false;
    };
    let expected = Sha256::digest(admin.as_bytes());
    let given = Sha256::digest(candidate.as_bytes());
    expected
        .iter()
        .zip(given.iter())
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

pub fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|token| !token.is_empty())
}

/// The device a token belongs to, touching its `last_seen_at` on the way, so
/// the table doubles as a record of which devices are still syncing.
pub async fn device_for_token(state: &AppState, token: &str) -> Result<Option<Uuid>> {
    let id = sqlx::query_scalar::<_, Uuid>(
        "UPDATE devices SET last_seen_at = now() WHERE token_hash = $1 RETURNING id",
    )
    .bind(hash_token(token))
    .fetch_optional(&state.pool)
    .await?;
    Ok(id)
}

/// Middleware for every route that needs a paired device.
pub async fn require_device(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response> {
    let token = bearer(request.headers()).ok_or(AppError::Unauthorized)?;
    let id = device_for_token(&state, token)
        .await?
        .ok_or(AppError::Unauthorized)?;
    request.extensions_mut().insert(Device(id));
    Ok(next.run(request).await)
}
