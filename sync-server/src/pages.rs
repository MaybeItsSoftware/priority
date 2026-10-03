//! The public pages the app stores link to: the privacy policy.
//!
//! Served here because the server is already the apps' one public address.
//! The contact line takes `CONTACT_EMAIL` from the environment, so the
//! address can change without a code change.

use axum::http::header;
use axum::response::{Html, IntoResponse};
use std::sync::OnceLock;

const PRIVACY: &str = include_str!("../static/privacy.html");

/// `GET /privacy`.
pub async fn privacy() -> impl IntoResponse {
    static PAGE: OnceLock<String> = OnceLock::new();
    let page = PAGE.get_or_init(|| {
        let email = std::env::var("CONTACT_EMAIL").ok();
        PRIVACY.replace("CONTACT_LINE", &contact_line(email.as_deref()))
    });
    (
        [(header::CACHE_CONTROL, "public, max-age=3600")],
        Html(page.as_str()),
    )
}

/// A mailto link for a plausible address, or a pointer to the store page.
/// Only plain address characters are let through, so the variable cannot
/// put markup into the page.
fn contact_line(email: Option<&str>) -> String {
    let safe = email.map(str::trim).filter(|email| {
        email.contains('@')
            && email
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c))
    });
    match safe {
        Some(email) => format!(
            "Questions, or a request about your data: <a href=\"mailto:{email}\">{email}</a>."
        ),
        None => "Questions, or a request about your data: use the support link on Priority's \
                 App Store or Google Play page."
            .to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_contact_line_takes_only_a_plain_address() {
        assert!(contact_line(Some("me@example.com")).contains("mailto:me@example.com"));
        assert!(!contact_line(Some("<script>@x.com")).contains("<script>"));
        assert!(contact_line(None).contains("support link"));
        assert!(PRIVACY.contains("CONTACT_LINE"), "the page has the slot");
    }
}
