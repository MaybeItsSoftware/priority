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
