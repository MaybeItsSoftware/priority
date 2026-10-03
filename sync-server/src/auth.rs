//! Device tokens: minting, hashing and checking them.
//!
//! A device signs in (or pairs) once and then identifies itself with an opaque
//! bearer token until it signs out. The token names the device, and through it
//! the account whose rows it may read and write. Only the token's sha256 is stored, so a leaked database
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

/// The signed-in device a request came from, put in the request's extensions
/// by [`require_device`].
#[derive(Debug, Clone, Copy)]
pub struct Device {
    pub id: Uuid,
    pub account: Uuid,
}

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
pub async fn device_for_token(state: &AppState, token: &str) -> Result<Option<Device>> {
    let device = sqlx::query_as::<_, (Uuid, Uuid)>(
        "UPDATE devices SET last_seen_at = now() WHERE token_hash = $1 \
         RETURNING id, account_id",
    )
    .bind(hash_token(token))
    .fetch_optional(&state.pool)
    .await?;
    Ok(device.map(|(id, account)| Device { id, account }))
}

/// Registers a device on an account and returns its token, which is shown
/// once and never stored.
pub async fn add_device(
    executor: impl sqlx::PgExecutor<'_>,
    account: Uuid,
    name: Option<&str>,
    platform: Option<&str>,
) -> Result<(Uuid, String)> {
    let device_id = Uuid::new_v4();
    let token = new_token();
    sqlx::query(
        "INSERT INTO devices (id, account_id, name, platform, token_hash, created_at, last_seen_at) \
         VALUES ($1, $2, $3, $4, $5, now(), now())",
    )
    .bind(device_id)
    .bind(account)
    .bind(name)
    .bind(platform)
    .bind(hash_token(&token))
    .execute(executor)
    .await?;
    Ok((device_id, token))
}

/// Middleware for every route that needs a paired device.
pub async fn require_device(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response> {
    let token = bearer(request.headers()).ok_or(AppError::Unauthorized)?;
    let device = device_for_token(&state, token)
        .await?
        .ok_or(AppError::Unauthorized)?;
    request.extensions_mut().insert(device);
    Ok(next.run(request).await)
}
