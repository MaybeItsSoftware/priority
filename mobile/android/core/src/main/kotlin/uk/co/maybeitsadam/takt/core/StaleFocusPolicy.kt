package uk.co.maybeitsadam.takt.core

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
 * paused on an earlier logical day is finished rather than resumed; one with no
 * task on it is discarded at once. The Rust core's `progress::stale_focus_outcome`.
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
    ): StaleFocusResolution = uniffi.takt_core.staleFocusOutcome(
        pausedAt?.coreMillis, accumulatedSeconds.toLong(), hasActiveTask, now.coreMillis,
        boundary.rolloverHour.toUByte(), boundary.zone.coreName,
    ).resolution
}

/** The core's outcome as the policy names it; the data layer maps the store's with it. */
val uniffi.takt_core.StaleFocusOutcome.resolution: StaleFocusResolution
    get() = when (this) {
        uniffi.takt_core.StaleFocusOutcome.KEEP -> StaleFocusResolution.KEEP
        uniffi.takt_core.StaleFocusOutcome.CLOSE -> StaleFocusResolution.CLOSE
        uniffi.takt_core.StaleFocusOutcome.DISCARD -> StaleFocusResolution.DISCARD
    }
