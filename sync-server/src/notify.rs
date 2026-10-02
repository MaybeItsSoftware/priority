//! Waking long-polls when rows change, through Postgres `LISTEN/NOTIFY`.
//!
//! A push NOTIFYs on [`CHANNEL`] as it commits. One task per process LISTENs
//! and bumps a `watch` counter, which every waiting `/v1/changes` request is
//! subscribed to. Going through Postgres rather than straight from the push
//! handler to the watch is what keeps this right with more than one replica:
//! a push to one wakes long-polls held by any of them.

use sqlx::PgPool;
use sqlx::postgres::PgListener;
use std::time::Duration;
use tokio::sync::watch;

pub const CHANNEL: &str = "rows_changed";

/// Starts listening and returns the counter it bumps.
///
/// Returns only once the LISTEN is in place, so nothing pushed after this
/// returns can be missed.
pub async fn spawn_listener(pool: &PgPool) -> Result<watch::Receiver<u64>, sqlx::Error> {
    let mut listener = PgListener::connect_with(pool).await?;
    listener.listen(CHANNEL).await?;
    let (sender, receiver) = watch::channel(0u64);
    tokio::spawn(async move {
        loop {
            let received = tokio::select! {
                received = listener.try_recv() => received,
                // Nobody left to wake: the server is gone. Dropping the
                // listener hands its connection back, which `PgPool::close`
                // otherwise waits on for ever.
                () = sender.closed() => return,
            };
            match received {
                Ok(Some(_)) => sender.send_modify(|count| *count = count.wrapping_add(1)),
                Ok(None) => {
                    // The connection dropped and anything NOTIFYed meanwhile
                    // is gone. Wake everyone so they re-read the table rather
                    // than sleep through rows they were owed; the next
                    // `try_recv` reconnects and re-LISTENs.
                    tracing::warn!("lost the LISTEN connection; reconnecting");
                    sender.send_modify(|count| *count = count.wrapping_add(1));
                }
                Err(error) => {
                    tracing::error!(%error, "LISTEN failed; retrying");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    });
    Ok(receiver)
}
