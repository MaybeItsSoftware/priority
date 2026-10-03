//! Who a request is from: a Supabase Auth user, on one of their devices.
//!
//! The apps sign in with Supabase (email and password, Google, Apple) and
//! send the access token it issues as `Authorization: Bearer <jwt>`. The
//! server checks the signature against the project's published keys and takes
//! the account from the token's `sub`. It never sees a password.
//!
//! Requests also carry `X-Priority-Device: <uuid>`, the device's own id, so
//! the server can list an account's devices and record who wrote a row.

use crate::AppState;
use crate::error::{AppError, Result};
use axum::extract::{Request, State};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::middleware::Next;
use axum::response::Response;
use jsonwebtoken::jwk::JwkSet;
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::RwLock;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub const DEVICE_HEADER: &str = "x-priority-device";

/// The signed-in user a request came from, put in the request's extensions by
/// [`require_user`].
#[derive(Debug, Clone)]
pub struct Caller {
    pub account: Uuid,
    pub email: Option<String>,
    /// The device's id, when it sent one.
    pub device: Option<Uuid>,
}

#[derive(Debug, Deserialize)]
struct Claims {
    sub: String,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    role: Option<String>,
}

/// Checks Supabase access tokens.
///
/// New Supabase projects sign tokens with an asymmetric key (ES256 or RS256)
/// and publish the public half at `/auth/v1/.well-known/jwks.json`; older
/// ones sign with a shared HS256 secret. Both are accepted, so rotating the
/// project from one to the other doesn't lock anyone out.
pub struct Verifier {
    issuer: String,
    jwks_url: Option<String>,
    secret: Option<DecodingKey>,
    keys: RwLock<HashMap<String, (DecodingKey, Algorithm)>>,
    /// When the key set was last fetched, so a flood of tokens naming an
    /// unknown key id can't turn into a flood of fetches.
    fetched: RwLock<Option<Instant>>,
    client: reqwest::Client,
}

/// How soon an unknown key id may trigger another fetch of the key set.
const REFETCH_AFTER: Duration = Duration::from_secs(30);

impl Verifier {
    /// For a project at `supabase_url` (`https://<ref>.supabase.co`).
    pub fn for_project(supabase_url: &str, legacy_secret: Option<&str>) -> Self {
        let base = supabase_url.trim_end_matches('/');
        let mut verifier = Self::new(format!("{base}/auth/v1"), legacy_secret);
        verifier.jwks_url = Some(format!("{base}/auth/v1/.well-known/jwks.json"));
        verifier
    }

    /// Accepts tokens from `issuer` signed with `secret` (HS256) only.
    pub fn with_secret(issuer: &str, secret: &str) -> Self {
        Self::new(issuer.to_owned(), Some(secret))
    }

    /// Accepts tokens from `issuer` signed by a key in `jwks`, never fetching.
    pub fn with_jwks(issuer: &str, jwks: &str) -> Result<Self> {
        let verifier = Self::new(issuer.to_owned(), None);
        verifier.load(jwks)?;
        Ok(verifier)
    }

    fn new(issuer: String, secret: Option<&str>) -> Self {
        Verifier {
            issuer,
            jwks_url: None,
            secret: secret.map(|secret| DecodingKey::from_secret(secret.as_bytes())),
            keys: RwLock::default(),
            fetched: RwLock::default(),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("a reqwest client with only a timeout builds"),
        }
    }

    fn load(&self, jwks: &str) -> Result<()> {
        let set: JwkSet = serde_json::from_str(jwks)
            .map_err(|e| AppError::Internal(format!("unreadable key set: {e}")))?;
        let mut keys = HashMap::new();
        for jwk in &set.keys {
            let (Some(kid), Some(alg)) = (jwk.common.key_id.clone(), jwk.common.key_algorithm)
            else {
                continue;
            };
            let Ok(alg) = alg.to_string().parse::<Algorithm>() else {
                continue;
            };
            if let Ok(key) = DecodingKey::from_jwk(jwk) {
                keys.insert(kid, (key, alg));
            }
        }
        *self.keys.write().expect("keys lock") = keys;
        Ok(())
    }

    async fn refresh(&self) -> Result<()> {
        let Some(url) = &self.jwks_url else {
            return Ok(());
        };
        {
            let fetched = self.fetched.read().expect("fetched lock");
            if fetched.is_some_and(|at| at.elapsed() < REFETCH_AFTER) {
                return Ok(());
            }
        }
        *self.fetched.write().expect("fetched lock") = Some(Instant::now());
        let body = self
            .client
            .get(url)
            .send()
            .await
            .and_then(reqwest::Response::error_for_status)
            .map_err(|e| AppError::Internal(format!("fetching the key set: {e}")))?
            .text()
            .await
            .map_err(|e| AppError::Internal(format!("reading the key set: {e}")))?;
        self.load(&body)
    }

