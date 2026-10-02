//! End-to-end tests against a real Postgres. `#[sqlx::test]` creates a fresh
//! database per test from `DATABASE_URL` and runs the migrations into it; see
//! README.md for starting a throwaway server.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use priority_sync_server::{AppState, MIGRATOR, notify, router};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;
use tower::ServiceExt;

const ADMIN: &str = "test-admin-token";

struct Server {
    app: Router,
    _stop: watch::Sender<bool>,
}

async fn server(pool: PgPool, admin: Option<&str>) -> Server {
    let changes = notify::spawn_listener(&pool).await.expect("listen");
    let (stop, shutdown) = watch::channel(false);
    let state = AppState {
        pool,
        admin_token: admin.map(Arc::from),
        changes,
        shutdown,
    };
    Server {
        app: router(state),
        _stop: stop,
    }
}

impl Server {
    async fn call(
        &self,
        method: &str,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut request = Request::builder().method(method).uri(uri);
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let request = match body {
            Some(body) => request
                .header("content-type", "application/json")
                .body(Body::from(body.to_string())),
            None => request.body(Body::empty()),
        }
        .expect("request");
        let response = self.app.clone().oneshot(request).await.expect("response");
        let status = response.status();
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("body")
            .to_bytes();
        let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, value)
    }

    async fn pair_admin(&self, name: &str) -> (String, String) {
        let (status, body) = self
            .call(
                "POST",
                "/v1/pair",
                None,
                Some(json!({"adminToken": ADMIN, "deviceName": name, "platform": "macos"})),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        (
            body["deviceId"].as_str().expect("deviceId").to_owned(),
            body["token"].as_str().expect("token").to_owned(),
        )
    }

    async fn pair_with_code(&self, inviter: &str, name: &str) -> String {
        let (status, body) = self
            .call("POST", "/v1/pairing-codes", Some(inviter), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let code = body["code"].as_str().expect("code").to_owned();
        let (status, body) = self
            .call(
                "POST",
                "/v1/pair",
                None,
                Some(json!({"code": code, "deviceName": name, "platform": "ios"})),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["token"].as_str().expect("token").to_owned()
    }

    async fn push(&self, token: &str, changes: Value) -> Value {
        let (status, body) = self
            .call(
                "POST",
                "/v1/push",
                Some(token),
                Some(json!({ "changes": changes })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    async fn changes(&self, token: &str, query: &str) -> Value {
        let (status, body) = self
            .call("GET", &format!("/v1/changes?{query}"), Some(token), None)
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }
}

fn hlc(ms: u64, device: &str) -> String {
    format!("{ms:013}-0000-{device}")
}

fn ids(page: &Value) -> Vec<String> {
    page["rows"]
        .as_array()
        .expect("rows")
        .iter()
        .map(|row| row["id"].as_str().expect("id").to_owned())
        .collect()
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn health_answers_ok(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (status, body) = server.call("GET", "/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"ok": true}));
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn pairing_codes_work_once_and_admin_is_checked(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;

    let (status, _) = server
        .call(
            "POST",
            "/v1/pair",
            None,
            Some(json!({"adminToken": "wrong", "deviceName": "x", "platform": "x"})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // The admin token itself can mint a code too.
    let (status, body) = server
        .call("POST", "/v1/pairing-codes", Some(ADMIN), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["expiresAt"].is_string());

    let (status, body) = server
        .call("POST", "/v1/pairing-codes", Some(&mac), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    let code = body["code"].as_str().expect("code").to_lowercase();
    let pair = json!({"code": code, "deviceName": "Phone", "platform": "ios"});
    let (status, _) = server
        .call("POST", "/v1/pair", None, Some(pair.clone()))
        .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = server.call("POST", "/v1/pair", None, Some(pair)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "a code works once");

    let (status, _) = server
        .call("POST", "/v1/pairing-codes", Some("nobody"), None)
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn admin_pairing_is_disabled_without_the_token(pool: PgPool) {
    let server = server(pool, None).await;
    let (status, _) = server
        .call(
            "POST",
            "/v1/pair",
            None,
            Some(json!({"adminToken": "", "deviceName": "Mac", "platform": "macos"})),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = server
        .call("POST", "/v1/pairing-codes", Some(""), None)
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn device_routes_need_a_paired_token(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (status, _) = server.call("GET", "/v1/changes", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = server
        .call(
            "POST",
            "/v1/push",
            Some(ADMIN),
            Some(json!({"changes": []})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "admin is not a device");
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn pair_push_and_pull_round_trip(pool: PgPool) {
    let server = server(pool.clone(), Some(ADMIN)).await;
    let (mac_id, mac) = server.pair_admin("Mac").await;
    let phone = server.pair_with_code(&mac, "Phone").await;

    let pushed = server
        .push(
            &mac,
            json!([
                {"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"),
                 "values": {"title": "Buy milk", "sortOrder": 0, "dueAt": null}},
                {"table": "task_lists", "id": "L1", "op": "upsert", "hlc": hlc(1000, "mac"),
                 "values": {"name": "Inbox"}},
            ]),
        )
        .await;
    assert_eq!(pushed["accepted"], 2);
    assert_eq!(pushed["cursor"], 2);

    let page = server.changes(&phone, "since=0").await;
    assert_eq!(page["cursor"], 2);
    assert_eq!(page["hasMore"], false);
    assert_eq!(
        page["rows"][0],
        json!({"table": "tasks", "id": "T1", "deleted": false,
               "values": {"title": "Buy milk", "sortOrder": 0, "dueAt": null},
               "hlc": hlc(1000, "mac")})
    );

    // The phone edits another column; the Mac, offline, renamed it earlier.
    server
        .push(
            &phone,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(3000, "phone"),
                    "values": {"notes": "oat"}}]),
        )
        .await;
    server
        .push(
            &mac,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(2000, "mac"),
                    "values": {"title": "Buy oat milk", "notes": "stale"}}]),
        )
        .await;
    let page = server.changes(&phone, "since=2").await;
    let row = &page["rows"][page["rows"].as_array().expect("rows").len() - 1];
    assert_eq!(row["values"]["title"], "Buy oat milk");
    assert_eq!(row["values"]["notes"], "oat");
    assert_eq!(row["hlc"], hlc(3000, "phone"));

    // lastDeviceId is the latest pusher, diagnostics only.
    let last: Option<uuid::Uuid> = sqlx::query_scalar(
        "SELECT last_device_id FROM rows WHERE table_name = 'tasks' AND row_id = 'T1'",
    )
    .fetch_one(&pool)
    .await
    .expect("row");
    assert_eq!(last.map(|id| id.to_string()), Some(mac_id));

    // Delete, then a stale edit, then a resurrecting one.
    server
        .push(
            &phone,
            json!([{"table": "tasks", "id": "T1", "op": "delete", "hlc": hlc(4000, "phone")}]),
        )
        .await;
    let page = server.changes(&mac, "since=4").await;
    assert_eq!(page["rows"][0]["deleted"], true);
    assert_eq!(page["rows"][0]["hlc"], hlc(4000, "phone"));
    let cursor = page["cursor"].as_i64().expect("cursor");

    let stale = server
        .push(
            &mac,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(3500, "mac"),
                    "values": {"title": "too late"}}]),
        )
        .await;
    assert_eq!(stale["cursor"], cursor, "a losing change writes nothing");
    server
        .push(
            &mac,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(5000, "mac"),
                    "values": {"title": "undeleted"}}]),
        )
        .await;
    let page = server.changes(&phone, &format!("since={cursor}")).await;
    assert_eq!(page["rows"][0]["deleted"], false);
    assert_eq!(page["rows"][0]["values"]["title"], "undeleted");
    assert_eq!(page["rows"][0]["values"]["notes"], "oat");
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn the_caller_receives_its_own_rows(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;
    server
        .push(
            &mac,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"),
                    "values": {"title": "mine"}}]),
        )
        .await;
    let page = server.changes(&mac, "since=0").await;
    assert_eq!(ids(&page), vec!["T1"]);
    assert_eq!(page["rows"][0]["values"]["title"], "mine");
    assert_eq!(page["cursor"], 1);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn pages_resume_from_the_cursor_without_gaps(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;
    let phone = server.pair_with_code(&mac, "Phone").await;
    let changes: Vec<Value> = (0..5)
        .map(|n| {
            json!({"table": "tasks", "id": format!("T{n}"), "op": "upsert",
                   "hlc": hlc(1000 + n, "mac"), "values": {"n": n}})
        })
        .collect();
    server.push(&mac, Value::Array(changes)).await;

    let mut seen = Vec::new();
    let mut cursor = 0;
    loop {
        let page = server
            .changes(&phone, &format!("since={cursor}&limit=2"))
            .await;
        seen.extend(ids(&page));
        cursor = page["cursor"].as_i64().expect("cursor");
        if page["hasMore"] == false {
            break;
        }
    }
    assert_eq!(seen, vec!["T0", "T1", "T2", "T3", "T4"]);
    assert_eq!(cursor, 5);

    // An empty page keeps the cursor where it was.
    let page = server.changes(&phone, &format!("since={cursor}")).await;
    assert_eq!(page["rows"], json!([]));
    assert_eq!(page["cursor"], cursor);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn re_pushing_a_batch_changes_nothing(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;
    let batch = json!([
        {"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"), "values": {"title": "a"}},
        {"table": "tasks", "id": "T2", "op": "delete", "hlc": hlc(1000, "mac")},
    ]);
    let first = server.push(&mac, batch.clone()).await;
    let second = server.push(&mac, batch).await;
    assert_eq!(first["cursor"], 2);
    assert_eq!(second["cursor"], 2);
    assert_eq!(second["accepted"], 2);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn malformed_changes_are_refused_whole(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;
    let (status, _) = server
        .call(
            "POST",
            "/v1/push",
            Some(&mac),
            Some(json!({"changes": [
                {"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"), "values": {"a": 1}},
                {"table": "tasks", "id": "T2", "op": "upsert", "hlc": "yesterday", "values": {"a": 1}},
            ]})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = server
        .call(
            "POST",
            "/v1/push",
            Some(&mac),
            Some(json!({"changes": [
                {"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"), "values": {"a": [1]}},
            ]})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let page = server.changes(&mac, "since=0").await;
    assert_eq!(
        page["rows"],
        json!([]),
        "nothing from a refused batch landed"
    );
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn a_long_poll_wakes_when_another_device_pushes(pool: PgPool) {
    let server = Arc::new(server(pool, Some(ADMIN)).await);
    let (_, mac) = server.pair_admin("Mac").await;
    let phone = server.pair_with_code(&mac, "Phone").await;

    let started = Instant::now();
    let waiter = {
        let server = Arc::clone(&server);
        tokio::spawn(async move { server.changes(&phone, "since=0&wait=20").await })
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!waiter.is_finished(), "nothing to send yet, so it waits");
    server
        .push(
            &mac,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "mac"),
                    "values": {"title": "ping"}}]),
        )
        .await;
    let page = tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .expect("woken well before its wait ran out")
        .expect("task");
    assert_eq!(ids(&page), vec!["T1"]);
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn an_idle_long_poll_returns_empty_when_its_wait_runs_out(pool: PgPool) {
    let server = server(pool, Some(ADMIN)).await;
    let (_, mac) = server.pair_admin("Mac").await;
    let started = Instant::now();
    let page = server.changes(&mac, "since=0&wait=1").await;
    assert!(started.elapsed() >= Duration::from_millis(900));
    assert_eq!(page["rows"], json!([]));
    assert_eq!(page["cursor"], 0);
    assert_eq!(page["hasMore"], false);
}
