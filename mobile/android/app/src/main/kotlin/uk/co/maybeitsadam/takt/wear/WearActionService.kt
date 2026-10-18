package uk.co.maybeitsadam.takt.wear

import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import java.time.Instant
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.appContainer
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository
import uk.co.maybeitsadam.takt.wear.contract.DEFAULT_BLOCK_SECONDS
import uk.co.maybeitsadam.takt.wear.contract.WearAction
import uk.co.maybeitsadam.takt.wear.contract.WearActionKind
import uk.co.maybeitsadam.takt.wear.contract.WearCodec
import uk.co.maybeitsadam.takt.wear.contract.WearPaths

/**
 * Takes the watch's messages. Play Services starts it (and so the app's
 * process) when one arrives, so an action from the watch lands even when the
 * phone app is not running.
 */
class WearActionService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        val container = applicationContext.appContainer
        WearBridge.watchSeen()
        when (event.path) {
            WearPaths.REFRESH -> WearBridge.refresh(container)
            WearPaths.ACTION -> {
                val action = WearCodec.decodeAction(event.data) ?: run {
                    Log.w(TAG, "Unreadable action from the watch")
                    return
                }
                if (WearBridge.isHandled(action.id)) return WearBridge.refresh(container)
                // Messages arrive one at a time on this thread; waiting here keeps a queue
                // flushed from the watch in the order it was made.
                runBlocking { withTimeoutOrNull(TIMEOUT_MILLIS) { WearActions(container).perform(action) } }
                WearBridge.markHandled(action.id)
            }
        }
    }

    private companion object {
        const val TAG = "WearActionService"
        const val TIMEOUT_MILLIS = 15_000L
    }
}

/**
 * What each watch action does, through the same undo calls the phone's own
 * Today and focus notification make, so every one is an ordinary undoable step.
 * Each checks the state first, so an action replayed from the watch's queue
 * after the phone already moved on does nothing.
 */
class WearActions(private val container: AppContainer) {
    private val undo get() = container.undo

    suspend fun perform(action: WearAction) {
        val repo = container.repository()
        val session = repo.activeFocusSession()?.takeIf { it.phase != FocusSessionPhase.FINISHED }
        val taskId = action.taskId
        when (action.action) {
            WearActionKind.COMPLETE -> taskId?.let { complete(repo, it, session) }
            WearActionKind.LOG_DAILY -> taskId?.let { logDaily(repo, it) }
            WearActionKind.START -> taskId?.let { start(repo, it, session) }
            WearActionKind.PAUSE -> if (session != null && session.activeTaskId != null && session.pausedAt == null) {
                undo.performNow(announce = false) { it.pauseFocusSession(session.id) }
            }
            WearActionKind.RESUME -> if (session != null && session.pausedAt != null) {
                undo.performNow(announce = false) { it.resumeFocusSession(session.id) }
            }
            WearActionKind.STOP -> session?.let { stop(it) }
            WearActionKind.DONE -> session?.let { done(it) }
        }
    }

    /** Today's tick: the running task is Done; a daily or habit logs today; anything else completes. */
    private suspend fun complete(repo: WorkspaceRepository, taskId: String, session: FocusSession?) {
        if (session != null && session.activeTaskId == taskId) return done(session)
        if (logDaily(repo, taskId)) return
        val task = repo.task(taskId) ?: return
        if (task.status != TaskStatus.OPEN) return
        undo.performNow { it.setStatus(TaskStatus.COMPLETED, taskId) }
    }

    /** Logs today's contribution to [taskId]'s daily unless it is already in; false when the task is no daily. */
    private suspend fun logDaily(repo: WorkspaceRepository, taskId: String): Boolean {
        val today = repo.dailies().firstOrNull { it.task.id == taskId }
        val daily = today?.daily ?: repo.daily(taskId)?.takeIf { it.isHabit } ?: return false
        if (today?.isDoneToday != true) undo.performNow { it.logContribution(daily.id) }
        return true
    }

    /** Play, as on Today's card: with a block already running, the task joins its queue. */
    private suspend fun start(repo: WorkspaceRepository, taskId: String, session: FocusSession?) {
        if (session != null && session.activeTaskId == taskId) return
        if (session != null && session.phase == FocusSessionPhase.RUNNING && session.activeTaskId != null) {
            undo.performNow(announce = false) {
                it.addToFocusQueue(session.id, taskId)
                undo.say("Queued after the running task")
            }
            return
        }
        val title = repo.task(taskId)?.title ?: return
        undo.performNow(announce = false) {
            val now = Instant.now()
            val candidate = it.nextUpCandidates(now).firstOrNull { candidate -> candidate.id == taskId }
            val planned = candidate?.let { found -> TaskAvailabilityPolicy.suggestedSeconds(found, FocusContext(), now) }
                ?: repo.task(taskId)?.estimateSeconds ?: DEFAULT_BLOCK_SECONDS
            it.startFocusSession(taskId, plannedSeconds = planned, context = FocusContext(), overrideAvailability = true, now = now)
            undo.say("Focus started on $title")
        }
    }

    /** The Focus screen's "End session": the time so far is logged, unscored, and the task stays open. */
    private suspend fun stop(session: FocusSession) {
        val now = Instant.now()
        undo.performNow(announce = false) { repo ->
            if (session.activeTaskId != null) {
                repo.completeActiveFocusTask(
                    sessionId = session.id, elapsedSeconds = session.elapsedSeconds(now), completeTask = false,
                    expectedBlockId = session.activeBlockId,
                )
            }
            repo.finishFocusSession(session.id, now)
            undo.say("Session ended")
        }
    }

    /** The focus notification's Done: the block is credited, unscored, and its task completed. */
    private suspend fun done(session: FocusSession) {
        if (session.activeTaskId == null) return
        undo.performNow { repo ->
            repo.completeActiveFocusTask(
                sessionId = session.id,
                elapsedSeconds = session.elapsedSeconds(Instant.now()),
                completeTask = true,
                expectedBlockId = session.activeBlockId,
            )
        }
    }
}
