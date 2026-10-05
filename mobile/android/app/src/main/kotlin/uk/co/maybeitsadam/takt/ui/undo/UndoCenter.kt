package uk.co.maybeitsadam.takt.ui.undo

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.core.TaskPlanningException
import uk.co.maybeitsadam.takt.data.workspace.HistoryEntry
import uk.co.maybeitsadam.takt.data.workspace.TaskEditorException
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceStoreException

/** What the snackbar offers after a message. */
enum class SnackAction(val label: String) { UNDO("Undo"), REDO("Redo") }

/** One snackbar: what happened, and optionally the step that takes it back. */
data class SnackMessage(val text: String, val action: SnackAction? = null, val isError: Boolean = false)

/** The two labels the toolbar's undo and redo buttons show; null when there is nothing. */
data class HistoryLabels(val undo: String?, val redo: String?)

/**
 * Every edit to the user's work goes through [perform], which runs it on the
 * repository (one journal group, so one undo step), then posts a snackbar
 * naming the step with an Undo action. Failures post the store's own message.
 */
class UndoCenter(private val container: AppContainer) {
    private val _messages = MutableSharedFlow<SnackMessage>(extraBufferCapacity = 8)
    val messages: SharedFlow<SnackMessage> = _messages.asSharedFlow()

    /** Undo/redo labels, live. */
    val labels: StateFlow<HistoryLabels> = container.withSession { session ->
        kotlinx.coroutines.flow.flow {
            session.repository.observeHistoryLabels().collect { (undo, redo) -> emit(HistoryLabels(undo, redo)) }
        }
    }.stateIn(container.scope, SharingStarted.WhileSubscribed(5_000), HistoryLabels(null, null))

    /** Runs [block] in the app scope (it survives the screen) and reports it. */
    fun perform(
        announce: Boolean = true,
        message: String? = null,
        block: suspend (WorkspaceRepository) -> Unit,
    ) {
        container.scope.launch { performNow(announce, message, block) }
    }

    /** As [perform], but suspends until the write is done. Returns false if it failed. */
    suspend fun performNow(
        announce: Boolean = true,
        message: String? = null,
        block: suspend (WorkspaceRepository) -> Unit,
    ): Boolean {
        val repository = container.repository()
        return try {
            block(repository)
            if (announce) {
                val label = message ?: repository.undoableLabel()
                if (label != null) _messages.tryEmit(SnackMessage(label, SnackAction.UNDO))
            }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            report(error)
            false
        }
    }

    fun undo() {
        container.scope.launch {
            val label = container.repository().undo()
            _messages.tryEmit(
                if (label != null) SnackMessage("Undid ${label.lowercaseFirst()}", SnackAction.REDO) else SnackMessage("Nothing to undo"),
            )
        }
    }

    fun redo() {
        container.scope.launch {
            val label = container.repository().redo()
            _messages.tryEmit(
                if (label != null) SnackMessage("Redid ${label.lowercaseFirst()}", SnackAction.UNDO) else SnackMessage("Nothing to redo"),
            )
        }
    }

    /** Undoes or redoes until [entry] is the newest applied step. */
    fun travel(to: HistoryEntry, history: List<HistoryEntry>) {
        container.scope.launch {
            val repository = container.repository()
            val index = history.indexOfFirst { it.groupId == to.groupId }
            if (index < 0) return@launch
            if (to.isUndone) {
                // Redo every undone step from the oldest undone up to and including this one.
                val steps = history.subList(index, history.size).count { it.isUndone }
                repeat(steps) { repository.redo() }
            } else {
                val steps = history.subList(0, index).count { !it.isUndone }
                repeat(steps) { repository.undo() }
            }
            _messages.tryEmit(SnackMessage("Back to ${(to.label ?: "that step").lowercaseFirst()}"))
        }
    }

    /** Posts a plain message (no action). */
    fun say(text: String) {
        _messages.tryEmit(SnackMessage(text))
    }

    fun report(error: Throwable) {
        val text = when (error) {
            is WorkspaceStoreException -> error.error.message
            is TaskPlanningException -> error.error.message
            is TaskEditorException -> error.error.message
            else -> error.message ?: "Something went wrong."
        }
        _messages.tryEmit(SnackMessage(text, isError = true))
    }

    /** Re-exposed for screens that only need the flow. */
    fun messagesFlow(): Flow<SnackMessage> = messages
}

private fun String.lowercaseFirst(): String = if (isEmpty()) this else this[0].lowercaseChar() + substring(1)
