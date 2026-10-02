package uk.co.maybeitsadam.priority.ui.focus

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableSet
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.collections.immutable.toImmutableSet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.BlockedFocusTask
import uk.co.maybeitsadam.priority.core.FocusAward
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.core.FocusPointsSummary
import uk.co.maybeitsadam.priority.core.FocusQueueState
import uk.co.maybeitsadam.priority.core.FocusQueueTask
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.FocusSessionPhase
import uk.co.maybeitsadam.priority.core.FocusTimeMode
import uk.co.maybeitsadam.priority.core.ScoredNextUp
import uk.co.maybeitsadam.priority.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.priority.core.TaskCondition
import uk.co.maybeitsadam.priority.core.TaskPlanningError
import uk.co.maybeitsadam.priority.core.TaskPlanningException
import uk.co.maybeitsadam.priority.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.priority.data.workspace.FocusCompletionOutcome
import uk.co.maybeitsadam.priority.ui.today.dayTicks
import uk.co.maybeitsadam.priority.ui.today.minuteTicks

/** A start the context rules out, held for the user to confirm. */
@Immutable
data class StartOverride(val taskId: String, val title: String, val plannedSeconds: Int, val explanation: String)

/** What the last finished block earned, shown until dismissed. */
@Immutable
data class LastBlock(val award: FocusAward?, val outcome: FocusCompletionOutcome)

/** Where you are, how long you have, and whether to make progress or finish. */
@Immutable
data class FocusContextState(
    val selected: ImmutableSet<String> = persistentSetOf(),
    val mode: FocusTimeMode = FocusTimeMode.PROGRESS,
    val time: AvailableTime = AvailableTime.Unlimited,
    val endsAt: Instant? = null,
) {
    val context: FocusContext get() = FocusContext(selected, endsAt, mode)
}

/** Everything the Focus screen draws. */
@Immutable
data class FocusUiState(
    val ladder: ImmutableList<ScoredNextUp> = persistentListOf(),
    val blocked: ImmutableList<BlockedFocusTask> = persistentListOf(),
    val conditions: ImmutableList<TaskCondition> = persistentListOf(),
    val hasManualOrder: Boolean = false,
    val session: FocusSession? = null,
    val activeTitle: String? = null,
    val queue: ImmutableList<FocusQueueTask> = persistentListOf(),
    val points: FocusPointsSummary = FocusPointsSummary.ZERO,
    val isLoaded: Boolean = false,
) {
    /** A block with a task: the running view replaces the ladder. */
    val isRunning: Boolean get() = session != null && session.phase != FocusSessionPhase.FINISHED
}

private const val CONDITIONS_KEY = "focus.conditions"
private const val MODE_KEY = "focus.mode"

/** The Focus screen: the context, the ladder ranked for it, the staged task, and the running block. */
@OptIn(ExperimentalCoroutinesApi::class)
class FocusViewModel(private val container: AppContainer) : ViewModel() {
    private val actions = FocusActions(container)
    private val settings = container.settings

    private val time = MutableStateFlow<Pair<AvailableTime, Instant?>>(AvailableTime.Unlimited to null)

    val contextState: StateFlow<FocusContextState> = combine(
        settings.stringSet(CONDITIONS_KEY),
        settings.string(MODE_KEY),
        time,
    ) { selected, mode, (available, endsAt) ->
        FocusContextState(selected.toImmutableSet(), FocusTimeMode.of(mode ?: "") ?: FocusTimeMode.PROGRESS, available, endsAt)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, FocusContextState())

    private val _staged = MutableStateFlow<String?>(null)
    val staged: StateFlow<String?> = _staged.asStateFlow()

    private val _stagedMinutes = MutableStateFlow(25)
    val stagedMinutes: StateFlow<Int> = _stagedMinutes.asStateFlow()

    private val _pending = MutableStateFlow<PendingCompletion?>(null)
    val pendingCompletion: StateFlow<PendingCompletion?> = _pending.asStateFlow()

    private val _override = MutableStateFlow<StartOverride?>(null)
    val startOverride: StateFlow<StartOverride?> = _override.asStateFlow()

    private val _lastBlock = MutableStateFlow<LastBlock?>(null)
    val lastBlock: StateFlow<LastBlock?> = _lastBlock.asStateFlow()

    private var expiryPromptedBlockId: String? = null

