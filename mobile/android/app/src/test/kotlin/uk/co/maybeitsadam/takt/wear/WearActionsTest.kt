package uk.co.maybeitsadam.takt.wear

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.session
import uk.co.maybeitsadam.takt.wear.contract.WearAction
import uk.co.maybeitsadam.takt.wear.contract.WearActionKind

/** A timer action from the watch acts only on the block it was tapped on. */
class WearActionsTest {
    private fun action(kind: WearActionKind, taskId: String?) = WearAction(id = "a", action = kind, taskId = taskId, issuedAt = 0)

    @Test fun doneForTheRunningTaskActs() {
        assertTrue(WearActions.targetsRunningTask(action(WearActionKind.DONE, "A"), session("A")))
    }

    @Test fun doneForATaskSinceReplacedIsIgnored() {
        for (kind in listOf(WearActionKind.DONE, WearActionKind.PAUSE, WearActionKind.RESUME, WearActionKind.STOP)) {
            assertFalse(kind.name, WearActions.targetsRunningTask(action(kind, "A"), session("B")))
            assertFalse(kind.name, WearActions.targetsRunningTask(action(kind, "A"), null))
        }
    }

    @Test fun anOlderWatchNamingNoTaskActsAsBefore() {
        assertTrue(WearActions.targetsRunningTask(action(WearActionKind.STOP, null), session("B")))
    }

    @Test fun ticksAndStartsAreNotTimerActions() {
        assertTrue(WearActions.targetsRunningTask(action(WearActionKind.COMPLETE, "A"), session("B")))
        assertTrue(WearActions.targetsRunningTask(action(WearActionKind.START, "A"), session("B")))
    }
}
