package uk.co.maybeitsadam.takt.ui.lists

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import uk.co.maybeitsadam.takt.app.AppContainer
import java.time.LocalDate
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.FilterListScope
import uk.co.maybeitsadam.takt.data.workspace.TaskWaitingDetails
import uk.co.maybeitsadam.takt.data.workspace.observeFilterListScope
import uk.co.maybeitsadam.takt.data.workspace.observeWaitingDetails

/** One list's share of a filter list's matches, in the core's board order. */
@Immutable
data class FilterListSection(val list: TaskList, val tasks: ImmutableList<WorkspaceTask>)

@Immutable
data class FilterListState(
    val name: String,
    /** The core's sentence for the rules (`describeFilterDefinition`). */
    val summary: String,
    val sections: ImmutableList<FilterListSection>,
    val blockedTaskIds: Set<String>,
    val count: Int,
    val isLoaded: Boolean,
    /** Deleted, on this device or another, while it was open. */
    val isMissing: Boolean,
    /** Matches filed in Waiting on: who they wait on and when to chase them. */
    val waiting: Map<String, WaitingBadge> = emptyMap(),
) {
    companion object {
        val Empty = FilterListState("", "", persistentListOf(), emptySet(), 0, isLoaded = false, isMissing = false)
    }
}

/** Shaping a filter list's matches into sections. Pure, so it is tested on the JVM. */
object FilterListShaping {
    fun shape(
        scope: FilterListScope,
        waiting: Map<String, TaskWaitingDetails> = emptyMap(),
        today: LocalDate = LocalDate.now(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): FilterListState {
        val filterList = scope.filterList
            ?: return FilterListState.Empty.copy(isLoaded = true, isMissing = true)
        // The core returns them list by list; grouping keeps that order.
        val sections = scope.matches
            .groupBy { it.list.id }
            .values
            .map { group -> FilterListSection(group.first().list, group.map { it.task }.toImmutableList()) }
        return FilterListState(
            name = filterList.name,
            summary = filterList.summary,
            sections = sections.toImmutableList(),
            blockedTaskIds = scope.blockedTaskIds,
            count = scope.matches.size,
            isLoaded = true,
            isMissing = false,
            waiting = scope.matches.mapNotNull { m ->
                WaitingBadge.of(waiting[m.task.id], m.task.status == TaskStatus.OPEN, today, zone)?.let { m.task.id to it }
            }.toMap(),
        )
    }
}

/** A filter list's matching tasks, read-only, re-read whenever anything its rules read changes. */
class FilterListViewModel(private val container: AppContainer, id: String) : ViewModel() {
    val state: StateFlow<FilterListState> = container.withSession { session ->
        combine(session.repository.observeFilterListScope(session.workspace.id, id), session.repository.observeWaitingDetails()) { scope, waiting ->
            FilterListShaping.shape(scope, waiting)
        }
    }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FilterListState.Empty)

    fun inspect(taskId: String) = container.inspector.open(taskId)
}
