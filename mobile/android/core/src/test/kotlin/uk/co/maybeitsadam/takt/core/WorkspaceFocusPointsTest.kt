package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The pure half of `WorkspaceFocusPointsTests.swift`. */
class WorkspaceFocusPointsTest {
    @Test fun aScoreIsMinutesTimesTheMultiplierToOneDecimalPlace() {
        assertEquals(25.0, FocusPoints.minutes(1_500), 0.0)
        assertEquals(12.5, FocusPoints.minutes(750), 0.0)
        assertEquals(12.5, FocusPoints.score(750, 1.0), 0.0)
        assertEquals(37.5, FocusPoints.score(1_500, 1.5), 0.0)
        assertEquals(12.5, FocusPoints.score(1_500, 0.5), 0.0)
        assertEquals(0.0, FocusPoints.score(0, 2.0), 0.0)
    }

    @Test fun anOutOfRangeOrNonsenseMultiplierCannotDistortTheTotals() {
        assertEquals(FocusPoints.multiplierRange.endInclusive, FocusPoints.clamped(900.0), 0.0)
        assertEquals(FocusPoints.multiplierRange.start, FocusPoints.clamped(-3.0), 0.0)
        assertEquals(FocusQuality.SOLID.multiplier, FocusPoints.clamped(Double.NaN), 0.0)
        assertEquals(FocusQuality.SOLID.multiplier, FocusPoints.clamped(Double.POSITIVE_INFINITY), 0.0)
        assertEquals(10.0, FocusPoints.score(600, Double.POSITIVE_INFINITY), 0.0)
    }

    @Test fun scoresAreFormattedWithoutATrailingZero() {
        assertEquals("25", FocusPoints.formatted(25.0))
        assertEquals("12.5", FocusPoints.formatted(12.5))
        assertEquals("0", FocusPoints.formatted(0.0))
    }

    @Test fun everyPresetQualityMapsBackToItself() {
        for (quality in FocusQuality.entries) assertEquals(quality, FocusQuality.matching(quality.multiplier))
        assertNull(FocusQuality.matching(1.23))
    }

    @Test fun anEarnedAwardDerivesItsMinutesAndPoints() {
        val award = FocusAward.earned(
            id = "a", sessionId = "s", taskId = "t", taskTitle = "Write", seconds = 1_500,
            multiplier = FocusQuality.SHARP.multiplier, awardedAt = epoch(0),
        )
        assertEquals(25.0, award.minutes, 0.0)
        assertEquals(1.5, award.multiplier, 0.0)
        assertEquals(37.5, award.points, 0.0)
        assertEquals(FocusQuality.SHARP, award.quality)
        val negative = FocusAward.earned(sessionId = null, taskId = null, taskTitle = "x", seconds = -5, multiplier = 9.0, awardedAt = epoch(0))
        assertEquals(0, negative.seconds)
        assertEquals(5.0, negative.multiplier, 0.0)
    }
}
