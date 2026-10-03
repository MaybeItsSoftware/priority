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
| `src/accounts.rs` | Sign up, sign in and out, the account's devices, deleting an account |
| `src/pairing.rs` | `POST /v1/pairing-codes` and `POST /v1/pair` |
| `src/auth.rs` | Bearer tokens, stored as sha256 |
| `migrations/` | The Postgres schema, applied at boot |

## Configuration

| Variable | |
| --- | --- |
| `DATABASE_URL` | Required. |
| `PORT` | Default 8080. |
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
