package uk.co.maybeitsadam.takt.wear.contract

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearContractTest {
    private val write = WearTask("a", "Write the report", detail = "Work", estimateSeconds = 1800)
    private val stretch = WearTask("b", "Stretch", isDaily = true)
    private val email = WearTask("c", "Email Sam", detail = "Overdue")

    private val idle = WearSnapshot(tasks = listOf(write, stretch, email), generatedAt = 1_000)

    private fun action(kind: WearActionKind, taskId: String? = null, at: Long = 10_000, id: String = "x") =
        WearAction(id = id, action = kind, taskId = taskId, issuedAt = at)

    @Test
    fun snapshotRoundTrips() {
        val snapshot = idle.copy(
            session = WearSession("a", "Write the report", WearPhase.PAUSED, startedAt = 5_000, accumulated = 90, plannedSeconds = 1800),
            handled = listOf("one", "two"),
        )
        assertEquals(snapshot, WearCodec.decodeSnapshot(WearCodec.encode(snapshot)))
    }

    @Test
    fun actionRoundTrips() {
        val sent = action(WearActionKind.LOG_DAILY, "b")
        assertEquals(sent, WearCodec.decodeAction(WearCodec.encode(sent)))
        assertEquals(listOf(sent, sent.copy(id = "y")), WearCodec.decodeActions(WearCodec.encodeActions(listOf(sent, sent.copy(id = "y")))))
    }

    @Test
    fun wireNamesAreTheSpecs() {
        val text = WearCodec.encode(action(WearActionKind.LOG_DAILY, "b")).decodeToString()
        assertTrue(text, text.contains("\"action\":\"logDaily\""))
        val session = WearSession(null, null, WearPhase.ON_BREAK, startedAt = 0, plannedSeconds = 300)
        assertTrue(WearCodec.encode(WearSnapshot(session = session)).decodeToString().contains("\"phase\":\"onBreak\""))
    }

    @Test
    fun decodingToleratesUnknownFieldsAndRejectsJunk() {
        val newer = """{"version":2,"tasks":[{"id":"a","title":"T","colour":"red"}],"generatedAt":5,"weather":"rain"}"""
        val decoded = WearCodec.decodeSnapshot(newer.encodeToByteArray())
        assertEquals("T", decoded?.tasks?.single()?.title)
        assertNull(WearCodec.decodeSnapshot("not json".encodeToByteArray()))
        assertNull(WearCodec.decodeAction("{}".encodeToByteArray()))
        assertEquals(emptyList<WearAction>(), WearCodec.decodeActions("[{"))
    }

    @Test
    fun elapsedTicksOnlyWhileRunning() {
        val running = WearSession("a", "T", WearPhase.RUNNING, startedAt = 10_000, accumulated = 60, plannedSeconds = 600)
        assertEquals(60 + 30, running.elapsedSeconds(40_000))
        assertEquals(600 - 90, running.remainingSeconds(40_000))
        val paused = running.copy(phase = WearPhase.PAUSED)
        assertEquals(60, paused.elapsedSeconds(400_000))
        // A clock behind the phone's never counts backwards.
        assertEquals(60, running.elapsedSeconds(0))
    }

    @Test
    fun completingRemovesTheRow() {
        val after = idle.applying(action(WearActionKind.COMPLETE, "c"))
        assertEquals(listOf("a", "b"), after.tasks.map { it.id })
        assertEquals(listOf("a", "c"), idle.applying(action(WearActionKind.LOG_DAILY, "b")).tasks.map { it.id })
    }

    @Test
    fun startingPutsTheTaskFirstAndTicksFromThen() {
        val after = idle.applying(action(WearActionKind.START, "c", at = 50_000))
        assertEquals("c", after.tasks.first().id)
        assertTrue(after.tasks.first().isRunning)
        assertEquals(WearPhase.RUNNING, after.session?.phase)
        assertEquals(50_000L, after.session?.startedAt)
        assertEquals(DEFAULT_BLOCK_SECONDS, after.session?.plannedSeconds)
        assertEquals(1800, idle.applying(action(WearActionKind.START, "a")).session?.plannedSeconds)
    }

    @Test
    fun startingWhileABlockRunsChangesNothing() {
        val running = idle.applying(action(WearActionKind.START, "a"))
        assertEquals(running, running.applying(action(WearActionKind.START, "c")))
    }

    @Test
    fun pauseFreezesTheElapsedTimeAndResumeCarriesOn() {
        val running = idle.applying(action(WearActionKind.START, "a", at = 0))
        val paused = running.applying(action(WearActionKind.PAUSE, at = 120_000))
        assertEquals(WearPhase.PAUSED, paused.session?.phase)
        assertEquals(120, paused.session?.elapsedSeconds(999_000))
        val resumed = paused.applying(action(WearActionKind.RESUME, at = 200_000))
        assertEquals(130, resumed.session?.elapsedSeconds(210_000))
        // Pausing a paused block is a no-op, so a replay is harmless.
        assertEquals(paused, paused.applying(action(WearActionKind.PAUSE, at = 300_000)))
    }

    @Test
    fun stopKeepsTheTaskAndDoneRemovesIt() {
        val running = idle.applying(action(WearActionKind.START, "a"))
        val stopped = running.applying(action(WearActionKind.STOP))
        assertNull(stopped.session)
        assertTrue(stopped.tasks.any { it.id == "a" && !it.isRunning })
        val done = running.applying(action(WearActionKind.DONE))
        assertNull(done.session)
        assertFalse(done.tasks.any { it.id == "a" })
        // Ticking the running row is Done.
        assertEquals(done, running.applying(action(WearActionKind.COMPLETE, "a")))
    }

    @Test
    fun pendingActionsThePhoneHasHandledAreNotDrawnAgain() {
        val pending = listOf(action(WearActionKind.COMPLETE, "c", id = "1"), action(WearActionKind.COMPLETE, "a", id = "2"))
        assertEquals(listOf("b"), idle.withPending(pending).tasks.map { it.id })
        // The phone has done "1" and its snapshot already lacks c; "2" is still on its way.
        val fresh = idle.copy(tasks = listOf(write, stretch), handled = listOf("1"))
        assertEquals(listOf("b"), fresh.withPending(pending).tasks.map { it.id })
    }

    @Test
    fun countsAndNext() {
        val withDone = idle.copy(tasks = idle.tasks + WearTask("d", "Read", isDaily = true, dailyDone = true))
        assertEquals(3, withDone.openCount)
        assertEquals("a", withDone.nextTask?.id)
        val running = idle.applying(action(WearActionKind.START, "c"))
        assertEquals("c", running.runningTask?.id)
        assertEquals("a", running.nextTask?.id)
    }

    @Test
    fun formatting() {
        assertEquals("25m", hoursAndMinutes(1500))
        assertEquals("1h", hoursAndMinutes(3600))
        assertEquals("1h 20m", hoursAndMinutes(4800))
        assertEquals("4:05", clock(245))
        assertEquals("1:02:03", clock(3723))
        assertEquals("-0:30", clock(-30))
    }
}
