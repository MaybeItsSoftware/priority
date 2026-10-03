# priority-sync-server

The row-sync server Priority's Mac, iPhone and Android apps replicate their
workspace through. `../docs/sync.md` is the protocol; this crate is its server
half. It stores rows and merges them by per-column last-write-wins, and knows
nothing about tasks.

## Layout

| File | What |
| --- | --- |
| `src/merge.rs` | The merge rule, pure and unit-tested without a database |
| `src/push.rs` | `POST /v1/push`: one transaction per push, serialised by an advisory lock |
| `src/changes.rs` | `GET /v1/changes`: the paged feed and its long-poll |
| `src/notify.rs` | `LISTEN rows_changed`, fanned out to waiting long-polls |
| `src/auth.rs` | Checking the Supabase access token each request carries |
| `src/devices.rs` | Registering a device, the account's devices, signing out, deleting an account |
| `migrations/` | The Postgres schema, applied at boot |

## Configuration

| Variable | |
| --- | --- |
| `DATABASE_URL` | Required. On Supabase, the **session** pooler (port 5432): `LISTEN` needs a session, which the transaction pooler (6543) doesn't keep. The server keeps its tables in a `sync` schema, which the Data API doesn't expose. |
| `PORT` | Default 8080. |
| `SUPABASE_URL` | Required. The project the apps sign in with, `https://<ref>.supabase.co`. Tokens are checked against its published keys (`/auth/v1/.well-known/jwks.json`). |
| `SUPABASE_JWT_SECRET` | Only for a project still signing with the legacy shared secret (HS256). |
| `SUPABASE_SECRET_KEY` | The project's secret API key, used only to delete the Supabase user when an account is deleted. Without it deleting answers 503. |
| `RUST_LOG` | Log filter, default `info`. Logs are JSON lines. |

## Running locally

```bash
DATABASE_URL=postgres://localhost/priority_sync cargo run
```

## Tests

The unit tests need nothing. The integration tests in `tests/api.rs` need a
Postgres server: `#[sqlx::test]` creates a fresh database per test from
`DATABASE_URL`, so the user in it must be able to `CREATE DATABASE`.

A throwaway server with Homebrew's Postgres:

```bash
PGDIR=$(mktemp -d)
initdb -D "$PGDIR/data" -U postgres --auth=trust >/dev/null
pg_ctl -D "$PGDIR/data" -o "-p 54329 -k $PGDIR" -l "$PGDIR/log" start

DATABASE_URL=postgres://postgres@localhost:54329/postgres cargo test

pg_ctl -D "$PGDIR/data" stop && rm -rf "$PGDIR"
```

Or with Docker:

```bash
docker run --rm -d --name sync-pg -e POSTGRES_HOST_AUTH_METHOD=trust -p 54329:5432 postgres:16
DATABASE_URL=postgres://postgres@localhost:54329/postgres cargo test
docker stop sync-pg
```

The gates:

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
docker build .
```

## Deploying

Railway, from this directory: see the comments in `railway.toml`.
