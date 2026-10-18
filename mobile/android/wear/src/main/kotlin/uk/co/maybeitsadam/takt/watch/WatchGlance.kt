package uk.co.maybeitsadam.takt.watch

import uk.co.maybeitsadam.takt.wear.contract.WearPhase
import uk.co.maybeitsadam.takt.wear.contract.WearSnapshot
import uk.co.maybeitsadam.takt.wear.contract.hoursAndMinutes

/**
 * What the tile and the complication say, worked out once from the day so
 * the two agree and it can be tested without a watch.
 */
data class WatchGlance(
    /** `Focusing`, `Paused`, `On a break`, `Next`, or `Today` when there is nothing to do. */
    val eyebrow: String,
    /** The running or next task's title; null when the day is clear. */
    val title: String?,
    /** `3 left today`, `All done`, `Open the phone app`. */
    val footer: String,
    val openCount: Int,
    val isFocusing: Boolean,
    /** Epoch millis the running block's elapsed time counts from (now minus elapsed); null unless ticking. */
    val countingFrom: Long?,
    /** The block's planned seconds, for a ranged complication; null with no block. */
    val plannedSeconds: Int?,
    /** Elapsed seconds at the time asked, for a paused or ranged reading. */
    val elapsedSeconds: Int,
) {
    companion object {
        fun of(snapshot: WearSnapshot?, nowMillis: Long): WatchGlance {
            if (snapshot == null) {
                return WatchGlance("Today", null, "Open Takt on your phone", 0, false, null, null, 0)
            }
            val left = snapshot.openCount
            val footer = if (left == 0) "All done" else "$left left today"
            val session = snapshot.session
            if (session != null && session.taskId != null) {
                val elapsed = session.elapsedSeconds(nowMillis)
                val title = session.taskTitle ?: snapshot.runningTask?.title
                return when (session.phase) {
                    WearPhase.RUNNING -> WatchGlance(
                        "Focusing", title, "${hoursAndMinutes(session.plannedSeconds)} planned · $footer", left, true,
                        countingFrom = nowMillis - elapsed * 1000L, plannedSeconds = session.plannedSeconds, elapsedSeconds = elapsed,
                    )
                    WearPhase.PAUSED -> WatchGlance(
                        "Paused", title, "${hoursAndMinutes(elapsed)} of ${hoursAndMinutes(session.plannedSeconds)} · $footer", left, true,
                        countingFrom = null, plannedSeconds = session.plannedSeconds, elapsedSeconds = elapsed,
                    )
                    WearPhase.ON_BREAK -> WatchGlance("On a break", snapshot.nextTask?.title, footer, left, false, null, null, 0)
                }
            }
            if (session?.phase == WearPhase.ON_BREAK) {
                return WatchGlance("On a break", snapshot.nextTask?.title, footer, left, false, null, null, 0)
            }
            val next = snapshot.nextTask ?: return WatchGlance("Today", null, footer, left, false, null, null, 0)
            return WatchGlance("Next", next.title, footer, left, false, null, null, 0)
        }
    }
}

/** `just now`, `4m ago`, `2h ago`, `yesterday`. */
fun ageText(generatedAt: Long, now: Long): String {
    val minutes = maxOf(0L, now - generatedAt) / 60_000
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "${minutes}m ago"
        minutes < 24 * 60 -> "${minutes / 60}h ago"
        else -> "${minutes / (24 * 60)}d ago"
    }
}