    val state: StateFlow<FocusUiState> = container.withSession { session ->
        val repo = session.repository
        val active = repo.observeActiveFocusSession()
        val context = contextState.map { it.context }.distinctUntilChanged()
        val snapshot: Flow<WorkspaceNextUpSnapshot> =
            combine(context, active.map { it?.activeTaskId }.distinctUntilChanged()) { c, running -> c to running }
                .flatMapLatest { (c, running) ->
                    minuteTicks().flatMapLatest { repo.observeNextUpSnapshot(session.workspace.id, c, running) }
                }
        val queue = active.map { it?.id }.distinctUntilChanged().flatMapLatest { id ->
            if (id == null) flowOf(emptyList()) else repo.observeFocusQueue(id)
        }
        val title = active.map { it?.activeTaskId }.distinctUntilChanged().flatMapLatest { id ->
            if (id == null) flowOf(null) else repo.observeTask(id).map { it?.title }
        }
        val points = dayTicks().flatMapLatest { repo.observeFocusPointsSummary() }
        combine(snapshot, active, queue, title, points) { next, focus, queued, activeTitle, summary ->
            FocusUiState(
                // The running task is the block, not a rung to choose again.
                ladder = next.ranking.ranked.filter { it.id != focus?.activeTaskId }.toImmutableList(),
                blocked = next.ranking.blocked.toImmutableList(),
                conditions = next.conditions.toImmutableList(),
                hasManualOrder = next.hasManualFocusOrder,
                session = focus,
                activeTitle = activeTitle,
                queue = queued.filter { it.item.state == FocusQueueState.QUEUED && it.task.id != focus?.activeTaskId }.toImmutableList(),
                points = summary,
                isLoaded = true,
            )
        }
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FocusUiState())

    init {
        StaleFocus.resolveOnce(container)
    }

    // region Context

    fun toggleCondition(condition: TaskCondition) {
        val current = contextState.value.selected
        val next = if (condition.id in current) {
            current - condition.id
        } else {
            // One place at a time: choosing a location replaces the last one.
            val places = if (condition.isLocation) state.value.conditions.filter { it.isLocation }.map { it.id }.toSet() else emptySet()
            current - places + condition.id
        }
        viewModelScope.launch { settings.putStringSet(CONDITIONS_KEY, next) }
    }

    fun setMode(mode: FocusTimeMode) {
        viewModelScope.launch { settings.putString(MODE_KEY, mode.raw) }
    }

    fun setAvailable(available: AvailableTime, now: Instant = Instant.now()) {
        time.value = available to FocusText.endsAt(available, now)
    }

