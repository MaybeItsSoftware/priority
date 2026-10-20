package uk.co.maybeitsadam.takt.ui.actions

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.data.workspace.RecurrenceClashChoice
import uk.co.maybeitsadam.takt.data.workspace.TaskRecurrenceClash
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository
import uk.co.maybeitsadam.takt.data.workspace.addOccurrenceCopy

/**
 * How a clash is worded: the same sentences as the Mac's and the iPhone's
 * (`TaskRecurrenceClash.title` / `message` in TaktWorkspace).
 */
object RecurrenceClashText {
    private val day = DateTimeFormatter.ofPattern("EEE d MMM", Locale.UK)

    /** The day as every prompt writes it: `Mon 20 Oct`. */
    fun day(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String = day.format(instant.atZone(zone))

    /** `Water the plants comes round again on Mon 20 Oct`. */
    fun title(task: String, clash: TaskRecurrenceClash, zone: ZoneId = ZoneId.systemDefault()): String =
        "$task comes round again on ${day(clash.nextTurn, zone)}"

    /** Whether the move lands on the turn itself rather than past it. */
    fun landsOnTurn(clash: TaskRecurrenceClash, zone: ZoneId = ZoneId.systemDefault()): Boolean =
        clash.movedTo.atZone(zone).toLocalDate() == clash.nextTurn.atZone(zone).toLocalDate()

    /** `Moving it to Mon 20 Oct lands on that turn.` */
    fun message(clash: TaskRecurrenceClash, zone: ZoneId = ZoneId.systemDefault()): String =
        "Moving it to ${day(clash.movedTo, zone)} ${if (landsOnTurn(clash, zone)) "lands on" else "goes past"} that turn."
}

/** A clash waiting on an answer: what the sheet draws, and where the answer goes. */
data class PendingRecurrenceClash(
    val taskTitle: String,
    val clash: TaskRecurrenceClash,
    internal val answer: (RecurrenceClashChoice) -> Unit,
) {
    val title: String get() = RecurrenceClashText.title(taskTitle, clash)
    val message: String get() = RecurrenceClashText.message(clash)
}

/**
 * The one open question about a clash, held until the sheet
 * (`RecurrenceClashSheet`, drawn by the app shell) answers it.
 */
open class RecurrenceClashQuestions {
    private val _pending = MutableStateFlow<PendingRecurrenceClash?>(null)
    val pending: StateFlow<PendingRecurrenceClash?> = _pending.asStateFlow()

    /**
     * The person's choice about [clash]; Stack, without asking, when there is
     * no clash. A question still open when another is asked is cancelled.
     */
    suspend fun choose(taskTitle: String, clash: TaskRecurrenceClash?): RecurrenceClashChoice {
        if (clash == null) return RecurrenceClashChoice.STACK
        return suspendCancellableCoroutine { continuation ->
            val pending = PendingRecurrenceClash(taskTitle, clash) { choice ->
                if (continuation.isActive) continuation.resume(choice)
            }
            _pending.value?.answer?.invoke(RecurrenceClashChoice.CANCEL)
            _pending.value = pending
            continuation.invokeOnCancellation { _pending.compareAndSet(pending, null) }
        }
    }

    /** The sheet's answer; dismissing it is Cancel. */
    fun answer(choice: RecurrenceClashChoice) {
        val pending = _pending.value ?: return
        _pending.value = null
        pending.answer(choice)
    }
}

/**
 * Asks what should happen when a move lands a repeating task on the day it
 * comes round again anyway. The core says whether it does (the repository's
 * `recurrenceClash`); the question is [RecurrenceClashQuestions]'.
 */
class RecurrenceClashes(private val container: AppContainer) : RecurrenceClashQuestions() {
    /**
     * A move written straight away: asks first if [find] names a clash, then
     * runs [move] as one step, then [then], and, for Keep both, the copy,
     * which the core joins to the move's step so one undo takes both back.
     * Cancel writes nothing.
     */
    fun move(
        taskId: String,
        taskTitle: String? = null,
        message: String? = null,
        find: suspend (WorkspaceRepository) -> TaskRecurrenceClash?,
        then: () -> Unit = {},
        move: suspend (WorkspaceRepository) -> Unit,
    ) {
        container.scope.launch {
            val repository = container.repository()
            // A clash that cannot be read is no reason to stop the move.
            val clash = runCatching { find(repository) }.getOrNull()
            val choice = if (clash == null) {
                RecurrenceClashChoice.STACK
            } else {
                choose(taskTitle ?: runCatching { repository.task(taskId)?.title }.getOrNull() ?: "This task", clash)
            }
            if (!choice.saves) return@launch
            if (!container.undo.performNow(message = message, block = move)) return@launch
            then()
            keepBothIfChosen(choice, taskId)
        }
    }

    /** The second step of Keep both, after the move has been saved. */
    suspend fun keepBothIfChosen(choice: RecurrenceClashChoice, taskId: String) {
        if (choice.addsCopy) container.undo.performNow { it.addOccurrenceCopy(taskId) }
    }
}
