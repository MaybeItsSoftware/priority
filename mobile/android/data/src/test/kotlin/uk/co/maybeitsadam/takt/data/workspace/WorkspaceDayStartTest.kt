package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.data.TestWorkspace

/**
 * Starting each day afresh, as the phone honours it: the settings are the
 * account's (set on the Mac or the CLI), and the foreground engines' tick
 * starts the day once it has changed. The rules are the core's, tested there.
 */
class WorkspaceDayStartTest {
    /** Thursday 22 October 2026, 20:00 UTC; the test workspace is in UTC. */
    private val evening: Instant = Instant.parse("2026-10-22T20:00:00Z")

    @Test
    fun theDayStartsAtHomeOnceItHasChanged(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded(now = evening)
            val conditions = store.conditions(workspace.id)
            val home = conditions.first { it.name == "Home" }
            val campus = conditions.first { it.name == "Campus" }
            assertFalse(store.dayStart().resets)
            assertFalse("nothing set, nothing due", store.startDayIfDue(evening, w.zone))

            store.coreWrite {
                it.setDayStartSettings(
                    uniffi.takt_core.DayStartSettings(true, 4, listOf(home.id), null), evening.toEpochMilli(), w.zone.id,
                )
            }
            store.saveFocusContext(
                workspace.id,
                emptyFocusContext().copy(conditionIds = listOf(campus.id), availableUntilMs = evening.toEpochMilli() + 3_600_000),
                evening.plusSeconds(60),
            )
            val settings = store.observeDayStart().first()
            assertTrue(settings.resets)
            assertFalse("set this evening, which counts as started", settings.isDue(evening.plusSeconds(3_600), w.zone))
            assertFalse(store.startDayIfDue(Instant.parse("2026-10-23T03:59:00Z"), w.zone))

            val morning = Instant.parse("2026-10-23T04:00:00Z")
            assertTrue(store.startDayIfDue(morning, w.zone))
            val reset = store.focusContext(workspace.id)!!
            assertEquals(listOf(home.id), reset.conditionIds)
            assertNull(reset.availableUntilMs)
            assertEquals("2026-10-23", store.dayStart().lastResetDay)
            assertFalse("once a day", store.startDayIfDue(morning.plusSeconds(3_600), w.zone))
        }
    }
}
