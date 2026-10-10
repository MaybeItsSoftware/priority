package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/**
 * What a typed task says about itself beyond its title:
 * `Write the release notes 45m #work @fri !1`, and `wait:Sam` for who it waits on.
 *
 * Only trailing words are read, and only while every one of them is a token;
 * the first word is never read as a token. The reading is the Rust core's
 * (`core/src/capture.rs`), as on the Mac and iPhone; this keeps the Kotlin
 * types so callers did not change.
 */
data class TaskCapture(
    val title: String,
    val estimateSeconds: Int? = null,
    /** The start of the day it is due. */
    val dueAt: Instant? = null,
    val tags: List<String> = emptyList(),
    /** 1 to 4. */
    val priority: Int? = null,
    /** Who it waits on, from `wait:Sam`. */
    val waitingOn: String? = null,
) {
    val hasDetails: Boolean
        get() = estimateSeconds != null || dueAt != null || tags.isNotEmpty() || priority != null ||
            waitingOn != null

    /** Short labels for what was found: `45m`, `Fri 3 Oct`, `#work`, `!1`, `waiting on Sam`. */
    fun detailLabels(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<String> =
        uniffi.takt_core.captureDetailLabels(core, now.coreMillis, zone.coreName)

    internal val core: uniffi.takt_core.CaptureParts
        get() = uniffi.takt_core.CaptureParts(
            title = title,
            estimateSeconds = estimateSeconds?.toLong(),
            dueAtMs = dueAt?.coreMillis,
            tags = tags,
            priority = priority?.toLong(),
            waitingOn = waitingOn,
        )

    companion object {
        /** Parses `text` as typed into an add field. */
        fun parse(text: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): TaskCapture {
            val core = uniffi.takt_core.captureParse(text, now.coreMillis, zone.coreName)
            return TaskCapture(
                title = core.title,
                estimateSeconds = core.estimateSeconds?.toInt(),
                dueAt = core.dueAtMs?.let(Instant::ofEpochMilli),
                tags = core.tags,
                priority = core.priority?.toInt(),
                waitingOn = core.waitingOn,
            )
        }
    }
}

/** The single words the add field understands, for the readers that share them (`HabitPolicy`). */
object TaskCaptureToken {
    /** Anything past a day is a typo or not an estimate. */
    const val MAXIMUM_ESTIMATE_SECONDS = 24 * 60 * 60

    /** `30m`, `90min`, `1h`, `1.5h`, `2hrs`, `1h30m`, `1h30`, each optionally after a `~`. */
    fun estimate(word: String): Int? = uniffi.takt_core.captureEstimate(word)?.toInt()

    /** `today`, `tomorrow`, a weekday (today included), `3d`/`2w`, or `yyyy-mm-dd`. The start of that day. */
    fun due(word: String, now: Instant, zone: ZoneId): Instant? =
        uniffi.takt_core.captureDue(word, now.coreMillis, zone.coreName)?.let(Instant::ofEpochMilli)
}
