package uk.co.maybeitsadam.takt.ui.conditions

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.ImmutableSet
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentMapOf
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.collections.immutable.toImmutableMap
import kotlinx.collections.immutable.toImmutableSet
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.core.TaskCondition
import uk.co.maybeitsadam.takt.data.workspace.ConditionGroup
import uk.co.maybeitsadam.takt.data.workspace.ConditionGroups
import uk.co.maybeitsadam.takt.data.workspace.emptyFocusContext
import uk.co.maybeitsadam.takt.ui.today.minuteTicks

/** The conditions, how many open tasks need each, and which hold now. */
@Immutable
data class ConditionsState(
    val conditions: ImmutableList<TaskCondition> = persistentListOf(),
    /** Open tasks requiring each condition, by id; one nothing needs is absent. */
    val usage: ImmutableMap<String, Int> = persistentMapOf(),
    /** What holds now, as the workspace keeps it, with an expired context set aside. */
    val selected: ImmutableSet<String> = persistentSetOf(),
    /** Said on an earlier day: probably not where you are now. The core's rule. */
    val isStale: Boolean = false,
    val isLoaded: Boolean = false,
) {
    val live: List<TaskCondition> get() = conditions.filter { !it.isArchived }

    /** What "where you are" offers: what an open task needs, and whatever is on. The core's rule. */
    val available: List<ConditionGroup> get() = ConditionGroups.available(conditions, usage.keys, selected)

    fun name(id: String): String = conditions.firstOrNull { it.id == id }?.name ?: "Missing condition"
}

/**
 * The conditions sheets' state: saying what holds now (shared through the
 * workspace's focus context with Focus, the Mac, the iPhone and the agent),
 * and making a condition from the sheet's search field.
 */
class ConditionsViewModel(private val container: AppContainer) : ViewModel() {
    val state: StateFlow<ConditionsState> = container.withSession { session ->
        val repo = session.repository
        val workspace = session.workspace.id
        combine(
            repo.observeConditions(workspace),
            repo.observeConditionUsage(workspace),
            repo.observeFocusContext(workspace),
            minuteTicks(),
        ) { conditions, usage, saved, _ ->
            val now = Instant.now()
            val context = saved?.let { uniffi.takt_core.focusContextInForce(it, now.toEpochMilli()) } ?: emptyFocusContext()
            ConditionsState(
                conditions = conditions.toImmutableList(),
                usage = usage.toImmutableMap(),
                selected = context.conditionIds.toImmutableSet(),
                isStale = uniffi.takt_core.focusContextIsStale(context, now.toEpochMilli(), ZoneId.systemDefault().id),
                isLoaded = true,
            )
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ConditionsState())

    /** Says [condition] holds now, or no longer does. A place replaces the last: the core's rule, as Focus's chips. */
    fun toggleNow(condition: TaskCondition) {
        val current = state.value
        val next = uniffi.takt_core.focusContextToggle(
            condition.id,
            condition.isLocation,
            current.selected.toList(),
            current.conditions.filter { it.isLocation }.map { it.id },
        )
        saveContext { it.copy(conditionIds = next, suggestedIds = emptyList()) }
    }

    /** Nothing holds any more: every condition off. */
    fun clearNow() {
        saveContext { it.copy(conditionIds = emptyList(), suggestedIds = emptyList()) }
    }

    /**
     * Makes a condition with no category (filed later, as on the Mac), one
     * undo step, then hands it to [then] — to turn it on, or require it.
     */
    fun createCondition(name: String, then: (TaskCondition) -> Unit) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            var made: TaskCondition? = null
            container.undo.performNow { repo -> made = repo.createCondition(container.awaitSession().workspace.id, trimmed, null) }
            made?.let(then)
        }
    }

    /** Saves the context into the workspace, changed by [change]. Not an undo step. */
    private fun saveContext(change: (uniffi.takt_core.StoredFocusContext) -> uniffi.takt_core.StoredFocusContext) {
        viewModelScope.launch {
            val session = container.awaitSession()
            val repo = session.repository
            val current = repo.focusContext(session.workspace.id) ?: emptyFocusContext()
            repo.saveFocusContext(session.workspace.id, change(current))
        }
    }
}
