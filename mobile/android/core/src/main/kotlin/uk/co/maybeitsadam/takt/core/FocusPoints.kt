package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.util.Locale
import java.util.UUID

/**
 * Scoring a block of focused work: the minutes it took times how well it went,
 * both to one decimal place. Port of `FocusPoints.swift`.
 */
object FocusPoints {
    /** The widest multiplier the app will store. */
    val multiplierRange: ClosedFloatingPointRange<Double> = 0.0..5.0

    fun minutes(seconds: Int): Double = oneDecimalPlace(maxOf(0, seconds) / 60.0)

    /** Clamps into range; a non-finite multiplier is ordinary (solid) work. */
    fun clamped(multiplier: Double): Double {
        if (!multiplier.isFinite()) return FocusQuality.SOLID.multiplier
        return minOf(maxOf(multiplier, multiplierRange.start), multiplierRange.endInclusive)
    }

    fun score(seconds: Int, multiplier: Double): Double = oneDecimalPlace(minutes(seconds) * clamped(multiplier))

    /** One decimal place, and no trailing `.0` on a whole number. */
    fun formatted(points: Double): String {
        val rounded = oneDecimalPlace(points)
        return if (rounded == roundHalfAway(rounded)) String.format(Locale.ROOT, "%.0f", rounded)
        else String.format(Locale.ROOT, "%.1f", rounded)
    }

    private fun oneDecimalPlace(value: Double): Double = roundHalfAway(value * 10) / 10
}

/** The multipliers offered as presets when a block ends. */
enum class FocusQuality(val raw: String, val multiplier: Double, val title: String, val detail: String) {
    SCATTERED("scattered", 0.5, "Scattered", "Kept losing the thread"),
    PASSABLE("passable", 0.75, "Passable", "Got there, slowly"),
    SOLID("solid", 1.0, "Solid", "An honest block of work"),
    SHARP("sharp", 1.5, "Sharp", "Quick and clean"),
    FLOW("flow", 2.0, "Flow", "Lost track of the time");

    val id: String get() = raw

    companion object {
        fun of(raw: String): FocusQuality? = entries.firstOrNull { it.raw == raw }

        /** The preset a multiplier corresponds to, or null when it was typed in. */
        fun matching(multiplier: Double): FocusQuality? = entries.firstOrNull { it.multiplier == multiplier }
    }
}

/**
 * Swift's `FocusAward.init(id:sessionId:taskId:taskTitle:seconds:multiplier:awardedAt:)`:
 * clamps seconds to non-negative, derives `minutes`, clamps the multiplier and
 * scores the points.
 */
fun FocusAward.Companion.earned(
    id: String = UUID.randomUUID().toString().uppercase(),
    sessionId: String?,
    taskId: String?,
    taskTitle: String,
    seconds: Int,
    multiplier: Double,
    awardedAt: Instant,
): FocusAward = FocusAward(
    id = id,
    sessionId = sessionId,
    taskId = taskId,
    taskTitle = taskTitle,
    seconds = maxOf(0, seconds),
    minutes = FocusPoints.minutes(seconds),
    multiplier = FocusPoints.clamped(multiplier),
    points = FocusPoints.score(seconds, multiplier),
    awardedAt = awardedAt,
)

val FocusAward.quality: FocusQuality? get() = FocusQuality.matching(multiplier)

/** The running totals, held together so the UI reads one consistent value. */
data class FocusPointsSummary(
    val today: Double,
    val last7Days: Double,
    val allTime: Double,
    val blocksToday: Int,
) {
    companion object {
        val ZERO = FocusPointsSummary(0.0, 0.0, 0.0, 0)
    }
}
