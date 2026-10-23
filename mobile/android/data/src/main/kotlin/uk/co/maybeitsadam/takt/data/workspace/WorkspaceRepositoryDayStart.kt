package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.flow.Flow

/**
 * How each day starts, as the account keeps it: at the hour the day changes,
 * what holds goes back to the conditions every day starts with (Home), with
 * nothing switched off for now and no time window. The Rust core's
 * `day_start`, shared with the Mac and the iPhone; set on the Mac or with
 * `takt ws day-start`, and only shown here.
 */
suspend fun WorkspaceRepository.dayStart(): uniffi.takt_core.DayStartSettings = coreRead { it.dayStartSettings() }

/** [dayStart], again whenever another device or the CLI changes it. */
fun WorkspaceRepository.observeDayStart(): Flow<uniffi.takt_core.DayStartSettings> =
    database.observe(setOf("preferences")) { it.core.dayStartSettings() }

/** Whether a look at [now] would start the day: it resets, and the day has changed since it last did. */
fun uniffi.takt_core.DayStartSettings.isDue(now: Instant, zone: ZoneId): Boolean {
    if (!resets) return false
    val last = lastResetDay ?: return true
    return last < uniffi.takt_core.dayStartDayKey(hour, now.toEpochMilli(), zone.id)
}

/**
 * Starts the day if it has changed since the last reset, on every workspace
 * that resets: once a day, on whichever device looks first, and never over
 * something said since the day began. A read first, so the tick that finds
 * nothing due never takes the writer. Run as the app comes forward and on
 * the foreground engines' tick. Returns whether anything was reset.
 */
suspend fun WorkspaceRepository.startDayIfDue(now: Instant = now(), zone: ZoneId = this.zone): Boolean {
    if (!dayStart().isDue(now, zone)) return false
    var reset = false
    for (workspace in workspaces()) {
        reset = coreWrite { it.applyDayStart(workspace.id, now.toEpochMilli(), zone.id) } || reset
    }
    return reset
}
