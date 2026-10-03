//! Adding a device without a password: `POST /v1/pairing-codes` and
//! `POST /v1/pair`.
//!
//! A signed-in device mints a short code, shown as text and as a QR code, and
//! the new device trades it for a token on the same account. Signing in with
//! the email and password does the same job (see `accounts.rs`); this is the
//! quicker way when one device is already in hand.

use crate::AppState;
use crate::accounts::SignedIn;
use crate::auth::{self, Device};
use crate::error::{AppError, Result};
use axum::extract::State;
use axum::{Extension, Json};
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

/// Mints a code for the calling device's account.
pub async fn create_code(
    State(state): State<AppState>,
    Extension(device): Extension<Device>,
) -> Result<Json<PairingCode>> {
    let expires_at = Utc::now() + CODE_LIFETIME;
    // Retried on the off chance of a collision with a live code; 30^8 makes
    // that rare enough that three attempts is plenty.
    for _ in 0..3 {
        let code = new_code();
        let inserted = sqlx::query(
            "INSERT INTO pairing_codes (code, account_id, expires_at) VALUES ($1, $2, $3) \
             ON CONFLICT (code) DO NOTHING",
        )
        .bind(&code)
        .bind(device.account)
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
    pub code: String,
    pub device_name: Option<String>,
    pub platform: Option<String>,
}

pub async fn pair(
    State(state): State<AppState>,
    Json(request): Json<PairRequest>,
) -> Result<Json<SignedIn>> {
    // Claimed in one statement, so two devices racing the same code cannot
    // both win it.
    let claimed = sqlx::query_as::<_, (Uuid, Option<String>)>(
        "UPDATE pairing_codes SET used_at = now() FROM accounts \
         WHERE pairing_codes.code = $1 AND pairing_codes.used_at IS NULL \
           AND pairing_codes.expires_at > now() AND accounts.id = pairing_codes.account_id \
         RETURNING accounts.id, accounts.email",
    )
    .bind(normalise_code(&request.code))
    .fetch_optional(&state.pool)
    .await?;
    let Some((account, email)) = claimed else {
        return Err(AppError::Forbidden(
            "that pairing code is wrong, used or expired".into(),
        ));
    };

    let (device_id, token) = auth::add_device(
        &state.pool,
        account,
        request.device_name.as_deref(),
        request.platform.as_deref(),
    )
    .await?;
    tracing::info!(%device_id, %account, "paired a device");
    Ok(Json(SignedIn {
        account_id: account,
        email,
        device_id,
        token,
    }))
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
