package uk.co.maybeitsadam.priority.core

import java.time.Instant

/** What becomes of a block that was paused and then left. */
enum class StaleFocusResolution(val raw: String) {
    /** Still today's block; it stays paused. */
    KEEP("keep"),
    /** Close it out, crediting the seconds to the day it was worked on. */
    CLOSE("close"),
    /** End it without crediting anything. */
    DISCARD("discard");

    companion object {
        fun of(raw: String): StaleFocusResolution? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Whether a paused focus session is still live when the app comes back. A block
 * paused on an earlier logical day is finished rather than resumed. Port of
 * `StaleFocusPolicy.swift`.
 */
object StaleFocusPolicy {
    /** Under a minute is not a sitting. */
    const val MINIMUM_CREDITED_SECONDS = 60

    fun resolution(
        pausedAt: Instant?,
        accumulatedSeconds: Int,
        hasActiveTask: Boolean = true,
        now: Instant,
        boundary: DayBoundary = DayBoundary(),
    ): StaleFocusResolution {
        if (pausedAt == null) return StaleFocusResolution.KEEP
        if (boundary.logicalDay(pausedAt) >= boundary.logicalDay(now)) return StaleFocusResolution.KEEP
        if (!hasActiveTask) return StaleFocusResolution.DISCARD
        return if (accumulatedSeconds >= MINIMUM_CREDITED_SECONDS) StaleFocusResolution.CLOSE else StaleFocusResolution.DISCARD
    }
}
