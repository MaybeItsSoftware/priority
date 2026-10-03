//! End-to-end tests against a real Postgres. `#[sqlx::test]` creates a fresh
//! database per test from `DATABASE_URL` and runs the migrations into it; see
//! README.md for starting a throwaway server.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use priority_sync_server::mail::{Mailer, Message, SendResult};
use priority_sync_server::reset::ResetMail;
use priority_sync_server::{AppState, MIGRATOR, notify, router};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::sync::watch;
use tower::ServiceExt;

const PASSWORD: &str = "correct horse battery";

struct Server {
    app: Router,
    _stop: watch::Sender<bool>,
}

async fn server(pool: PgPool) -> Server {
    server_with(pool, None).await
}

/// Keeps every email "sent", for the tests to read the reset link out of.
struct OutBox(mpsc::UnboundedSender<Message>);

impl Mailer for OutBox {
    fn send(&self, message: Message) -> Pin<Box<dyn Future<Output = SendResult> + Send + '_>> {
        let _ = self.0.send(message);
        Box::pin(async { Ok(()) })
    }
}

async fn server_with_mail(pool: PgPool) -> (Server, mpsc::UnboundedReceiver<Message>) {
    let (sender, receiver) = mpsc::unbounded_channel();
    let reset = ResetMail {
        mailer: Box::new(OutBox(sender)),
        public_url: "https://sync.example.com".into(),
    };
    (server_with(pool, Some(Arc::new(reset))).await, receiver)
}

async fn server_with(pool: PgPool, reset: Option<Arc<ResetMail>>) -> Server {
    let changes = notify::spawn_listener(&pool).await.expect("listen");
    let (stop, shutdown) = watch::channel(false);
    let state = AppState {
        pool,
        sign_ins: Arc::default(),
        reset,
        changes,
        shutdown,
    };
    Server {
        app: router(state),
        _stop: stop,
    }
}

