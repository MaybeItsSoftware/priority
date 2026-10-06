package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of `HabitPolicyTests.swift`, case for case. 2026-10-05 is a Monday. */
class HabitPolicyTest {
    private fun day(value: Int, month: Int = 10, hour: Int = 12) = date(2026, month, value, hour)

    // Frequency

    @Test fun frequencyRoundTripsThroughTheDailyStorage() {
        for (frequency in listOf(HabitFrequency.Daily, HabitFrequency.Weekly, HabitFrequency.EveryNDays(3), HabitFrequency.Weekdays(setOf(2, 4, 6)))) {
            val stored = frequency.storage
            assertEquals(frequency, HabitFrequency.of(stored.weekdays, stored.intervalDays))
        }
        assertEquals(HabitFrequency.Daily, HabitFrequency.of(emptySet(), null))
        assertEquals("Every other day", HabitFrequency.EveryNDays(2).label)
        assertEquals("Weekdays", HabitFrequency.Weekdays(setOf(2, 3, 4, 5, 6)).label)
        assertEquals("Mon Wed", HabitFrequency.Weekdays(setOf(4, 2)).label)
    }

    @Test fun scheduledDaysFollowWeekdaysAndIntervalsFromTheAnchor() {
        val weekdays = HabitRule(weekdays = setOf(2, 4), anchor = day(5))
        assertTrue(HabitPolicy.isScheduled(weekdays, day(5), UTC)) // Mon
        assertFalse(HabitPolicy.isScheduled(weekdays, day(6), UTC)) // Tue
        assertTrue(HabitPolicy.isScheduled(weekdays, day(7), UTC)) // Wed

        val weekly = HabitRule(intervalDays = 7, anchor = day(5))
        assertTrue(HabitPolicy.isScheduled(weekly, day(12), UTC))
        assertFalse(HabitPolicy.isScheduled(weekly, day(13), UTC))
        assertFalse("nothing before the day it was made", HabitPolicy.isScheduled(weekly, day(28, month = 9), UTC))
    }

    // Expiry

    @Test fun expiryRules() {
        var rule = HabitRule(anchor = day(1))
        assertFalse(HabitPolicy.isExpired(rule, day(30), sourceCompleted = true, zone = UTC))

        rule = rule.copy(expiry = HabitExpiry.WhenSourceCompleted)
        assertFalse(HabitPolicy.isExpired(rule, day(30), sourceCompleted = false, zone = UTC))
        assertTrue(HabitPolicy.isExpired(rule, day(30), sourceCompleted = true, zone = UTC))

        rule = rule.copy(expiry = HabitExpiry.On(day(10, hour = 18)))
        assertFalse(HabitPolicy.isExpired(rule, day(9), sourceCompleted = false, zone = UTC))
        assertTrue(HabitPolicy.isExpired(rule, day(10, hour = 1), sourceCompleted = false, zone = UTC))
        assertNull(HabitPolicy.appearance(rule, day(11), lastDoneDay = null, sourceCompleted = false, zone = UTC))
    }

    @Test fun storedExpiryReadsBackAndFallsBackToNever() {
        assertEquals(HabitExpiry.WhenSourceCompleted, HabitExpiry.of("source", null))
        assertEquals(HabitExpiry.On(day(3)), HabitExpiry.of("date", day(3)))
        assertEquals(HabitExpiry.Never, HabitExpiry.of("date", null))
        assertEquals(HabitExpiry.Never, HabitExpiry.of("nonsense", null))
        assertEquals("source", HabitExpiry.WhenSourceCompleted.rule)
    }

    // Appearance

    @Test fun aDueHabitAppearsInItsColumnUntilItIsDone() {
        val rule = HabitRule(anchor = day(5), placement = HabitPlacement.THIS_WEEK)
        val appearance = HabitPolicy.appearance(rule, day(6), lastDoneDay = day(5), sourceCompleted = false, zone = UTC)
        assertEquals(HabitAppearance("this-week", day(6, hour = 0), isCarriedOver = false), appearance)
        assertNull(HabitPolicy.appearance(rule, day(6), lastDoneDay = day(6, hour = 9), sourceCompleted = false, zone = UTC))
    }

    @Test fun aMissedDayIsDroppedWhenTheHabitDisappearsAtTheEndOfTheDay() {
        val rule = HabitRule(intervalDays = 7, anchor = day(5), dropsAtDayEnd = true)
        assertNotNull(HabitPolicy.appearance(rule, day(5), lastDoneDay = null, sourceCompleted = false, zone = UTC))
        assertNull(HabitPolicy.appearance(rule, day(6), lastDoneDay = null, sourceCompleted = false, zone = UTC))
    }

    @Test fun aMissedDayIsCarriedUntilDoneWhenItDoesNotDisappear() {
        val rule = HabitRule(intervalDays = 7, anchor = day(5), dropsAtDayEnd = false, placement = HabitPlacement.WAITING)
        val carried = HabitPolicy.appearance(rule, day(8), lastDoneDay = null, sourceCompleted = false, zone = UTC)
        assertEquals(HabitAppearance("waiting-on", day(5, hour = 0), isCarriedOver = true), carried)
        // Done on the 8th: owed nothing on the 9th.
        assertNull(HabitPolicy.appearance(rule, day(9), lastDoneDay = day(8), sourceCompleted = false, zone = UTC))
        // Done before the owed day does not count for it.
        assertNotNull(HabitPolicy.appearance(rule, day(13), lastDoneDay = day(8), sourceCompleted = false, zone = UTC))
    }

    @Test fun anExpiredHabitNeverAppears() {
        val rule = HabitRule(anchor = day(5), dropsAtDayEnd = false, expiry = HabitExpiry.WhenSourceCompleted)
        assertNull(HabitPolicy.appearance(rule, day(6), lastDoneDay = null, sourceCompleted = true, zone = UTC))
    }

    // Column

    @Test fun reconciledColumnOnlyManagesTheHabitsOwnColumn() {
        val appearance = HabitAppearance("today", day(5), isCarriedOver = false)
        val today = HabitPlacement.TODAY
        assertEquals(HabitColumnChange("today"), HabitPolicy.reconciledColumn(null, appearance, today))
        assertNull(HabitPolicy.reconciledColumn("today", appearance, today))
        assertNull("a card moved by hand stays where it was put", HabitPolicy.reconciledColumn("in-progress", appearance, today))
        assertEquals(HabitColumnChange(null), HabitPolicy.reconciledColumn("today", null, today))
        assertNull(HabitPolicy.reconciledColumn("backlog", null, today))
        assertNull(HabitPolicy.reconciledColumn(null, null, today))
    }

    // Parsing

    @Test fun estimateAndDateText() {
        assertEquals(1_800, HabitPolicy.estimateSeconds("30m"))
        assertEquals(5_400, HabitPolicy.estimateSeconds("1h30"))
        assertEquals(2_700, HabitPolicy.estimateSeconds("45"))
        assertNull(HabitPolicy.estimateSeconds(""))
        assertNull(HabitPolicy.estimateSeconds("soon"))
        assertEquals(date(2026, 12, 31), HabitPolicy.date("2026-12-31", now = day(5), zone = UTC))
        assertEquals(day(19, hour = 0), HabitPolicy.date("2w", now = day(5), zone = UTC))
    }

    // The shared list id

    @Test fun theHabitsListIdIsTheOneTheMacDerives() {
        // The same literal is pinned in `HabitPolicyTests.swift`.
        assertEquals("CBC20FA7-CBCE-52A3-A729-95DCFFC9C2A4", HabitPolicy.habitsListId("WORKSPACE"))
    }
}
