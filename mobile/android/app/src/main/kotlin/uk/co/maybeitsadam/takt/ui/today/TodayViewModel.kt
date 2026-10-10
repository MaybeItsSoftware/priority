package uk.co.maybeitsadam.takt.ui.today

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.takt.ui.focus.FocusActions
import uk.co.maybeitsadam.takt.ui.focus.FocusDeferral
import uk.co.maybeitsadam.takt.ui.focus.PendingCompletion
import uk.co.maybeitsadam.takt.ui.focus.StaleFocus

/** Every minute, so the day's dates (overdue, starts today) move on with the clock. */
internal fun minuteTicks(): Flow<Unit> = flow {
    while (true) {
        emit(Unit)
        delay(60_000 - System.currentTimeMillis() % 60_000)
    }
}

/** The local date, re-emitted when it changes. */
internal fun dayTicks(zone: ZoneId = ZoneId.systemDefault()): Flow<LocalDate> =
    minuteTicks().map { LocalDate.now(zone) }.distinctUntilChanged()

/** Today: the plan, the running block, the dailies, and the forecast drawn from them. */
@OptIn(ExperimentalCoroutinesApi::class)
class TodayViewModel(private val container: AppContainer) : ViewModel() {
    private val focus = FocusActions(container)

    /** An order written but not yet read back, shown straight away so a drag does not snap back. */
    private val pendingOrder = MutableStateFlow<List<String>?>(null)

    private val _pending = MutableStateFlow<PendingCompletion?>(null)
    val pendingCompletion: StateFlow<PendingCompletion?> = _pending.asStateFlow()

    private val stored: Flow<DayState> = container.withSession { session ->
        val repo = session.repository
        val active = repo.observeActiveFocusSession()
        val snapshot = active.map { it?.activeTaskId }.distinctUntilChanged().flatMapLatest { runningId ->
            // The day needs only the ladder's head, as the iPhone's Today asks.
            minuteTicks().flatMapLatest {
                repo.observeNextUpSnapshot(
                    session.workspace.id, FocusContext(), runningId, ladderLimit = WorkspaceNextUpSnapshot.fallbackDayLength,
                )
            }
        }
        val dailies = dayTicks().flatMapLatest { repo.observeDailies(Instant.now()) }
        combine(snapshot, active, dailies, repo.observeLists(session.workspace.id)) { next, focusSession, daily, lists ->
            DayShaping.build(next, focusSession, daily, lists)
        }
    }.flowOn(Dispatchers.Default)

    val state: StateFlow<DayState> = combine(stored, pendingOrder) { day, order ->
        if (order == null || order == day.plannedIds) day else day.copy(cards = DayArrangement.applying(order, day.cards).toImmutableList())
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DayState())

    init {
        StaleFocus.resolveOnce(container)
    }

    // region Arranging

    /** Moves a planned card [offset] places through the planned part of the day. */
    fun movePlanned(taskId: String, offset: Int) {
        val order = DayArrangement.moving(taskId, offset, state.value.plannedIds) ?: return
        arrange(order)
    }

    /** Writes the planned order (a drag's result) as one undo step. */
    fun arrange(order: List<String>) {
        if (order == state.value.plannedIds) return
        pendingOrder.value = order
        viewModelScope.launch {
            container.undo.performNow { it.arrangeDay(order) }
            pendingOrder.value = null
        }
    }

    // endregion

    // region Ticking off

    /** A daily logs today's contribution and leaves the task open; anything else is completed. */
    fun tickOff(card: DayCard) {
        if (card.isRunning) {
            requestCompletion(completeTask = true)
            return
        }
        val dailyId = card.dailyId
        if (dailyId != null) {
            if (card.isDailyDoneToday) {
                container.undo.perform { it.clearContribution(dailyId) }
            } else {
                container.undo.perform { it.logContribution(dailyId) }
            }
        } else {
            container.commands.complete(card.id)
        }
    }

    fun toggleDaily(daily: DayDaily) {
        if (daily.isDone) {
            container.undo.perform { it.clearContribution(daily.id) }
        } else {
            container.undo.perform { it.logContribution(daily.id) }
        }
    }

    // endregion

    // region Plan and dates

    fun togglePlanned(card: DayCard) = container.commands.togglePlannedToday(card.id)

    fun dueToday(card: DayCard) = container.commands.dueToday(card.id)

    fun dueTomorrow(card: DayCard) = container.commands.dueTomorrow(card.id)

    /** Not today: off the plan, and the start pushed to tomorrow morning. */
    fun deferToTomorrow(card: DayCard) = container.undo.perform(message = "Moved ${card.title} to tomorrow") { repo ->
        if (card.isPlanned) repo.setPlannedForToday(false, listOf(card.id))
        repo.scheduleTask(card.id, FocusDeferral.TOMORROW.date(Instant.now()))
    }

    fun inspect(card: DayCard) = container.inspector.open(card.id)

    // endregion

    // region The running block

    /**
     * Play on a card. Unconditional, as on the Mac: pressing play answers
     * whether the task is available. With a block already running, the task
     * joins its queue instead.
     */
    fun start(card: DayCard) {
        if (card.isRunning) return
        val session = state.value.session
        if (session != null && session.phase == FocusSessionPhase.RUNNING && session.activeTaskId != null) {
            container.undo.perform(announce = false) { repo ->
                repo.addToFocusQueue(session.id, card.id)
                container.undo.say("Queued after the running task")
            }
            return
        }
        container.undo.perform(announce = false) { repo ->
            val now = Instant.now()
            val candidate = repo.nextUpCandidates(now).firstOrNull { it.id == card.id }
            val planned = candidate?.let { TaskAvailabilityPolicy.suggestedSeconds(it, FocusContext(), now) }
                ?: card.estimateSeconds ?: (25 * 60)
            repo.startFocusSession(card.id, plannedSeconds = planned, context = FocusContext(), overrideAvailability = true, now = now)
            container.undo.say("Focus started on ${card.title}")
        }
    }

    fun togglePause() {
        state.value.session?.let(focus::togglePause)
    }

    fun requestCompletion(completeTask: Boolean) {
        if (_pending.value != null) return
        val day = state.value
        val session = day.session ?: return
        val title = day.runningCard?.title ?: day.cards.firstOrNull { it.id == session.activeTaskId }?.title ?: "Focus block"
        _pending.value = focus.requestCompletion(session, title, completeTask)
    }

    fun confirmCompletion(multiplier: Double) {
        val pending = _pending.value ?: return
        _pending.value = null
        focus.confirm(pending, multiplier)
    }

    fun cancelCompletion() {
        val pending = _pending.value ?: return
        _pending.value = null
        focus.cancel(pending)
    }

    // endregion
}