impl Server {
    /// A page request, form-encoded when there is a body; returns the HTML.
    async fn page(&self, method: &str, uri: &str, form: Option<&str>) -> (StatusCode, String) {
        let request = Request::builder().method(method).uri(uri);
        let request = match form {
            Some(form) => request
                .header("content-type", "application/x-www-form-urlencoded")
                .body(Body::from(form.to_owned())),
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
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

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

    async fn sign_up(&self, email: &str, name: &str) -> (String, String) {
        let (status, body) = self
            .call(
                "POST",
                "/v1/accounts",
                None,
                Some(json!({"email": email, "password": PASSWORD, "deviceName": name, "platform": "macos"})),
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
    let server = server(pool).await;
    let (status, body) = server.call("GET", "/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"ok": true}));
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn pairing_codes_work_once(pool: PgPool) {
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;

    let (status, body) = server
        .call("POST", "/v1/pairing-codes", Some(&mac), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["expiresAt"].is_string());
    let code = body["code"].as_str().expect("code").to_lowercase();
    let pair = json!({"code": code, "deviceName": "Phone", "platform": "ios"});
    let (status, body) = server
        .call("POST", "/v1/pair", None, Some(pair.clone()))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["email"], "me@example.com", "the code's account");
    let (status, _) = server.call("POST", "/v1/pair", None, Some(pair)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "a code works once");

    let (status, _) = server
        .call("POST", "/v1/pairing-codes", Some("nobody"), None)
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = server.call("POST", "/v1/pairing-codes", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn anyone_can_sign_up_once_per_email_and_sign_in_again(pool: PgPool) {
    let server = server(pool).await;
    let sign_up = |email: &str, password: &str| json!({"email": email, "password": password, "deviceName": "Mac", "platform": "macos"});

    let (status, body) = server
        .call(
            "POST",
            "/v1/accounts",
            None,
            Some(sign_up(" Me@Example.com ", PASSWORD)),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["email"], "me@example.com");
    let account = body["accountId"].clone();

    let (status, _) = server
        .call(
            "POST",
            "/v1/accounts",
            None,
            Some(sign_up("ME@example.com", PASSWORD)),
        )
        .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "one account per email, any case"
    );
    let (status, _) = server
        .call(
            "POST",
            "/v1/accounts",
            None,
            Some(sign_up("you@example.com", "short")),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = server
        .call(
            "POST",
            "/v1/accounts",
            None,
            Some(sign_up("not an email", PASSWORD)),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, body) = server
        .call(
            "POST",
            "/v1/sessions",
            None,
            Some(sign_up("me@EXAMPLE.com", PASSWORD)),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["accountId"], account);
    assert!(body["token"].is_string());

    let (status, body) = server
        .call(
            "POST",
            "/v1/sessions",
            None,
            Some(sign_up("me@example.com", "wrong password")),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], "wrong email or password");
    let (status, body) = server
        .call(
            "POST",
            "/v1/sessions",
            None,
            Some(sign_up("nobody@example.com", PASSWORD)),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        body["error"], "wrong email or password",
        "no hint who has an account"
    );
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn too_many_wrong_passwords_lock_the_email(pool: PgPool) {
    let server = server(pool).await;
    server.sign_up("me@example.com", "Mac").await;
    let attempt = |password: &str| json!({"email": "me@example.com", "password": password, "deviceName": "x", "platform": "x"});
    for _ in 0..10 {
        let (status, _) = server
            .call("POST", "/v1/sessions", None, Some(attempt("guess guess")))
            .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    let (status, _) = server
        .call("POST", "/v1/sessions", None, Some(attempt(PASSWORD)))
        .await;
    assert_eq!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "even the right one, for a while"
    );
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn accounts_never_see_each_others_rows(pool: PgPool) {
    let server = server(pool).await;
    let (_, mine) = server.sign_up("me@example.com", "Mac").await;
    let (_, yours) = server.sign_up("you@example.com", "Mac").await;

    // The same row id in both accounts: two separate rows.
    server
        .push(
            &mine,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "a"),
                    "values": {"title": "mine"}}]),
        )
        .await;
    server
        .push(
            &yours,
            json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(500, "b"),
                    "values": {"title": "yours"}},
                   {"table": "tasks", "id": "T2", "op": "upsert", "hlc": hlc(500, "b"),
                    "values": {"title": "also yours"}}]),
        )
        .await;

    let page = server.changes(&mine, "since=0").await;
    assert_eq!(ids(&page), vec!["T1"]);
    assert_eq!(page["rows"][0]["values"]["title"], "mine");
    let page = server.changes(&yours, "since=0").await;
    assert_eq!(ids(&page), vec!["T1", "T2"]);
    assert_eq!(
        page["rows"][0]["values"]["title"], "yours",
        "an older hlc, but not a rival"
    );
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn signing_out_revokes_only_that_device(pool: PgPool) {
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
    let phone = server.pair_with_code(&mac, "Phone").await;

    let (status, body) = server.call("GET", "/v1/account", Some(&mac), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["email"], "me@example.com");
    let devices = body["devices"].as_array().expect("devices");
    assert_eq!(devices.len(), 2);
    assert_eq!(devices[0]["name"], "Mac");
    assert_eq!(devices[0]["current"], true);
    assert_eq!(devices[1]["current"], false);

    let (status, _) = server
        .call("POST", "/v1/sign-out", Some(&phone), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = server.call("GET", "/v1/changes", Some(&phone), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = server.call("GET", "/v1/changes", Some(&mac), None).await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn deleting_an_account_takes_its_rows_and_devices(pool: PgPool) {
    let server = server(pool.clone()).await;
    let (_, mine) = server.sign_up("me@example.com", "Mac").await;
    let (_, yours) = server.sign_up("you@example.com", "Mac").await;
    for token in [&mine, &yours] {
        server
            .push(
                token,
                json!([{"table": "tasks", "id": "T1", "op": "upsert", "hlc": hlc(1000, "a"),
                        "values": {"title": "x"}}]),
            )
            .await;
    }

    let (status, _) = server
        .call(
            "POST",
            "/v1/account/delete",
            Some(&mine),
            Some(json!({"password": "wrong"})),
        )
        .await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "the password is asked for again"
    );
    let (status, _) = server
        .call(
            "POST",
            "/v1/account/delete",
            Some(&mine),
            Some(json!({"password": PASSWORD})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = server.call("GET", "/v1/changes", Some(&mine), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let left: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM rows")
        .fetch_one(&pool)
        .await
        .expect("count");
    assert_eq!(left, 1, "only the other account's row");
    let (status, _) = server
        .call(
            "POST",
            "/v1/accounts",
            None,
            Some(json!({"email": "me@example.com", "password": PASSWORD})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "the email is free again");
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn device_routes_need_a_signed_in_token(pool: PgPool) {
    let server = server(pool).await;
    let (status, _) = server.call("GET", "/v1/changes", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = server
        .call(
            "POST",
            "/v1/push",
            Some("nobody"),
            Some(json!({"changes": []})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = server.call("GET", "/v1/account", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn pair_push_and_pull_round_trip(pool: PgPool) {
    let server = server(pool.clone()).await;
    let (mac_id, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = Arc::new(server(pool).await);
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
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
    let server = server(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
    let started = Instant::now();
    let page = server.changes(&mac, "since=0&wait=1").await;
    assert!(started.elapsed() >= Duration::from_millis(900));
    assert_eq!(page["rows"], json!([]));
    assert_eq!(page["cursor"], 0);
    assert_eq!(page["hasMore"], false);
}

/// The token in a reset email's link.
fn reset_token(message: &Message) -> String {
    let start = message.text.find("token=").expect("a link") + "token=".len();
    message.text[start..start + 64].to_owned()
}

async fn next_mail(outbox: &mut mpsc::UnboundedReceiver<Message>) -> Message {
    tokio::time::timeout(Duration::from_secs(10), outbox.recv())
        .await
        .expect("an email in time")
        .expect("an email")
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn reset_says_so_when_mail_is_not_set_up(pool: PgPool) {
    let server = server(pool).await;
    let (status, body) = server
        .call(
            "POST",
            "/v1/password-reset",
            None,
            Some(json!({"email": "me@example.com"})),
        )
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "password reset isn't set up on this server");
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn a_reset_link_sets_a_new_password_once_and_signs_every_device_out(pool: PgPool) {
    let (server, mut outbox) = server_with_mail(pool).await;
    let (_, mac) = server.sign_up("me@example.com", "Mac").await;
    let phone = server.pair_with_code(&mac, "Phone").await;

    let (status, body) = server
        .call(
            "POST",
            "/v1/password-reset",
            None,
            Some(json!({"email": " ME@example.com"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let mail = next_mail(&mut outbox).await;
    assert_eq!(mail.to, "me@example.com");
    assert!(mail.text.contains("https://sync.example.com/reset?token="));
    let token = reset_token(&mail);
    assert!(mail.html.contains(&token));

    let (status, html) = server
        .page("GET", &format!("/reset?token={token}"), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Choose a new password"));
    assert!(html.contains(&token));

    let (_, html) = server
        .page(
            "POST",
            "/reset",
            Some(&format!(
                "token={token}&password=new+password+1&confirm=other+one+12"
            )),
        )
        .await;
    assert!(html.contains("don&#39;t match"), "{html}");
    let (_, html) = server
        .page(
            "POST",
            "/reset",
            Some(&format!("token={token}&password=short&confirm=short")),
        )
        .await;
    assert!(html.contains("at least 8"), "{html}");

    let (status, html) = server
        .page(
            "POST",
            "/reset",
            Some(&format!(
                "token={token}&password=new+password+1&confirm=new+password+1"
            )),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Your password is changed"), "{html}");

    for token in [&mac, &phone] {
        let (status, _) = server.call("GET", "/v1/changes", Some(token), None).await;
        assert_eq!(
            status,
            StatusCode::UNAUTHORIZED,
            "every device is signed out"
        );
    }
    let sign_in = |password: &str| json!({"email": "me@example.com", "password": password});
    let (status, _) = server
        .call("POST", "/v1/sessions", None, Some(sign_in(PASSWORD)))
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "the old password is gone");
    let (status, _) = server
        .call(
            "POST",
            "/v1/sessions",
            None,
            Some(sign_in("new password 1")),
        )
        .await;
    assert_eq!(status, StatusCode::OK);

    let (_, html) = server
        .page(
            "POST",
            "/reset",
            Some(&format!(
                "token={token}&password=third+password&confirm=third+password"
            )),
        )
        .await;
    assert!(html.contains("expired"), "a link works once");
    let (_, html) = server.page("GET", "/reset?token=nonsense", None).await;
    assert!(html.contains("expired"));
}

#[sqlx::test(migrator = "MIGRATOR")]
async fn reset_answers_the_same_for_unknown_emails_and_limits_links(pool: PgPool) {
    let (server, mut outbox) = server_with_mail(pool).await;
    let (status, body) = server
        .call(
            "POST",
            "/v1/password-reset",
            None,
            Some(json!({"email": "nobody@example.com"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"ok": true}));
    let (status, _) = server
        .call(
            "POST",
            "/v1/password-reset",
            None,
            Some(json!({"email": "not an email"})),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    server.sign_up("me@example.com", "Mac").await;
    for _ in 0..3 {
        server
            .call(
                "POST",
                "/v1/password-reset",
                None,
                Some(json!({"email": "me@example.com"})),
            )
            .await;
        // One at a time, so the count each request checks is settled.
        assert_eq!(next_mail(&mut outbox).await.to, "me@example.com");
    }
    let (status, _) = server
        .call(
            "POST",
            "/v1/password-reset",
            None,
            Some(json!({"email": "me@example.com"})),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "the answer gives nothing away");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        outbox.try_recv().is_err(),
        "no fourth email this hour, and none for nobody@"
    );
}
