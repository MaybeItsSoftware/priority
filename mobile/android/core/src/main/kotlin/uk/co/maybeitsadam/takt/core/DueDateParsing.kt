package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/**
 * Turns Checkvist's free-text `due` string into an instant, when it names one:
 * the Rust core's `checkvist_due_date` (`core/src/capture.rs`), as on the Mac.
 *
 * An internet date-time (`2026-10-02T09:30:00Z`) is that moment; anything else
 * starting with a year, month and day (`2026-10-02`, `2026/10/02 09:00:00 +0100`,
 * `2026-1-5`) is that day's midnight in UTC, which is what the Mac's Foundation
 * parsers answered. [zone] is kept for callers; the answer no longer depends on it.
 */
object DueDateParsing {
    /** Null for an empty string, and for a keyword like `asap` that names no calendar date. */
    @Suppress("UNUSED_PARAMETER")
    fun date(due: String?, zone: ZoneId = ZoneId.systemDefault()): Instant? =
        uniffi.takt_core.checkvistDueDate(due)?.let(Instant::ofEpochMilli)
}
