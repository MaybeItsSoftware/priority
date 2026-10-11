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
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.FilterListScope
import uk.co.maybeitsadam.takt.data.workspace.observeFilterListScope

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
) {
    companion object {
        val Empty = FilterListState("", "", persistentListOf(), emptySet(), 0, isLoaded = false, isMissing = false)
    }
}

/** Shaping a filter list's matches into sections. Pure, so it is tested on the JVM. */
object FilterListShaping {
    fun shape(scope: FilterListScope): FilterListState {
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
        )
    }
}

/** A filter list's matching tasks, read-only, re-read whenever anything its rules read changes. */
class FilterListViewModel(private val container: AppContainer, id: String) : ViewModel() {
    val state: StateFlow<FilterListState> = container.withSession { it.repository.observeFilterListScope(it.workspace.id, id) }
        .map { FilterListShaping.shape(it) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FilterListState.Empty)

    fun inspect(taskId: String) = container.inspector.open(taskId)
}
