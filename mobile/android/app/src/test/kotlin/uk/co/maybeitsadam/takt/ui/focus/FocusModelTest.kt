package uk.co.maybeitsadam.takt.ui.focus

import java.time.LocalTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.T0
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.NextUpCandidate
import uk.co.maybeitsadam.takt.core.TaskUnavailableReason
import uk.co.maybeitsadam.takt.session

class FocusModelTest {
    private val utc = ZoneOffset.UTC

    @Test fun endsAtForMinutesAndUntil() {
        assertNull(FocusText.endsAt(AvailableTime.Unlimited, T0, utc))
        assertEquals(T0.plusSeconds(1800), FocusText.endsAt(AvailableTime.Minutes(30), T0, utc))
        assertEquals(T0.plusSeconds(5 * 3600), FocusText.endsAt(AvailableTime.Until(LocalTime.of(14, 0)), T0, utc))
        assertEquals(T0.plusSeconds(23 * 3600), FocusText.endsAt(AvailableTime.Until(LocalTime.of(8, 0)), T0, utc))
    }

    @Test fun deferrals() {
        assertEquals(T0.plusSeconds(3600), FocusDeferral.AN_HOUR.date(T0, utc))
        assertEquals(T0.plusSeconds(5 * 3600), FocusDeferral.THIS_AFTERNOON.date(T0, utc))
        assertEquals(T0.plusSeconds(24 * 3600), FocusDeferral.TOMORROW.date(T0, utc))
    }

    @Test fun multiplierAndPoints() {
        assertEquals("×1", FocusText.multiplier(1.0))
        assertEquals("×0.75", FocusText.multiplier(0.75))
        assertEquals("×1.5", FocusText.multiplier(1.5))
        assertEquals("37.5 points", FocusText.points(1500, 1.5))
        assertEquals("1 point", FocusText.points(60, 1.0))
    }

    @Test fun unavailableTexts() {
        assertEquals("Needs at least 2 minutes", FocusText.unavailable(TaskUnavailableReason.InsufficientTime(61), emptyList()))
        assertEquals(
            "Needs Missing condition",
            FocusText.unavailable(TaskUnavailableReason.MissingConditions(listOf(listOf("x"))), emptyList()),
        )
    }

    @Test fun startObjectionsWhenBlockTooLong() {
        val candidate = NextUpCandidate("a", "A")
        assertTrue(FocusText.startObjections(candidate, FocusContext(), 1500, T0, emptyList()).isEmpty())
        val objections = FocusText.startObjections(candidate, FocusContext(endsAt = T0.plusSeconds(600)), 1500, T0, emptyList())
        assertEquals(listOf("The block is longer than the time you have."), objections)
        assertEquals(1, FocusText.startObjections(null, FocusContext(), 1500, T0, emptyList()).size)
    }

    @Test fun clockReading() {
        val reading = ClockReading.of(session("a", accumulated = 120, planned = 600), T0.plusSeconds(60))
        assertEquals(180, reading.elapsedSeconds)
        assertEquals("03:00", reading.text)
        assertEquals(0.3f, reading.fraction, 0.001f)
        assertTrue(ClockReading(700, 600).isOverrun)
    }
}
