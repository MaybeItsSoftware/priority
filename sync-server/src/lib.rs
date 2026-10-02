//! The row-sync server Priority's apps replicate their workspace through.
//!
//! docs/sync.md is the protocol; this is its server half. The server stores
//! rows and merges them by per-column last-write-wins. It knows nothing about
//! tasks, so a schema change on the clients needs no change here.

pub mod auth;
pub mod changes;
pub mod config;
pub mod error;
pub mod merge;
pub mod notify;
pub mod pairing;
pub mod push;

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
    pub admin_token: Option<Arc<str>>,
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
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_device,
        ));
    Router::new()
        .route("/health", get(health))
        .route("/v1/pairing-codes", post(pairing::create_code))
        .route("/v1/pair", post(pairing::pair))
        .merge(device_routes)
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .layer(CompressionLayer::new().gzip(true))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}
