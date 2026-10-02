package uk.co.maybeitsadam.priority.core

import kotlin.math.abs

/** Which of the four Eisenhower boxes a coordinate falls in. */
enum class MatrixQuadrant(val raw: String, val title: String, val commandWords: List<String>) {
    /** Urgent and important. */
    DO_NOW("doNow", "Do", listOf("do", "do-now", "donow")),
    /** Important, not urgent. */
    SCHEDULE("schedule", "Schedule", listOf("schedule", "plan")),
    /** Urgent, not important. */
    DELEGATE("delegate", "Delegate", listOf("delegate")),
    /** Neither. */
    ELIMINATE("eliminate", "Eliminate", listOf("eliminate", "drop", "bin"));

    /** The middle of the box, as `(urgency, importance)`. */
    val representativeCoordinate: MatrixCoordinate
        get() = when (this) {
            DO_NOW -> MatrixCoordinate(5.0, 5.0)
            SCHEDULE -> MatrixCoordinate(-5.0, 5.0)
            DELEGATE -> MatrixCoordinate(5.0, -5.0)
            ELIMINATE -> MatrixCoordinate(-5.0, -5.0)
        }

    companion object {
        fun of(raw: String): MatrixQuadrant? = entries.firstOrNull { it.raw == raw }

        fun named(word: String): MatrixQuadrant? {
            val normalized = word.trim().lowercase()
            return entries.firstOrNull { normalized in it.commandWords }
        }
    }
}

data class MatrixCoordinate(val urgency: Double, val importance: Double)

data class MatrixOffset(val x: Double, val y: Double)

/** The mapping between an Eisenhower coordinate and a point on the plotted square. Port of `MatrixGeometry.swift`. */
object MatrixGeometry {
    /** Coordinates run -9...9 on both axes. */
    const val extent: Double = 9.0
    /** The square is scaled by 10, leaving a tenth of margin. */
    const val scale: Double = 10.0

    /** Offset in points from the centre; positive importance is up (negative y). */
    fun offset(urgency: Double, importance: Double, plotSize: Double): MatrixOffset {
        val half = plotSize / 2
        return MatrixOffset((urgency / scale) * half, -(importance / scale) * half)
    }

    /** The coordinate an offset represents, clamped to the legal range. */
    fun coordinate(offsetX: Double, offsetY: Double, plotSize: Double): MatrixCoordinate {
        if (plotSize <= 0) return MatrixCoordinate(0.0, 0.0)
        val half = plotSize / 2
        return MatrixCoordinate(clamp((offsetX / half) * scale), clamp(-(offsetY / half) * scale))
    }

    /** Rounded to whole steps (half away from zero, as Swift's `rounded()`). */
    fun snappedCoordinate(offsetX: Double, offsetY: Double, plotSize: Double): MatrixCoordinate {
        val raw = coordinate(offsetX, offsetY, plotSize)
        return MatrixCoordinate(roundHalfAway(raw.urgency), roundHalfAway(raw.importance))
    }

    fun clamp(value: Double): Double = minOf(extent, maxOf(-extent, value))

    /** Zero on an axis counts as the lower side. */
    fun quadrant(urgency: Double, importance: Double): MatrixQuadrant = when {
        urgency > 0 && importance > 0 -> MatrixQuadrant.DO_NOW
        importance > 0 -> MatrixQuadrant.SCHEDULE
        urgency > 0 -> MatrixQuadrant.DELEGATE
        else -> MatrixQuadrant.ELIMINATE
    }

    /** `(0, 0)` is the unset sentinel. */
    fun isPlaced(urgency: Double, importance: Double): Boolean = urgency != 0.0 || importance != 0.0
}

/** Swift `Double.rounded()`: to nearest, ties away from zero. */
fun roundHalfAway(value: Double): Double =
    if (value.isNaN() || value.isInfinite()) value else Math.copySign(Math.floor(abs(value) + 0.5), value)
