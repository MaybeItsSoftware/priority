package uk.co.maybeitsadam.priority.app

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The task whose inspector is open: a sheet on phones, a pane on wide screens. */
class InspectorController {
    private val _taskId = MutableStateFlow<String?>(null)
    val taskId: StateFlow<String?> = _taskId.asStateFlow()

    fun open(taskId: String) {
        _taskId.value = taskId
    }

    fun close() {
        _taskId.value = null
    }
}

/** Where a quick add should file its task; null fields mean the Inbox. */
data class QuickAddRequest(
    val listId: String? = null,
    val parentTaskId: String? = null,
    /** Text to start with, e.g. from a share or the search field. */
    val text: String = "",
    /** Bumped on every request so the same request twice still reopens the sheet. */
    val nonce: Long = System.nanoTime(),
)

/** Opens the quick-add sheet from anywhere: the FAB, the tile, the launcher shortcut, Ctrl+N. */
class QuickAddController {
    private val _contextListId = MutableStateFlow<String?>(null)

    /** The list on screen, if any; the FAB and Ctrl+N file into it rather than the Inbox. */
    val contextListId: StateFlow<String?> = _contextListId.asStateFlow()

    fun setContextList(listId: String?) {
        _contextListId.value = listId
    }

    private val _request = MutableStateFlow<QuickAddRequest?>(null)
    val request: StateFlow<QuickAddRequest?> = _request.asStateFlow()

    fun open(request: QuickAddRequest = QuickAddRequest()) {
        _request.value = request
    }

    fun close() {
        _request.value = null
    }
}
