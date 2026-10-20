package uk.co.maybeitsadam.takt.ui.search

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
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
import uk.co.maybeitsadam.takt.data.workspace.blockedTaskIds
import uk.co.maybeitsadam.takt.data.workspace.buriedStarts
import uk.co.maybeitsadam.takt.data.workspace.observeSidebar
import uk.co.maybeitsadam.takt.data.workspace.waitingDetails
import uk.co.maybeitsadam.takt.ui.lists.WaitingBadge
import uk.co.maybeitsadam.takt.core.TaskStatus
import java.time.LocalDate
import java.time.ZoneId

@Immutable
data class SearchState(
    /** The query the results answer; null before the first search. */
    val query: String? = null,
    val results: ImmutableList<TaskSearchResult> = persistentListOf(),
    /** Results waiting on an open task, drawn greyed. */
    val blockedIds: Set<String> = emptySet(),
    /** Results whose start is still to come, and when: drawn greyed, with the day they start. */
    val buriedStarts: Map<String, java.time.Instant> = emptyMap(),
    /** Results filed in Waiting on: who they wait on and when to chase them. */
    val waiting: Map<String, WaitingBadge> = emptyMap(),
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
                .filter { "tasks" in it || "task_lists" in it || "task_dependencies" in it || "task_metadata" in it }
                .map { }
                .onStart { emit(Unit) }
                .map {
                    val results = repository.searchTasks(session.workspace.id, query, includingCompleted = include)
                    val blocked = repository.blockedTaskIds()
                    val details = repository.waitingDetails()
                    val today = LocalDate.now()
                    val zone = ZoneId.systemDefault()
                    SearchState(
                        query,
                        results.toImmutableList(),
                        results.mapNotNullTo(HashSet()) { r -> r.task.id.takeIf { it in blocked } },
                        repository.buriedStarts(results.map { it.task.id }),
                        results.mapNotNull { r ->
                            WaitingBadge.of(details[r.task.id], r.task.status == TaskStatus.OPEN, today, zone)?.let { r.task.id to it }
                        }.toMap(),
                    )
                }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SearchState())

    /** Commands run from Find, newest first: what it lifts, and lists with nothing typed. */
    private val recents: Flow<List<String>> = container.settings.string(RECENT_COMMANDS).map(FindModel::decodeRecents)

    private val places: Flow<List<FindPlace>> = container.withSession { session ->
        session.repository.observeSidebar(session.workspace.id).map(FindModel::places)
    }

    /** The commands and places matching the query. Instant: no store read, so no debounce. */
    val palette: StateFlow<FindPalette> = combine(_query, recents, places.onStart { emit(emptyList()) }) { q, r, p ->
        FindModel.palette(q, r, p)
    }.flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FindPalette(commands = FindModel.commands.toImmutableList()))

    fun recordCommand(id: String) {
        container.scope.launch {
            val current = FindModel.decodeRecents(container.settings.string(RECENT_COMMANDS).first())
            container.settings.putString(RECENT_COMMANDS, FindModel.encodeRecents(FindModel.recording(id, current)))
        }
    }

    fun inspect(taskId: String) = container.inspector.open(taskId)

    fun toggle(result: TaskSearchResult) = container.commands.toggleComplete(result.task)

    companion object {
        const val DEBOUNCE_MS = 150L
        const val RECENT_COMMANDS = "findRecentCommands"
    }
}
