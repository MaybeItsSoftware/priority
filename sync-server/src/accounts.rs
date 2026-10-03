//! Accounts: signing up, signing in and out, and deleting an account.
//!
//! Anyone can make an account with an email and a password. Signing in on a
//! device trades them for a device token (see `auth.rs`), which is all the
//! device sends from then on; the password is never stored on a device.
//!
//! Passwords are hashed with argon2id at the crate's default cost. Hashing is
//! deliberately slow, so it runs on the blocking pool rather than stalling the
//! async workers that serve long-polls.

use crate::AppState;
use crate::auth::{self, Device};
use crate::error::{AppError, Result};
use argon2::Argon2;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use axum::extract::State;
use axum::{Extension, Json};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Shorter is too easy to guess offline if the database ever leaked; there is
/// no upper rule beyond stopping someone posting a megabyte to the hasher.
const MIN_PASSWORD_CHARS: usize = 8;
const MAX_PASSWORD_BYTES: usize = 1024;
/// RFC 5321's limit on a forward path.
const MAX_EMAIL_LEN: usize = 254;

/// Failed sign-ins allowed per email within [`FAILURE_WINDOW`] before the
/// server stops checking passwords for it. Generous for a person mistyping,
/// useless for someone guessing.
const MAX_FAILURES: u32 = 10;
const FAILURE_WINDOW: Duration = Duration::from_secs(15 * 60);

/// What signing up, signing in and pairing all answer with.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedIn {
    pub account_id: Uuid,
    /// `None` only for an account carried over from before accounts existed.
    pub email: Option<String>,
    pub device_id: Uuid,
    pub token: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    pub email: String,
    pub password: String,
    pub device_name: Option<String>,
    pub platform: Option<String>,
}

/// An email as the server keys it: trimmed and lowercased, so "Me@X.com" and
/// "me@x.com " are one account.
pub fn normalise_email(email: &str) -> String {
    email.trim().to_lowercase()
}

/// A shape check, not proof the address exists: one `@` with something either
/// side, a dot in the domain and no spaces. The server never sends mail, so
/// anything stricter would only turn away real addresses.
pub fn check_email(email: &str) -> Result<()> {
    let bad = || AppError::BadRequest("that doesn't look like an email address".into());
    if email.len() > MAX_EMAIL_LEN || email.chars().any(char::is_whitespace) {
        return Err(bad());
    }
    let (local, domain) = email.split_once('@').ok_or_else(bad)?;
    let dotted = domain
        .split_once('.')
        .is_some_and(|(left, right)| !left.is_empty() && !right.is_empty());
    if local.is_empty() || domain.contains('@') || !dotted {
        return Err(bad());
    }
    Ok(())
}

pub fn check_password(password: &str) -> Result<()> {
    if password.chars().count() < MIN_PASSWORD_CHARS {
        return Err(AppError::BadRequest(format!(
            "use a password of at least {MIN_PASSWORD_CHARS} characters"
        )));
    }
    if password.len() > MAX_PASSWORD_BYTES {
        return Err(AppError::BadRequest("that password is too long".into()));
    }
    Ok(())
}

pub(crate) async fn hash_password(password: String) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        let mut salt = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut salt);
        let salt = SaltString::encode_b64(&salt).map_err(|e| AppError::Internal(e.to_string()))?;
        Argon2::default()
            .hash_password(password.as_bytes(), &salt)
            .map(|hash| hash.to_string())
            .map_err(|e| AppError::Internal(e.to_string()))
    })
    .await
    .map_err(|e| AppError::Internal(e.to_string()))?
}

/// Checks a password against a stored hash. With no hash (no such account)
/// it checks against a throwaway one instead, so a wrong email takes as long
/// to refuse as a wrong password and the timing says nothing about who has
/// an account.
async fn verify_password(password: String, stored: Option<String>) -> Result<bool> {
    tokio::task::spawn_blocking(move || {
        let stored = stored.unwrap_or_else(|| dummy_hash().to_owned());
        let Ok(parsed) = PasswordHash::new(&stored) else {
            return false;
        };
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok()
    })
    .await
    .map_err(|e| AppError::Internal(e.to_string()))
}

fn dummy_hash() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(|| {
        let salt = SaltString::encode_b64(&[7u8; 16]).expect("a fixed salt encodes");
        Argon2::default()
            .hash_password(b"not anybody's password", &salt)
            .expect("hashing a fixed password succeeds")
            .to_string()
    })
}

