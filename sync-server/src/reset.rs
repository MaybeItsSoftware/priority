//! Resetting a forgotten password by email.
//!
//! `POST /v1/password-reset` emails a link to `GET /reset?token=…`, a page this
//! server serves itself, so the link works on any device whether or not the
//! app is on it. The page posts the new password back to `POST /reset`.
//!
//! The request answers the same whether or not the email has an account, and
//! does the lookup and the sending after answering, so neither the reply nor
//! how long it takes says who has one. A new password signs every device out:
//! a reset is also how someone takes an account back from whoever had it.

use crate::AppState;
use crate::accounts::{self, check_password, normalise_email};
use crate::auth::{hash_token, new_token};
use crate::error::{AppError, Result};
use crate::mail::{Mailer, Message};
use axum::Json;
use axum::extract::{Form, Query, State};
use axum::http::header;
use axum::response::{Html, IntoResponse, Response};
use chrono::{Duration, Utc};
use serde::Deserialize;
use uuid::Uuid;

/// How long a link works.
const LINK_LIFETIME: Duration = Duration::hours(1);
/// Links sent per account per hour. Enough to retry a lost email, too few to
/// fill someone's inbox by typing their address in a loop.
const MAX_LINKS_PER_HOUR: i64 = 3;

/// What sending a reset needs. `None` in [`AppState`] when the server has no
/// Resend key, and the endpoint says so.
pub struct ResetMail {
    pub mailer: Box<dyn Mailer>,
    /// Where `/reset` is reachable from outside, without a trailing slash.
    pub public_url: String,
}

#[derive(Debug, Deserialize)]
pub struct ResetRequest {
    pub email: String,
}

/// `POST /v1/password-reset`.
pub async fn request(
    State(state): State<AppState>,
    Json(request): Json<ResetRequest>,
) -> Result<Json<serde_json::Value>> {
    if state.reset.is_none() {
        return Err(AppError::Unavailable(
            "password reset isn't set up on this server".into(),
        ));
    }
    let email = normalise_email(&request.email);
    accounts::check_email(&email)?;
    tokio::spawn(async move {
        if let Err(error) = send_link(&state, &email).await {
            tracing::error!(%error, "could not send a password reset link");
        }
    });
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn send_link(state: &AppState, email: &str) -> std::result::Result<(), String> {
    let Some(reset) = state.reset.as_deref() else {
        return Ok(());
    };
    let account = sqlx::query_scalar::<_, Uuid>("SELECT id FROM accounts WHERE email = $1")
        .bind(email)
        .fetch_optional(&state.pool)
        .await
        .map_err(|e| e.to_string())?;
    let Some(account) = account else {
        tracing::info!("password reset asked for an email with no account");
        return Ok(());
    };
    let recent = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM password_resets \
         WHERE account_id = $1 AND created_at > now() - interval '1 hour'",
    )
    .bind(account)
    .fetch_one(&state.pool)
    .await
    .map_err(|e| e.to_string())?;
    if recent >= MAX_LINKS_PER_HOUR {
        tracing::warn!(%account, "password reset refused: too many this hour");
        return Ok(());
    }

    let token = new_token();
    sqlx::query(
        "INSERT INTO password_resets (token_hash, account_id, expires_at) VALUES ($1, $2, $3)",
    )
    .bind(hash_token(&token))
    .bind(account)
    .bind(Utc::now() + LINK_LIFETIME)
    .execute(&state.pool)
    .await
    .map_err(|e| e.to_string())?;
    // Sweep links that can never be used again while here.
    sqlx::query("DELETE FROM password_resets WHERE expires_at < now() - interval '1 day'")
        .execute(&state.pool)
        .await
        .map_err(|e| e.to_string())?;

    let link = format!("{}/reset?token={token}", reset.public_url);
    reset
        .mailer
        .send(Message {
            to: email.to_owned(),
            subject: "Reset your Priority password".into(),
            text: format!(
                "Someone asked to reset the password for the Priority account {email}.\n\n\
                 Set a new one here. The link works for an hour:\n{link}\n\n\
                 Setting it signs your devices out; sign in on each with the new password.\n\n\
                 If it wasn't you, ignore this email and nothing changes."
            ),
            html: email_html(email, &link),
        })
        .await?;
    tracing::info!(%account, "sent a password reset link");
    Ok(())
}

