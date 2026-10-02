use priority_sync_server::config::Config;
use priority_sync_server::{AppState, MIGRATOR, notify, router};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // JSON lines, because Railway's log viewer indexes the fields.
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = Config::from_env()?;
    if config.admin_token.is_none() {
        tracing::warn!(
            "SYNC_ADMIN_TOKEN is not set: admin pairing is DISABLED. No first device can pair, \
             and pairing codes can only be minted by an already paired device. Set it with \
             `openssl rand -hex 32`."
        );
    }

    // Long-polls hold no connection while they wait, so a small pool serves
    // many devices.
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(10))
        .connect(&config.database_url)
        .await?;
    MIGRATOR.run(&pool).await?;
    tracing::info!("migrations applied");

    let changes = notify::spawn_listener(&pool).await?;
    let (stop, shutdown) = watch::channel(false);
    let state = AppState {
        pool,
        admin_token: config.admin_token.map(Arc::from),
        changes,
        shutdown,
    };

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", config.port)).await?;
    tracing::info!(port = config.port, "listening");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async move {
            shutdown_signal().await;
            tracing::info!("shutting down");
            let _ = stop.send(true);
        })
        .await?;
    Ok(())
}

/// SIGTERM is what Railway sends on redeploy; ctrl-c is for running locally.
async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            tracing::error!(%error, "could not listen for ctrl-c");
            std::future::pending::<()>().await;
        }
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(error) => {
                tracing::error!(%error, "could not listen for SIGTERM");
                std::future::pending::<()>().await;
            }
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {}
        () = terminate => {}
    }
}