/// Counts failed sign-ins per email, in this process only.
///
/// One replica is the deployment (see `railway.toml`); with more, each would
/// allow its own [`MAX_FAILURES`], which still makes guessing hopeless.
#[derive(Default)]
pub struct SignInLimiter {
    failures: Mutex<HashMap<String, (u32, Instant)>>,
}

impl SignInLimiter {
    fn is_locked(&self, email: &str) -> bool {
        let failures = self.failures.lock().expect("limiter lock");
        failures.get(email).is_some_and(|(count, since)| {
            *count >= MAX_FAILURES && since.elapsed() < FAILURE_WINDOW
        })
    }

    fn record_failure(&self, email: &str) {
        let mut failures = self.failures.lock().expect("limiter lock");
        // Forget windows that have run out, so the map stays the size of the
        // last quarter hour's mistakes.
        failures.retain(|_, (_, since)| since.elapsed() < FAILURE_WINDOW);
        let entry = failures
            .entry(email.to_owned())
            .or_insert((0, Instant::now()));
        entry.0 += 1;
    }

    pub(crate) fn clear(&self, email: &str) {
        self.failures.lock().expect("limiter lock").remove(email);
    }
}

/// `POST /v1/accounts`: makes an account and signs this device in to it.
pub async fn sign_up(
    State(state): State<AppState>,
    Json(request): Json<Credentials>,
) -> Result<Json<SignedIn>> {
    let email = normalise_email(&request.email);
    check_email(&email)?;
    check_password(&request.password)?;
    let password_hash = hash_password(request.password).await?;

    let mut tx = state.pool.begin().await?;
    let account = Uuid::new_v4();
    let inserted = sqlx::query(
        "INSERT INTO accounts (id, email, password_hash) VALUES ($1, $2, $3) \
         ON CONFLICT (email) DO NOTHING",
    )
    .bind(account)
    .bind(&email)
    .bind(&password_hash)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if inserted == 0 {
        return Err(AppError::Conflict(
            "there is already an account with that email; sign in instead".into(),
        ));
    }
    let (device_id, token) = auth::add_device(
        &mut *tx,
        account,
        request.device_name.as_deref(),
        request.platform.as_deref(),
    )
    .await?;
    tx.commit().await?;
    tracing::info!(%account, %device_id, "signed up");
    Ok(Json(SignedIn {
        account_id: account,
        email: Some(email),
        device_id,
        token,
    }))
}

/// `POST /v1/sessions`: signs this device in to an existing account.
pub async fn sign_in(
    State(state): State<AppState>,
    Json(request): Json<Credentials>,
) -> Result<Json<SignedIn>> {
    let email = normalise_email(&request.email);
    if state.sign_ins.is_locked(&email) {
        return Err(AppError::TooManyRequests(
            "too many wrong passwords; try again in 15 minutes".into(),
        ));
    }
    let found = sqlx::query_as::<_, (Uuid, Option<String>)>(
        "SELECT id, password_hash FROM accounts WHERE email = $1",
    )
    .bind(&email)
    .fetch_optional(&state.pool)
    .await?;
    let (account, stored) = match found {
        Some((account, stored)) => (Some(account), stored),
        None => (None, None),
    };
    let matched = verify_password(request.password, stored).await?;
    let Some(account) = account.filter(|_| matched) else {
        state.sign_ins.record_failure(&email);
        return Err(AppError::BadCredentials);
    };
    state.sign_ins.clear(&email);

    let (device_id, token) = auth::add_device(
        &state.pool,
        account,
        request.device_name.as_deref(),
        request.platform.as_deref(),
    )
    .await?;
    tracing::info!(%account, %device_id, "signed in");
    Ok(Json(SignedIn {
        account_id: account,
        email: Some(email),
        device_id,
        token,
    }))
}

/// `POST /v1/sign-out`: forgets the calling device's token. The device keeps
/// its workspace; it just stops syncing.
pub async fn sign_out(
    State(state): State<AppState>,
    Extension(device): Extension<Device>,
) -> Result<Json<serde_json::Value>> {
    sqlx::query("DELETE FROM devices WHERE id = $1")
        .bind(device.id)
        .execute(&state.pool)
        .await?;
    tracing::info!(device = %device.id, "signed out");
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub account_id: Uuid,
    pub email: Option<String>,
    pub devices: Vec<DeviceInfo>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub id: Uuid,
    pub name: Option<String>,
    pub platform: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
    /// The device asking.
    pub current: bool,
}

