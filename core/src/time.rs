//! Time as the workspace stores it.

use std::time::{Duration, UNIX_EPOCH};

/// A moment as GRDB stores one (`YYYY-MM-DD HH:MM:SS.SSS`, UTC), from
/// milliseconds since 1970, which is how clients pass "now" to a write so a
/// test can fix it.
pub fn stored(now_ms: i64) -> String {
    let since = Duration::from_millis(now_ms.max(0) as u64);
    crate::schema::grdb_timestamp(UNIX_EPOCH + since)
}

/// A name with its surrounding whitespace removed, refused if nothing is
/// left: `WorkspaceStore.nonEmptyName` and the Kotlin `nonEmptyName`.
pub fn non_empty_name(raw: &str) -> Result<String, crate::CoreError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(crate::CoreError::EmptyName);
    }
    Ok(trimmed.to_string())
}

/// A stored date read back, as leniently as the clients read one: GRDB's
/// `YYYY-MM-DD HH:MM:SS.SSS`, with or without seconds and fraction, with a
/// space or a `T`, and with an offset if one was written.
pub fn parse_stored(text: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    use chrono::{DateTime, NaiveDateTime, Utc};
    let text = text.trim();
    if let Ok(zoned) = DateTime::parse_from_rfc3339(text) {
        return Some(zoned.with_timezone(&Utc));
    }
    let normalised = text.replacen('T', " ", 1);
    let normalised = normalised.trim_end_matches('Z');
    for format in [
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
    ] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(normalised, format) {
            return Some(naive.and_utc());
        }
    }
    None
}

/// An instant as GRDB stores one.
pub fn stored_instant(instant: chrono::DateTime<chrono::Utc>) -> String {
    stored(instant.timestamp_millis())
}
