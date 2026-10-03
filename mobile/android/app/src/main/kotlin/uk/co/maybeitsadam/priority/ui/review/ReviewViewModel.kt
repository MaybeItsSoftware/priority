package uk.co.maybeitsadam.priority.ui.review

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.FocusPointsSummary
import uk.co.maybeitsadam.priority.core.TaskProgressPeriod
import uk.co.maybeitsadam.priority.core.TaskProgressSeries
import uk.co.maybeitsadam.priority.data.workspace.observeCompletedTasks
import uk.co.maybeitsadam.priority.data.workspace.observeReviewDay
import uk.co.maybeitsadam.priority.data.workspace.observeReviewProgress

/** Review: the day's focus on a ruler, the finished work, and the trend. */
class ReviewViewModel(private val container: AppContainer) : ViewModel() {
    private val zone: ZoneId get() = ZoneId.systemDefault()

    private val _section = MutableStateFlow(ReviewSection.TIMELINE)
    val section: StateFlow<ReviewSection> = _section

    private val _day = MutableStateFlow(LocalDate.now())
    val day: StateFlow<LocalDate> = _day

    private val _period = MutableStateFlow(TaskProgressPeriod.WEEK)
    val period: StateFlow<TaskProgressPeriod> = _period

    init {
        viewModelScope.launch {
            container.settings.string(PERIOD_KEY).collect { raw ->
                raw?.let(TaskProgressPeriod::of)?.let { _period.value = it }
            }
        }
    }

    fun select(section: ReviewSection) {
        _section.value = section
    }

    /** Never past today: the future holds no logged work. */
    fun moveDay(by: Long) {
        val next = _day.value.plusDays(by)
        _day.value = minOf(next, LocalDate.now(zone))
    }

    fun showDay(day: LocalDate) {
        _day.value = minOf(day, LocalDate.now(zone))
    }

    fun selectPeriod(period: TaskProgressPeriod) {
        _period.value = period
        viewModelScope.launch { container.settings.putString(PERIOD_KEY, period.raw) }
    }

    /** Ticks each minute while [day] is today, so a running block grows on the ruler. */
    private fun minuteTicks(day: LocalDate): Flow<Instant> = flow {
        while (true) {
            emit(Instant.now())
            if (day != LocalDate.now(zone)) break
            delay(60_000)
        }
    }

    val timeline: StateFlow<TimelineDay?> = _day.flatMapLatest { day ->
        val start = day.atStartOfDay(zone).toInstant()
        val end = day.plusDays(1).atStartOfDay(zone).toInstant()
        container.withSession { session -> session.repository.observeReviewDay(start, end) }
            .combine(minuteTicks(day)) { records, now ->
                val session = records.activeSession
                val live = session?.activeTaskId?.let { taskId ->
                    TimelineDay.Live(
                        id = session.activeBlockId ?: "live/${session.id}",
                        taskId = taskId,
                        title = records.activeTaskTitle ?: "Focus",
                        seconds = session.elapsedSeconds(now),
                    )
                }
                TimelineDay.build(
                    day = day,
                    blocks = records.blocks.map(TimelineDay::Input),
                    awards = records.awards,
                    live = live,
                    completions = records.closedTasks,
                    now = now,
                    zone = zone,
                )
            }
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val done: StateFlow<ImmutableList<DoneGroup>?> = container.withSession { session ->
        val since = Instant.now().minusSeconds(DONE_WINDOW_DAYS * 86_400L)
        session.repository.observeCompletedTasks(since)
            .combine(session.repository.observeLists(session.workspace.id, includingArchived = true)) { tasks, lists ->
                doneGroups(tasks, lists.associate { it.id to it.name }, Instant.now(), zone)
            }
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val progress: StateFlow<ProgressSummary> = _period.flatMapLatest { period ->
        val interval = TaskProgressSeries.interval(period, Instant.now(), zone)
        container.withSession { session -> session.repository.observeReviewProgress(interval.start, interval.end) }
            .map { records ->
                ProgressSummary.build(
                    period = period,
                    completions = records.completions,
                    creations = records.creations,
                    blocks = records.blocks.map { it.seconds to it.recordedAt },
                    now = Instant.now(),
                    zone = zone,
                )
            }
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ProgressSummary())

    val points: StateFlow<FocusPointsSummary> = container.withSession { it.repository.observeFocusPointsSummary() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FocusPointsSummary.ZERO)

    fun reopen(taskId: String) = container.commands.reopen(taskId)

    fun inspect(taskId: String) = container.inspector.open(taskId)

    companion object {
        const val DONE_WINDOW_DAYS = 35
        const val PERIOD_KEY = "reviewProgressPeriod"
    }
}