/// `GET /v1/account`: who this device is signed in as, and the account's
/// other devices.
pub async fn account(
    State(state): State<AppState>,
    Extension(device): Extension<Device>,
) -> Result<Json<AccountInfo>> {
    let email = sqlx::query_scalar::<_, Option<String>>("SELECT email FROM accounts WHERE id = $1")
        .bind(device.account)
        .fetch_one(&state.pool)
        .await?;
    type DeviceTuple = (
        Uuid,
        Option<String>,
        Option<String>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
    );
    let devices = sqlx::query_as::<_, DeviceTuple>(
        "SELECT id, name, platform, created_at, last_seen_at FROM devices \
         WHERE account_id = $1 ORDER BY created_at",
    )
    .bind(device.account)
    .fetch_all(&state.pool)
    .await?
    .into_iter()
    .map(
        |(id, name, platform, created_at, last_seen_at)| DeviceInfo {
            current: id == device.id,
            id,
            name,
            platform,
            created_at,
            last_seen_at,
        },
    )
    .collect();
    Ok(Json(AccountInfo {
        account_id: device.account,
        email,
        devices,
    }))
}

#[derive(Debug, Deserialize)]
pub struct DeleteRequest {
    #[serde(default)]
    pub password: String,
}

/// `POST /v1/account/delete`: deletes the account, every row it synced and
/// every device signed in to it. The password is asked for again so a phone
/// left unlocked can't wipe the account. Each device keeps its own copy of
/// the workspace.
pub async fn delete_account(
    State(state): State<AppState>,
    Extension(device): Extension<Device>,
    Json(request): Json<DeleteRequest>,
) -> Result<Json<serde_json::Value>> {
    let stored =
        sqlx::query_scalar::<_, Option<String>>("SELECT password_hash FROM accounts WHERE id = $1")
            .bind(device.account)
            .fetch_one(&state.pool)
            .await?;
    // An account with no password (carried over from before accounts) is
    // proved by the device token alone.
    if stored.is_some() && !verify_password(request.password, stored).await? {
        return Err(AppError::BadCredentials);
    }
    // Rows, devices and codes go with it, by ON DELETE CASCADE.
    sqlx::query("DELETE FROM accounts WHERE id = $1")
        .bind(device.account)
        .execute(&state.pool)
        .await?;
    tracing::info!(account = %device.account, "deleted an account");
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emails_are_trimmed_and_lowercased() {
        assert_eq!(normalise_email("  Me@Example.COM "), "me@example.com");
    }

    #[test]
    fn email_shape_is_checked_loosely() {
        assert!(check_email("me@example.com").is_ok());
        assert!(check_email("a.b+tag@mail.example.co.uk").is_ok());
        for bad in [
            "",
            "me",
            "me@",
            "@example.com",
            "me@example",
            "me@@example.com",
            "m e@x.com",
            "me@.com",
        ] {
            assert!(check_email(bad).is_err(), "{bad:?} should be refused");
        }
    }

    #[test]
    fn passwords_need_eight_characters() {
        assert!(check_password("1234567").is_err());
        assert!(check_password("12345678").is_ok());
        assert!(check_password(&"x".repeat(MAX_PASSWORD_BYTES + 1)).is_err());
    }

    #[tokio::test]
    async fn a_hash_verifies_its_password_and_nothing_else() {
        let hash = hash_password("correct horse".into()).await.expect("hash");
        assert!(hash.starts_with("$argon2id$"));
        assert!(
            verify_password("correct horse".into(), Some(hash.clone()))
                .await
                .expect("verify")
        );
        assert!(
            !verify_password("wrong horse".into(), Some(hash))
                .await
                .expect("verify")
        );
        assert!(
            !verify_password("correct horse".into(), None)
                .await
                .expect("verify")
        );
    }

    #[test]
    fn the_limiter_locks_after_too_many_failures() {
        let limiter = SignInLimiter::default();
        for _ in 0..MAX_FAILURES {
            assert!(!limiter.is_locked("me@x.com"));
            limiter.record_failure("me@x.com");
        }
        assert!(limiter.is_locked("me@x.com"));
        assert!(!limiter.is_locked("you@x.com"));
        limiter.clear("me@x.com");
        assert!(!limiter.is_locked("me@x.com"));
    }
}