#[derive(Debug, Deserialize)]
pub struct PageQuery {
    #[serde(default)]
    pub token: String,
}

/// `GET /reset?token=…`: the form, or why the link is no good.
pub async fn page(State(state): State<AppState>, Query(query): Query<PageQuery>) -> Response {
    match live_link(&state, &query.token).await {
        Ok(Some(_)) => page_response(form_page(&query.token, None)),
        Ok(None) => page_response(message_page(
            "This link has expired",
            "Reset links work once, for an hour. Ask for a new one from the sign-in screen in Priority.",
        )),
        Err(error) => error.into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct ResetForm {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub confirm: String,
}

/// `POST /reset`: sets the password from the form.
pub async fn submit(State(state): State<AppState>, Form(form): Form<ResetForm>) -> Response {
    if form.password != form.confirm {
        return page_response(form_page(
            &form.token,
            Some("The two passwords don't match."),
        ));
    }
    if let Err(AppError::BadRequest(problem)) = check_password(&form.password) {
        return page_response(form_page(&form.token, Some(&problem)));
    }
    match set_password(&state, &form.token, form.password).await {
        Ok(true) => page_response(message_page(
            "Your password is changed",
            "Every device has been signed out. Sign in on each one with the new password.",
        )),
        Ok(false) => page_response(message_page(
            "This link has expired",
            "Reset links work once, for an hour. Ask for a new one from the sign-in screen in Priority.",
        )),
        Err(error) => error.into_response(),
    }
}

/// The account a link resets, if it's a well-formed, unused, unexpired one.
async fn live_link(state: &AppState, token: &str) -> Result<Option<Uuid>> {
    if !is_token_shaped(token) {
        return Ok(None);
    }
    let account = sqlx::query_scalar::<_, Uuid>(
        "SELECT account_id FROM password_resets \
         WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()",
    )
    .bind(hash_token(token))
    .fetch_optional(&state.pool)
    .await?;
    Ok(account)
}

/// Uses the link: sets the password, spends every outstanding link for the
/// account and signs out its devices, all or nothing. False if the link is no
/// good (by now: it may have been used in another tab meanwhile).
async fn set_password(state: &AppState, token: &str, password: String) -> Result<bool> {
    if !is_token_shaped(token) {
        return Ok(false);
    }
    let password_hash = accounts::hash_password(password).await?;
    let mut tx = state.pool.begin().await?;
    let claimed = sqlx::query_scalar::<_, Uuid>(
        "UPDATE password_resets SET used_at = now() \
         WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() \
         RETURNING account_id",
    )
    .bind(hash_token(token))
    .fetch_optional(&mut *tx)
    .await?;
    let Some(account) = claimed else {
        return Ok(false);
    };
    let email = sqlx::query_scalar::<_, Option<String>>(
        "UPDATE accounts SET password_hash = $1 WHERE id = $2 RETURNING email",
    )
    .bind(&password_hash)
    .bind(account)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE password_resets SET used_at = now() WHERE account_id = $1 AND used_at IS NULL",
    )
    .bind(account)
    .execute(&mut *tx)
    .await?;
    sqlx::query("DELETE FROM devices WHERE account_id = $1")
        .bind(account)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    // Whoever reset it can sign in at once, past any lockout from the
    // guessing that may have prompted the reset.
    if let Some(email) = email {
        state.sign_ins.clear(&email);
    }
    tracing::info!(%account, "reset a password");
    Ok(true)
}

/// Tokens are [`new_token`]'s 64 hex characters. Checked before the token is
/// looked up or written back into a page, so nothing else ever reaches either.
fn is_token_shaped(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn page_response(body: String) -> Response {
    (
        [
            // The token is in the address: don't hand it to anything else.
            (header::REFERRER_POLICY, "no-referrer"),
            (header::CACHE_CONTROL, "no-store"),
            (
                header::CONTENT_SECURITY_POLICY,
                "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
            ),
        ],
        Html(body),
    )
        .into_response()
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// The house look, small enough to inline: chalk paper, grape ink, hairlines,
/// no shadows, light and dark.
const STYLE: &str = "
:root { --paper:#faf8f4; --raised:#ffffff; --ink:#444054; --muted:#6e6b7c; --border:#e6e4ea;
        --input:#d8d5dd; --primary:#007fff; --danger:#d62246; color-scheme: light dark; }
@media (prefers-color-scheme: dark) { :root { --paper:#1c1a23; --raised:#25232f; --ink:#f5f4f7;
        --muted:#b6b3bf; --border:#34313f; --input:#34313f; } }
* { box-sizing: border-box; }
body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
       background:var(--paper); color:var(--ink); padding:24px;
       font:16px/1.5 'IBM Plex Sans', -apple-system, system-ui, sans-serif; }
main { width:100%; max-width:380px; background:var(--raised); border:1px solid var(--border);
       border-radius:8px; padding:28px; }
h1 { font-size:20px; font-weight:600; margin:0 0 8px; }
p { margin:0 0 16px; color:var(--muted); }
label { display:block; font-size:13px; color:var(--muted); margin:16px 0 6px; }
input { width:100%; font:inherit; font-size:16px; padding:10px 12px; border:1px solid var(--input);
        border-radius:6px; background:var(--paper); color:var(--ink); }
input:focus { outline:2px solid var(--primary); outline-offset:1px; }
button { margin-top:20px; width:100%; min-height:44px; font:inherit; font-weight:600; color:#fff;
         background:var(--primary); border:1px solid var(--primary); border-radius:6px; cursor:pointer; }
.problem { color:var(--danger); margin:16px 0 0; }
";

fn shell(title: &str, body: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta name=\"robots\" content=\"noindex\"><title>{title} · Priority</title>\
         <style>{STYLE}</style></head><body><main>{body}</main></body></html>",
        title = escape(title),
    )
}

fn form_page(token: &str, problem: Option<&str>) -> String {
    let token = if is_token_shaped(token) { token } else { "" };
    let problem = problem
        .map(|text| format!("<p class=\"problem\" role=\"alert\">{}</p>", escape(text)))
        .unwrap_or_default();
    shell(
        "Choose a new password",
        &format!(
            "<h1>Choose a new password</h1>\
             <p>At least 8 characters. Every device will be signed out.</p>\
             <form method=\"post\" action=\"/reset\">\
             <input type=\"hidden\" name=\"token\" value=\"{token}\">\
             <label for=\"password\">New password</label>\
             <input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"new-password\" minlength=\"8\" required autofocus>\
             <label for=\"confirm\">Type it again</label>\
             <input id=\"confirm\" name=\"confirm\" type=\"password\" autocomplete=\"new-password\" minlength=\"8\" required>\
             {problem}<button type=\"submit\">Set password</button></form>"
        ),
    )
}

fn message_page(title: &str, text: &str) -> String {
    shell(
        title,
        &format!("<h1>{}</h1><p>{}</p>", escape(title), escape(text)),
    )
}

fn email_html(email: &str, link: &str) -> String {
    let (email, link) = (escape(email), escape(link));
    format!(
        "<div style=\"font-family:-apple-system,system-ui,sans-serif;color:#444054;max-width:480px\">\
         <p>Someone asked to reset the password for the Priority account <strong>{email}</strong>.</p>\
         <p><a href=\"{link}\" style=\"display:inline-block;padding:10px 16px;background:#007fff;color:#ffffff;\
         border-radius:6px;text-decoration:none;font-weight:600\">Choose a new password</a></p>\
         <p style=\"color:#6e6b7c\">The link works for an hour. Setting a password signs your devices out; \
         sign in on each with the new one.</p>\
         <p style=\"color:#6e6b7c\">If it wasn't you, ignore this email and nothing changes.</p></div>"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_minted_tokens_are_accepted_or_echoed() {
        assert!(is_token_shaped(&new_token()));
        assert!(!is_token_shaped(""));
        assert!(!is_token_shaped(&"g".repeat(64)));
        assert!(!is_token_shaped(&format!("{}\"><script>", "a".repeat(55))));
        assert!(!form_page("\"><script>alert(1)</script>", None).contains("<script>"));
    }

    #[test]
    fn page_text_is_escaped() {
        assert_eq!(
            escape("<a href=\"x\">&'"),
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;"
        );
        assert!(form_page(&new_token(), Some("<b>")).contains("&lt;b&gt;"));
    }
}
