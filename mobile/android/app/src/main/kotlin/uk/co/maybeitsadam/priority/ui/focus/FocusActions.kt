package uk.co.maybeitsadam.priority.ui.focus

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.FocusSessionPhase
import uk.co.maybeitsadam.priority.core.StaleFocusResolution
import uk.co.maybeitsadam.priority.data.workspace.FocusCompletion
import uk.co.maybeitsadam.priority.data.workspace.FocusCompletionOutcome
import uk.co.maybeitsadam.priority.ui.components.Format

/**
 * The block's controls, shared by Today's running card and the Focus screen,
 * so pausing, logging and finishing behave the same from both.
 */
class FocusActions(private val container: AppContainer) {
    fun togglePause(session: FocusSession) = container.undo.perform(announce = false) { repo ->
        if (session.pausedAt == null) repo.pauseFocusSession(session.id) else repo.resumeFocusSession(session.id)
    }

    /**
     * Stops the clock and returns the block to ask about. `completeTask`
     * false is "log and keep": the time is credited and the task stays open.
     */
    fun requestCompletion(session: FocusSession, title: String, completeTask: Boolean, now: Instant = Instant.now()): PendingCompletion? {
        val taskId = session.activeTaskId ?: return null
        val pending = PendingCompletion(
            sessionId = session.id, taskId = taskId, title = title, seconds = session.elapsedSeconds(now),
            completeTask = completeTask, blockId = session.activeBlockId, wasPaused = session.pausedAt != null,
        )
        if (session.pausedAt == null) container.undo.perform(announce = false) { it.pauseFocusSession(session.id, now) }
        return pending
    }

    /** Drops the question, resuming a block that was running when it was asked. */
    fun cancel(pending: PendingCompletion) {
        if (!pending.wasPaused) container.undo.perform(announce = false) { it.resumeFocusSession(pending.sessionId) }
    }

    /** Credits the time the block took and scores it; null [multiplier] skips the score. */
    fun confirm(
        pending: PendingCompletion,
        multiplier: Double?,
        context: FocusContext = FocusContext(),
        onDone: (FocusCompletion) -> Unit = {},
    ) = container.undo.perform(message = completionLabel(pending)) { repo ->
        val completion = repo.completeActiveFocusTask(
            sessionId = pending.sessionId,
            elapsedSeconds = pending.seconds,
            qualityMultiplier = multiplier,
            completeTask = pending.completeTask,
            expectedBlockId = pending.blockId,
            context = context,
        )
        onDone(completion)
    }

    /** Ends the session, logging a running block's time without a score. */
    fun endSession(session: FocusSession, context: FocusContext = FocusContext(), now: Instant = Instant.now()) =
        container.undo.perform(announce = false) { repo ->
            if (session.activeTaskId != null) {
                repo.completeActiveFocusTask(
                    sessionId = session.id, elapsedSeconds = session.elapsedSeconds(now), completeTask = false,
                    expectedBlockId = session.activeBlockId, context = context,
                )
            }
            repo.finishFocusSession(session.id, now)
            container.undo.say("Session ended")
        }

    private fun completionLabel(pending: PendingCompletion): String =
        if (pending.completeTask) "Completed ${pending.title}" else "Logged ${Format.duration(pending.seconds)} on ${pending.title}"

    companion object {
        fun outcomeText(outcome: FocusCompletionOutcome): String = when (outcome) {
            FocusCompletionOutcome.TaskCompleted -> "Task done"
            is FocusCompletionOutcome.ProgressLogged -> "Logged ${Format.duration(outcome.seconds)}"
            is FocusCompletionOutcome.ContributionLogged -> "Daily +${Format.duration(outcome.seconds)}"
        }
    }
}

/** Settles a session left paused on an earlier day, once per process, when Today or Focus first opens. */
object StaleFocus {
    private val resolved = AtomicBoolean(false)

    fun resolveOnce(container: AppContainer) {
        if (!resolved.compareAndSet(false, true)) return
        container.scope.launch {
            val resolution = runCatching { container.repository().resolveStaleFocusSession() }.getOrNull()
            when (resolution) {
                StaleFocusResolution.CLOSE -> container.undo.say("Closed the block left paused on an earlier day and logged its time")
                StaleFocusResolution.DISCARD -> container.undo.say("Ended the block left paused on an earlier day")
                StaleFocusResolution.KEEP, null -> Unit
            }
        }
    }
}

/** Whether the block's clock is moving. */
val FocusSession.isTicking: Boolean get() = phase == FocusSessionPhase.RUNNING && pausedAt == null && activeTaskId != null

/**
 * The current time, advancing every [periodMillis] while [active] and the
 * screen is at least started; it stops when the screen is not visible.
 */
@Composable
fun rememberTicker(active: Boolean, periodMillis: Long = 1_000): State<Instant> {
    val now = remember { mutableStateOf(Instant.now()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(active, periodMillis, lifecycle) {
        now.value = Instant.now()
        if (!active) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now.value = Instant.now()
                delay(periodMillis - (System.currentTimeMillis() % periodMillis).coerceAtMost(periodMillis - 1))
            }
        }
    }
    return now
}

/**
 * Asks for POST_NOTIFICATIONS (API 33+) the first time a block is started
 * here, then runs the start whatever the answer: without the permission the
 * block still runs, only its notification is hidden.
 */
@Composable
fun rememberNotificationGate(): (() -> Unit) -> Unit {
    val context = LocalContext.current
    val asked = rememberSaveable { mutableStateOf(false) }
    val pending = remember { mutableStateOf<(() -> Unit)?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        pending.value?.invoke()
        pending.value = null
    }
    return remember(context, launcher) {
        { start ->
            val needsAsking = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                !asked.value
            if (needsAsking) {
                asked.value = true
                pending.value = start
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                start()
            }
        }
    }
}
