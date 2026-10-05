package uk.co.maybeitsadam.takt.ui.search

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.data.workspace.TaskSearchResult

@Immutable
data class SearchState(
    /** The query the results answer; null before the first search. */
    val query: String? = null,
    val results: ImmutableList<TaskSearchResult> = persistentListOf(),
)

/** Search: FTS through the repository, debounced, re-run when tasks change under it. */
class SearchViewModel(private val container: AppContainer) : ViewModel() {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query

    private val _includeCompleted = MutableStateFlow(false)
    val includeCompleted: StateFlow<Boolean> = _includeCompleted

    fun setQuery(text: String) {
        _query.value = text
    }

    fun setIncludeCompleted(include: Boolean) {
        _includeCompleted.value = include
    }

    val state: StateFlow<SearchState> = combine(_query.debounce { if (it.isBlank()) 0L else DEBOUNCE_MS }, _includeCompleted) { q, c ->
        q.trim() to c
    }.flatMapLatest { (query, include) ->
        if (query.isEmpty()) return@flatMapLatest flowOf(SearchState(query, persistentListOf()))
        container.withSession { session ->
            val repository = session.repository
            repository.database.invalidations
                .filter { "tasks" in it || "task_lists" in it }
                .map { }
                .onStart { emit(Unit) }
                .map {
                    val results = repository.searchTasks(session.workspace.id, query, includingCompleted = include)
                    SearchState(query, results.toImmutableList())
                }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SearchState())

    fun inspect(taskId: String) = container.inspector.open(taskId)

    fun toggle(result: TaskSearchResult) = container.commands.toggleComplete(result.task)

    companion object {
        const val DEBOUNCE_MS = 150L
    }
}
