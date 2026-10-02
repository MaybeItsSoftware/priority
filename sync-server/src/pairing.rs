//! Adding a device: `POST /v1/pairing-codes` and `POST /v1/pair`.
//!
//! The first device (the Mac) pairs with the admin token, which only its owner
//! has. Every later device pairs with a short code minted by one already
//! paired, so nobody types a 64-character secret on a phone.

use crate::AppState;
use crate::auth::{self, bearer, hash_token, is_admin_token};
use crate::error::{AppError, Result};
use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use chrono::{DateTime, Duration, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// How long a code works for. Long enough to pick up the other device and
/// type it; short enough that one left on screen is soon useless.
const CODE_LIFETIME: Duration = Duration::minutes(10);

/// No 0/O, 1/I/L or U: the code is read off one screen and typed on another.
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCode {
    pub code: String,
    pub expires_at: DateTime<Utc>,
}

/// Mints a code. Either the admin token or any paired device's token will do.
pub async fn create_code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<PairingCode>> {
    let token = bearer(&headers).ok_or(AppError::Unauthorized)?;
    if !is_admin_token(&state, token) && auth::device_for_token(&state, token).await?.is_none() {
        return Err(AppError::Unauthorized);
    }

    let expires_at = Utc::now() + CODE_LIFETIME;
    // Retried on the off chance of a collision with a live code; 30^8 makes
    // that rare enough that three attempts is plenty.
    for _ in 0..3 {
        let code = new_code();
        let inserted = sqlx::query(
            "INSERT INTO pairing_codes (code, expires_at) VALUES ($1, $2) \
             ON CONFLICT (code) DO NOTHING",
        )
        .bind(&code)
        .bind(expires_at)
        .execute(&state.pool)
        .await?
        .rows_affected();
        if inserted == 1 {
            // Expired codes are never useful again; sweep them while here.
            sqlx::query("DELETE FROM pairing_codes WHERE expires_at < now() - interval '1 day'")
                .execute(&state.pool)
                .await?;
            return Ok(Json(PairingCode { code, expires_at }));
        }
    }
    Err(AppError::Database(sqlx::Error::Protocol(
        "could not mint a unique pairing code".into(),
    )))
}

fn new_code() -> String {
    let mut rng = rand::thread_rng();
    let mut code = String::with_capacity(9);
    for index in 0..8 {
        if index == 4 {
            code.push('-');
        }
        code.push(CODE_ALPHABET[rng.gen_range(0..CODE_ALPHABET.len())] as char);
    }
    code
}

/// A code as typed: case, spaces and the hyphen are forgiven.
fn normalise_code(typed: &str) -> String {
    let letters: String = typed
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if letters.len() == 8 {
        format!("{}-{}", &letters[..4], &letters[4..])
    } else {
        letters
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairRequest {
    pub code: Option<String>,
    pub admin_token: Option<String>,
    pub device_name: Option<String>,
    pub platform: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResponse {
    pub device_id: Uuid,
    pub token: String,
}

pub async fn pair(
    State(state): State<AppState>,
    Json(request): Json<PairRequest>,
) -> Result<Json<PairResponse>> {
    if let Some(admin_token) = request.admin_token.as_deref() {
        if state.admin_token.is_none() {
            return Err(AppError::Forbidden(
                "admin pairing is disabled: SYNC_ADMIN_TOKEN is not set".into(),
            ));
        }
        if !is_admin_token(&state, admin_token) {
            return Err(AppError::Unauthorized);
        }
    } else if let Some(code) = request.code.as_deref() {
        // Claimed in one statement, so two devices racing the same code
        // cannot both win it.
        let claimed = sqlx::query(
            "UPDATE pairing_codes SET used_at = now() \
             WHERE code = $1 AND used_at IS NULL AND expires_at > now()",
        )
        .bind(normalise_code(code))
        .execute(&state.pool)
        .await?
        .rows_affected();
        if claimed == 0 {
            return Err(AppError::Forbidden(
                "that pairing code is wrong, used or expired".into(),
            ));
        }
    } else {
        return Err(AppError::BadRequest(
            "send either a pairing code or the admin token".into(),
        ));
    }

    let device_id = Uuid::new_v4();
    let token = auth::new_token();
    sqlx::query(
        "INSERT INTO devices (id, name, platform, token_hash, created_at, last_seen_at) \
         VALUES ($1, $2, $3, $4, now(), now())",
    )
    .bind(device_id)
    .bind(request.device_name)
    .bind(request.platform)
    .bind(hash_token(&token))
    .execute(&state.pool)
    .await?;
    tracing::info!(%device_id, "paired a device");
    Ok(Json(PairResponse { device_id, token }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_two_groups_of_four_from_the_alphabet() {
        let code = new_code();
        assert_eq!(code.len(), 9);
        assert_eq!(&code[4..5], "-");
        assert!(
            code.bytes()
                .filter(|b| *b != b'-')
                .all(|b| CODE_ALPHABET.contains(&b))
        );
    }

    #[test]
    fn typed_codes_are_forgiven_case_and_spacing() {
        assert_eq!(normalise_code("abcd efgh"), "ABCD-EFGH");
        assert_eq!(normalise_code(" ABCD-EFGH "), "ABCD-EFGH");
        assert_eq!(normalise_code("abcdefgh"), "ABCD-EFGH");
    }
}