    /// The caller a token proves, or `Unauthorized` for anything short of a
    /// valid, unexpired user token from this project.
    pub async fn verify(&self, token: &str) -> Result<(Uuid, Option<String>)> {
        let header = decode_header(token).map_err(|_| AppError::Unauthorized)?;
        let (key, alg) = if header.alg == Algorithm::HS256 {
            let secret = self.secret.clone().ok_or(AppError::Unauthorized)?;
            (secret, Algorithm::HS256)
        } else {
            let kid = header.kid.ok_or(AppError::Unauthorized)?;
            let known = self.keys.read().expect("keys lock").get(&kid).cloned();
            let found = match known {
                Some(found) => Some(found),
                None => {
                    // A key we haven't seen: the project may have rotated.
                    self.refresh().await?;
                    self.keys.read().expect("keys lock").get(&kid).cloned()
                }
            };
            found.ok_or(AppError::Unauthorized)?
        };
        if alg != header.alg {
            return Err(AppError::Unauthorized);
        }

        let mut validation = Validation::new(alg);
        validation.set_audience(&["authenticated"]);
        validation.set_issuer(&[&self.issuer]);
        let claims = decode::<Claims>(token, &key, &validation)
            .map_err(|_| AppError::Unauthorized)?
            .claims;
        if claims.role.as_deref() != Some("authenticated") {
            return Err(AppError::Unauthorized);
        }
        let account = Uuid::parse_str(&claims.sub).map_err(|_| AppError::Unauthorized)?;
        Ok((account, claims.email))
    }
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

fn device_id(headers: &HeaderMap) -> Result<Option<Uuid>> {
    let Some(value) = headers.get(DEVICE_HEADER) else {
        return Ok(None);
    };
    value
        .to_str()
        .ok()
        .and_then(|text| Uuid::parse_str(text.trim()).ok())
        .map(Some)
        .ok_or_else(|| AppError::BadRequest(format!("{DEVICE_HEADER} is not a uuid")))
}

/// Middleware for every route that needs a signed-in user. Touches the
/// device's `last_seen_at` on the way, so the device list shows which are
/// still syncing.
pub async fn require_user(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response> {
    let token = bearer(request.headers()).ok_or(AppError::Unauthorized)?;
    let (account, email) = state.verifier.verify(token).await?;
    let device = device_id(request.headers())?;
    if let Some(device) = device {
        sqlx::query("UPDATE devices SET last_seen_at = now() WHERE id = $1 AND account_id = $2")
            .bind(device)
            .bind(account)
            .execute(&state.pool)
            .await?;
    }
    request.extensions_mut().insert(Caller {
        account,
        email,
        device,
    });
    Ok(next.run(request).await)
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{EncodingKey, Header, encode};
    use serde_json::json;

    const ISSUER: &str = "https://example.supabase.co/auth/v1";
    const USER: &str = "6f1c1f9e-2a4b-4c55-9d0e-1a2b3c4d5e6f";

    /// A throwaway P-256 key, made for these tests and used nowhere else.
    const EC_PRIVATE: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgypKY4u7/jCnQWKup
H3zFf/VgL3GwhAj9zYO04s+AdDyhRANCAAS3aR0qiG9wmU00685wwCMw7KKzUtmc
Y0n5D5E5J6BugCwN/1kNn5nOxyExZhNLvA8XCzu2nnaT3ntsZXmuMzvf
-----END PRIVATE KEY-----";

    fn jwks() -> String {
        json!({"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "kid": "k1", "use": "sig",
            "x": "t2kdKohvcJlNNOvOcMAjMOyis1LZnGNJ-Q-ROSegboA",
            "y": "LA3_WQ2fmc7HITFmE0u8DxcLO7aedpPee2xlea4zO98"}]})
        .to_string()
    }

    fn claims(issuer: &str, role: &str, exp_from_now: i64) -> serde_json::Value {
        json!({"sub": USER, "email": "me@example.com", "role": role, "aud": "authenticated",
               "iss": issuer, "exp": chrono::Utc::now().timestamp() + exp_from_now})
    }

    fn es256(kid: &str, claims: &serde_json::Value) -> String {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(kid.into());
        let key = EncodingKey::from_ec_pem(EC_PRIVATE.as_bytes()).expect("key");
        encode(&header, claims, &key).expect("token")
    }

    #[tokio::test]
    async fn a_token_signed_by_the_published_key_is_the_user() {
        let verifier = Verifier::with_jwks(ISSUER, &jwks()).expect("jwks");
        let token = es256("k1", &claims(ISSUER, "authenticated", 600));
        let (account, email) = verifier.verify(&token).await.expect("valid");
        assert_eq!(account.to_string(), USER);
        assert_eq!(email.as_deref(), Some("me@example.com"));
    }

    #[tokio::test]
    async fn anything_else_is_refused() {
        let verifier = Verifier::with_jwks(ISSUER, &jwks()).expect("jwks");
        for token in [
            es256("k1", &claims(ISSUER, "authenticated", -600)),
            es256(
                "k1",
                &claims("https://other.supabase.co/auth/v1", "authenticated", 600),
            ),
            es256("k1", &claims(ISSUER, "anon", 600)),
            es256("unknown", &claims(ISSUER, "authenticated", 600)),
            "not a token".to_owned(),
        ] {
            assert!(verifier.verify(&token).await.is_err());
        }
        // HS256 with no secret configured: refused, not trusted.
        let hs = encode(
            &Header::new(Algorithm::HS256),
            &claims(ISSUER, "authenticated", 600),
            &EncodingKey::from_secret(b"guess"),
        )
        .expect("token");
        assert!(verifier.verify(&hs).await.is_err());
    }

    #[tokio::test]
    async fn a_legacy_secret_signs_hs256_tokens() {
        let verifier = Verifier::with_secret(ISSUER, "s3cret");
        let sign = |secret: &[u8]| {
            encode(
                &Header::new(Algorithm::HS256),
                &claims(ISSUER, "authenticated", 600),
                &EncodingKey::from_secret(secret),
            )
            .expect("token")
        };
        assert!(verifier.verify(&sign(b"s3cret")).await.is_ok());
        assert!(verifier.verify(&sign(b"wrong")).await.is_err());
    }
}
