package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration

class PeriodicScheduleTest {
    /** Wednesday 2025-09-24, 09:00 UTC. */
    private val wednesday = epoch(1_758_704_400)
    private fun weekday(of: java.time.Instant) = calendarWeekday(of.atZone(UTC).toLocalDate())
    private fun s(rule: String) = PeriodicSchedule.parse(rule)

    @Test fun readsThePhrasesTheAppAlreadyStores() {
        assertEquals(PeriodicSchedule.Cadence.Days(1), s("daily")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Weeks(1), s(" Weekly ")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Weekdays, s("weekdays")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Days(3), s("every 3 days")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Weeks(2), s("every 2 weeks")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Weekday(2), s("every monday")?.cadence)
        assertEquals(PeriodicSchedule.Cadence.Weekday(6), s("friday")?.cadence)
    }

    @Test fun refusesWhatItCannotSchedule() {
        assertNull(s(""))
        assertNull(s("   "))
        assertNull(s("every so often"))
        assertNull(s("every 0 days"))
        assertNull(s("every 2 months"))
    }

    @Test fun stepsOneCadenceForwardAndKeepsTheTimeOfDay() {
        val next = s("every 3 days")!!.nextOccurrence(wednesday, zone = UTC)
        assertEquals(wednesday.plusSeconds(3 * 86_400), next)
        assertEquals(9, next!!.atZone(UTC).hour)
    }

    @Test fun weekdaysSkipTheWeekend() {
        val friday = wednesday.atZone(UTC).plusDays(2).toInstant()
        val next = s("weekdays")!!.nextOccurrence(friday, zone = UTC)
        assertEquals(2, weekday(next!!))
        assertEquals(friday.plusSeconds(3 * 86_400), next)
    }

    @Test fun aNamedWeekdayLandsOnThatDay() {
        val next = s("every monday")!!.nextOccurrence(wednesday, zone = UTC)
        assertEquals(2, weekday(next!!))
        assertEquals(wednesday.plusSeconds(5 * 86_400), next)
    }

    @Test fun catchesUpPastAGapWithoutBreakingTheRhythm() {
        val longAgo = wednesday.minusSeconds(20 * 86_400)
        val next = s("every 3 days")!!.nextOccurrence(longAgo, notBefore = wednesday, zone = UTC)
        assertNotNull(next)
        assertTrue(next!! > wednesday)
        val elapsed = Duration.between(longAgo, next).seconds
        assertEquals(0, elapsed % (3 * 86_400))
        assertTrue(elapsed <= 21 * 86_400 + 3 * 86_400)
    }

    @Test fun notBeforeNeverPullsAnOccurrenceBackwards() {
        val next = s("daily")!!.nextOccurrence(wednesday, notBefore = wednesday.minusSeconds(86_400), zone = UTC)
        assertEquals(wednesday.plusSeconds(86_400), next)
    }

    @Test fun labelsReadAsSomeoneWouldSayThem() {
        assertEquals("Daily", s("daily")?.displayLabel)
        assertEquals("Weekdays", s("weekdays")?.displayLabel)
        assertEquals("Weekly", s("every 1 week")?.displayLabel)
        assertEquals("Every 4 days", s("every 4 days")?.displayLabel)
        assertEquals("Every Thursday", s("every thu")?.displayLabel)
    }
}
