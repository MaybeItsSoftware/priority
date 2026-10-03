//! The row-sync server Priority's apps replicate their workspace through.
//!
//! docs/sync.md is the protocol; this is its server half. The server stores
//! rows and merges them by per-column last-write-wins. It knows nothing about
//! tasks, so a schema change on the clients needs no change here.
//!
//! Anyone can make an account (`accounts.rs`). Every row, device and pairing
//! code belongs to one account, and a device only ever sees its own account's
//! rows.

pub mod accounts;
pub mod auth;
pub mod changes;
pub mod config;
pub mod error;
pub mod mail;
pub mod merge;
pub mod notify;
pub mod pairing;
pub mod push;
pub mod reset;

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::{Json, Router, middleware};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::sync::Arc;
use tokio::sync::watch;
use tower_http::compression::CompressionLayer;
use tower_http::trace::TraceLayer;

/// A first sync pushes every row a device has in batches of 500; this leaves
/// room for wide rows (long notes) without letting one request eat the memory
/// of a small Railway container.
const BODY_LIMIT: usize = 10 * 1024 * 1024;

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    /// Failed sign-ins per email, to stop password guessing.
    pub sign_ins: Arc<accounts::SignInLimiter>,
    /// How password reset links are sent; `None` without a Resend key.
    pub reset: Option<Arc<reset::ResetMail>>,
    /// Bumped whenever any process commits a push. See `notify.rs`.
    pub changes: watch::Receiver<u64>,
    /// Flips to true on SIGTERM so long-polls answer at once rather than
    /// holding the shutdown up for their full 25 seconds.
    pub shutdown: watch::Receiver<bool>,
}

pub fn router(state: AppState) -> Router {
    let device_routes = Router::new()
        .route("/v1/push", post(push::push))
        .route("/v1/changes", get(changes::changes))
        .route("/v1/pairing-codes", post(pairing::create_code))
        .route("/v1/account", get(accounts::account))
        .route("/v1/account/delete", post(accounts::delete_account))
        .route("/v1/sign-out", post(accounts::sign_out))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_device,
        ));
    Router::new()
        .route("/health", get(health))
        .route("/v1/accounts", post(accounts::sign_up))
        .route("/v1/sessions", post(accounts::sign_in))
        .route("/v1/pair", post(pairing::pair))
        .route("/v1/password-reset", post(reset::request))
        .route("/reset", get(reset::page).post(reset::submit))
        .merge(device_routes)
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .layer(CompressionLayer::new().gzip(true))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}
