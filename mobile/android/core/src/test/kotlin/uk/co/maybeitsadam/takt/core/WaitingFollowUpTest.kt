package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of `WaitingFollowUpTests.swift`: when a follow-up is due, its title, the id two devices agree on, its label. */
class WaitingFollowUpTest {
    /** Tuesday 6 October 2026, 10:00 UTC. */
    private val now = date(2026, 10, 6, 10)

    private fun waiting(
        followUpAt: Instant?,
        column: String? = "waiting-on",
        isOpen: Boolean = true,
        tag: String? = "Sam",
        made: String? = null,
    ) = WaitingTaskState("SOURCE", "Contract signed", isOpen, column, tag, followUpAt, made)

    // The engine

    @Test fun aFollowUpIsDueAtItsTimeWhileTheTaskIsStillWaiting() {
        val at = date(2026, 10, 6, 9)
        val plan = WaitingFollowUp.dueFollowUp(waiting(at), now)
        assertEquals("Follow up with Sam: Contract signed", plan?.title)
        assertEquals(at, plan?.dueAt)
        assertEquals("SOURCE", plan?.sourceTaskId)
        assertEquals(WaitingFollowUp.followUpTaskId("SOURCE", at), plan?.taskId)
        // Exactly at the time counts.
        assertNotNull(WaitingFollowUp.dueFollowUp(waiting(now), now))
    }

    @Test fun nothingIsDueBeforeTheTimeOrWithoutOne() {
        assertNull(WaitingFollowUp.dueFollowUp(waiting(date(2026, 10, 6, 11)), now))
        assertNull(WaitingFollowUp.dueFollowUp(waiting(null), now))
    }

    @Test fun aTaskThatLeftWaitingOrClosedGetsNoFollowUp() {
        val at = date(2026, 10, 6, 9)
        assertNull(WaitingFollowUp.dueFollowUp(waiting(at, column = "today"), now))
        assertNull(WaitingFollowUp.dueFollowUp(waiting(at, column = null), now))
        assertNull(WaitingFollowUp.dueFollowUp(waiting(at, isOpen = false), now))
    }

    @Test fun aFollowUpIsMadeOncePerTimeSet() {
        val at = date(2026, 10, 6, 9)
        val made = WaitingFollowUp.followUpTaskId("SOURCE", at)
        assertNull(WaitingFollowUp.dueFollowUp(waiting(at, made = made), now))
        // Setting a new time after the first one fired makes a new follow-up.
        val later = date(2026, 10, 6, 9, 30)
        val plan = WaitingFollowUp.dueFollowUp(waiting(later, made = made), now)
        assertNotNull(plan)
        assertNotEquals(made, plan?.taskId)
    }

    @Test fun theTitleNamesTheTagOnlyWhenThereIsOne() {
        assertEquals("Follow up: Invoice paid", WaitingFollowUp.title("Invoice paid", null))
        assertEquals("Follow up: Invoice paid", WaitingFollowUp.title("Invoice paid", "  "))
        assertEquals("Follow up with Legal: Invoice paid", WaitingFollowUp.title("Invoice paid", " Legal "))
    }

    @Test fun aTagIsTrimmedAndClipped() {
        assertNull(WaitingFollowUp.normalizedTag(null))
        assertNull(WaitingFollowUp.normalizedTag(" \n "))
        assertEquals("Sam", WaitingFollowUp.normalizedTag("  Sam\n"))
        assertEquals("x".repeat(40), WaitingFollowUp.normalizedTag("x".repeat(55)))
        // Characters, not UTF-16 units: an emoji counts once and is never split.
        assertEquals("😀".repeat(40), WaitingFollowUp.normalizedTag("😀".repeat(41)))
    }

    /** The same vector is asserted by the Swift tests, so both platforms make one row that sync merges. */
    @Test fun theFollowUpIdIsDeterministicAndUuidShaped() {
        val at = epoch(1_791_291_600) // 2026-10-06 13:00 UTC
        val id = WaitingFollowUp.followUpTaskId("6F1C2A9E-0000-4000-8000-000000000001", at)
        assertEquals("D2D0E044-BDD3-5ED3-95C6-C687611541D1", id)
        assertEquals(id, WaitingFollowUp.followUpTaskId("6F1C2A9E-0000-4000-8000-000000000001", at.plusMillis(400)))
        assertEquals(id, UUID.fromString(id).toString().uppercase())
        assertEquals(id.uppercase(), id)
        assertEquals('5', id[14])
    }

    @Test fun theLabelNamesTodayTomorrowAWeekdayOrADate() {
        assertEquals("↻ Today 14:00", WaitingFollowUp.label(date(2026, 10, 6, 14), now, UTC))
        assertEquals("↻ Tomorrow 09:00", WaitingFollowUp.label(date(2026, 10, 7, 9), now, UTC))
        assertEquals("↻ Thu 14:00", WaitingFollowUp.label(date(2026, 10, 8, 14), now, UTC))
        assertEquals("↻ Mon 08:30", WaitingFollowUp.label(date(2026, 10, 12, 8, 30), now, UTC))
        assertEquals("↻ 20 Oct 14:00", WaitingFollowUp.label(date(2026, 10, 20, 14), now, UTC))
        assertEquals("↻ 20 Oct 2027 14:00", WaitingFollowUp.label(date(2027, 10, 20, 14), now, UTC))
        // A time already gone shows its date, as the Mac's does.
        assertEquals("↻ 5 Oct 14:00", WaitingFollowUp.label(date(2026, 10, 5, 14), now, UTC))
        assertEquals("2026-10-08 14:05", WaitingFollowUp.editableText(date(2026, 10, 8, 14, 5), UTC))
    }
}