    fun createCondition(name: String, isLocation: Boolean) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        container.undo.perform { repo -> repo.createCondition(container.awaitSession().workspace.id, trimmed, isLocation) }
    }

    // endregion

    // region The ladder

    /**
     * With a block running, staging a task queues it behind the block;
     * otherwise it becomes the task about to begin, its length seeded from
     * what it knows about itself.
     */
    fun stage(rung: ScoredNextUp) = stage(rung.id, rung.candidate.title)

    fun stage(taskId: String, title: String) {
        val session = state.value.session
        if (session != null && session.phase == FocusSessionPhase.RUNNING && session.activeTaskId != null) {
            container.undo.perform(announce = false) { repo ->
                repo.addToFocusQueue(session.id, taskId)
                container.undo.say("Queued $title after the running block")
            }
            return
        }
        _staged.value = taskId
        val candidate = state.value.ladder.firstOrNull { it.id == taskId }?.candidate
            ?: state.value.blocked.firstOrNull { it.id == taskId }?.candidate
        val seconds = candidate?.let { TaskAvailabilityPolicy.suggestedSeconds(it, contextState.value.context, Instant.now()) } ?: (25 * 60)
        _stagedMinutes.value = maxOf(1, Math.round(seconds / 60.0).toInt())
    }

    fun unstage() {
        _staged.value = null
    }

    fun setStagedMinutes(minutes: Int) {
        _stagedMinutes.value = minutes.coerceIn(1, 480)
    }

    /** Begins the staged task; a start the context rules out is held for confirmation. */
    fun beginStaged(override: Boolean = false) {
        val taskId = _staged.value ?: return
        begin(taskId, _stagedMinutes.value * 60, override)
    }

    fun begin(taskId: String, requestedSeconds: Int, override: Boolean = false) {
        val context = contextState.value.context
        viewModelScope.launch {
            val repo = container.repository()
            val now = Instant.now()
            val candidate = runCatching { repo.nextUpCandidates(now) }.getOrDefault(emptyList()).firstOrNull { it.id == taskId }
            val planned = if (candidate != null && !override) {
                TaskAvailabilityPolicy.plannedSeconds(candidate, requestedSeconds, context, now)
            } else {
                requestedSeconds
            }
            val title = candidate?.title ?: repo.task(taskId)?.title ?: "This task"
            val objections = FocusText.startObjections(candidate, context, planned, now, state.value.conditions)
            if (!override && objections.isNotEmpty()) {
                _override.value = StartOverride(taskId, title, planned, objections.joinToString("\n"))
                return@launch
            }
            _override.value = null
            val started = container.undo.performNow(announce = false) { store ->
                try {
                    store.startFocusSession(taskId, plannedSeconds = planned, context = context, overrideAvailability = override, now = now)
                    container.undo.say("Focus started on $title")
                } catch (refused: TaskPlanningException) {
                    if (refused.error != TaskPlanningError.UNAVAILABLE) throw refused
                    _override.value = StartOverride(taskId, title, planned, refused.error.message)
                }
            }
            if (started && _override.value == null) {
                _staged.value = null
                _lastBlock.value = null
            }
        }
    }

    fun confirmOverride() {
        val pending = _override.value ?: return
        _override.value = null
        begin(pending.taskId, pending.plannedSeconds, override = true)
    }

    fun dismissOverride() {
        _override.value = null
    }

    fun deferTask(taskId: String, deferral: FocusDeferral) = deferTo(taskId, deferral.date(Instant.now()), deferral.title.lowercase())

    fun deferTo(taskId: String, at: Instant, label: String) {
        if (_staged.value == taskId) _staged.value = null
        container.undo.perform(message = "Deferred to $label") { it.scheduleTask(taskId, at) }
    }

    /** Moves a rung by hand: only the task that moved is pinned, so a nudge stays a nudge. */
    fun moveRung(taskId: String, offset: Int) {
        val ladder = state.value.ladder
        val index = ladder.indexOfFirst { it.id == taskId }
        val target = index + offset
        if (index < 0 || target !in ladder.indices) return
        container.undo.perform { it.pinTask(taskId, target) }
    }

    fun unpin(taskId: String) = container.undo.perform { it.unpinTask(taskId) }

    /** Gives the ladder back to the ranking. */
    fun resetOrder() = container.undo.perform { it.clearFocusOrder() }

    /** Ticks a task off without a block: a daily logs today's contribution, anything else completes. */
    fun completeWithoutSession(rung: ScoredNextUp) {
        if (_staged.value == rung.id) _staged.value = null
        if (rung.candidate.isDailyDueToday) {
            container.undo.perform { repo ->
                val daily = repo.daily(rung.id) ?: return@perform
                repo.logContribution(daily.id)
            }
        } else {
            container.commands.complete(rung.id)
        }
    }

    fun inspect(taskId: String) = container.inspector.open(taskId)

    // endregion

    // region The running block

    fun togglePause() {
        state.value.session?.let(actions::togglePause)
    }

    fun requestCompletion(completeTask: Boolean, now: Instant = Instant.now()) {
        if (_pending.value != null) return
        val current = state.value
        val session = current.session ?: return
        _pending.value = actions.requestCompletion(session, current.activeTitle ?: "Focus block", completeTask, now)
    }

    fun confirmCompletion(multiplier: Double?) {
        val pending = _pending.value ?: return
        _pending.value = null
        actions.confirm(pending, multiplier, contextState.value.context) { completion ->
            _lastBlock.value = LastBlock(completion.award, completion.outcome)
        }
    }

    fun cancelCompletion() {
        val pending = _pending.value ?: return
        _pending.value = null
        actions.cancel(pending)
    }

    fun endSession() {
        _pending.value = null
        state.value.session?.let { actions.endSession(it, contextState.value.context) }
    }

    fun dismissLastBlock() {
        _lastBlock.value = null
    }

    /** Each second of a running block: once the planned time is up, ask how it went (once per block). */
    fun tick(now: Instant) {
        val session = state.value.session ?: return
        if (!session.isTicking || _pending.value != null) return
        if (session.elapsedSeconds(now) >= session.workDurationSeconds && expiryPromptedBlockId != session.activeBlockId) {
            expiryPromptedBlockId = session.activeBlockId
            requestCompletion(completeTask = false, now = now)
        }
    }

    // endregion
}
