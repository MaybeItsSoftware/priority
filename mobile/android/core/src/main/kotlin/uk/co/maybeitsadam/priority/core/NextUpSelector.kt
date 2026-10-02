package uk.co.maybeitsadam.priority.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

enum class NextUpReason(val raw: String, val explanation: String) {
    DAILY("daily", "today's contribution is still outstanding"),
    OVERDUE("overdue", "it is past its due date"),
    DUE_TODAY("dueToday", "it is due today"),
    DUE_SOON("dueSoon", "it is due shortly"),
    TODAY("today", "you put it in Today"),
    IMPORTANCE("importance", "it is important on the matrix"),
    PRIORITY("priority", "it carries a high priority"),
    ORDER("order", "it is next in order"),
    CONDITION("condition", "its required conditions are available now"),
    STARTED("started", "its start time has arrived"),
    DEADLINE_RISK("deadlineRisk", "its remaining work puts the deadline at risk");

    companion object {
        fun of(raw: String): NextUpReason? = entries.firstOrNull { it.raw == raw }
    }
}

enum class FocusTimeMode(val raw: String) {
    PROGRESS("progress"),
    FINISH("finish");

    companion object {
        fun of(raw: String): FocusTimeMode? = entries.firstOrNull { it.raw == raw }
    }
}

data class FocusContext(
    val conditionIDs: Set<String> = emptySet(),
    val endsAt: Instant? = null,
    val mode: FocusTimeMode = FocusTimeMode.PROGRESS,
)

/** Swift's `Date.distantPast` (0001-01-01T00:00:00Z). */
val DISTANT_PAST: Instant = Instant.parse("0001-01-01T00:00:00Z")

data class NextUpCandidate(
    val id: String,
    val title: String,
    val isDailyDueToday: Boolean = false,
    val dueAt: Instant? = null,
    val startAt: Instant? = null,
    val matrixUrgency: Int? = null,
    val matrixImportance: Int? = null,
    val priority: Int? = null,
    val estimateSeconds: Int? = null,
    val kanbanColumn: String? = null,
    val focusRank: Int? = null,
    val sortOrder: Int = 0,
    val createdAt: Instant = DISTANT_PAST,
    val dueDate: String? = null,
    val requirementGroups: List<List<String>> = emptyList(),
    val loggedSeconds: Int = 0,
    val minimumBlockSeconds: Int? = null,
    val requiresSingleSitting: Boolean = false,
    val dailyRemainingSeconds: Int? = null,
    val dailyUnavailable: TaskUnavailableReason? = null,
) {
    val remainingSeconds: Int?
        get() {
            dailyRemainingSeconds?.let { return maxOf(0, it) }
            return estimateSeconds?.let { maxOf(0, it - maxOf(0, loggedSeconds)) }
        }

    fun effectiveDeadline(zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val due = dueDate
        if (due != null) {
            TaskCalendarDate.date(due, zone)?.let { return it.atZone(zone).plusDays(1).toInstant() }
        }
        return dueAt
    }
}

/** Calendar dates stay dates across daylight-saving and time zone changes. */
object TaskCalendarDate {
    fun string(date: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
        val d = date.atZone(zone).toLocalDate()
        return "%04d-%02d-%02d".format(d.year, d.monthValue, d.dayOfMonth)
    }

    /** The start of the named day, or null if it does not round-trip (e.g. `2026-02-31`). */
    fun date(value: String, zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val pieces = value.split("-").mapNotNull { it.toIntOrNull() }
        if (pieces.size != 3) return null
        val date = try {
            LocalDate.of(pieces[0], 1, 1).plusMonths((pieces[1] - 1).toLong()).plusDays((pieces[2] - 1).toLong())
        } catch (_: Exception) {
            return null
        }
        val instant = date.atStartOfDay(zone).toInstant()
        return if (string(instant, zone) == value) instant else null
    }
}

sealed interface TaskUnavailableReason {
    data class StartsLater(val at: Instant) : TaskUnavailableReason
    data class MissingConditions(val groups: List<List<String>>) : TaskUnavailableReason
    data class InsufficientTime(val seconds: Int) : TaskUnavailableReason
    data object NeedsEstimate : TaskUnavailableReason
    data object ExpiredWindow : TaskUnavailableReason
    data object DailyNotScheduled : TaskUnavailableReason
    data object DailyAlreadyMet : TaskUnavailableReason
}

data class BlockedFocusTask(val candidate: NextUpCandidate, val reasons: List<TaskUnavailableReason>) {
    val id: String get() = candidate.id
}

data class FocusRanking(
    val ranked: List<ScoredNextUp>,
    val blocked: List<BlockedFocusTask>,
    val nextEvaluationAt: Instant?,
)

object TaskAvailabilityPolicy {
    fun reasons(task: NextUpCandidate, context: FocusContext, now: Instant): List<TaskUnavailableReason> {
        val result = mutableListOf<TaskUnavailableReason>()
        task.dailyUnavailable?.let { result += it }
        task.startAt?.let { if (it > now) result += TaskUnavailableReason.StartsLater(it) }
        val missing = task.requirementGroups.filter { group -> group.none { it in context.conditionIDs } }
        if (missing.isNotEmpty()) result += TaskUnavailableReason.MissingConditions(missing)
        val window = context.endsAt?.let { maxOf(0.0, secondsBetween(now, it)) }
        if (window != null && window < 60) result += TaskUnavailableReason.ExpiredWindow
        if (task.requiresSingleSitting || context.mode == FocusTimeMode.FINISH) {
            val remaining = task.remainingSeconds
            if (remaining == null || remaining <= 0) {
                result += TaskUnavailableReason.NeedsEstimate
                return result
            }
            val needed = maxOf(60, remaining, task.minimumBlockSeconds ?: 60)
            if (window != null && needed.toDouble() > window) result += TaskUnavailableReason.InsufficientTime(needed)
        } else if (window != null && maxOf(60, task.minimumBlockSeconds ?: 60).toDouble() > window) {
            result += TaskUnavailableReason.InsufficientTime(maxOf(60, task.minimumBlockSeconds ?: 60))
        }
        return result
    }

    fun plannedSeconds(task: NextUpCandidate, requested: Int?, context: FocusContext, now: Instant): Int {
        val needed = if (task.requiresSingleSitting) (task.remainingSeconds ?: 60) else 60
        val seconds = maxOf(
            maxOf(60, needed),
            maxOf(task.minimumBlockSeconds ?: 60, requested ?: suggestedSeconds(task, context, now)),
        )
        return context.endsAt?.let { minOf(seconds, maxOf(0, secondsBetween(now, it).toInt())) } ?: seconds
    }

    fun suggestedSeconds(task: NextUpCandidate, context: FocusContext, now: Instant): Int {
        val remaining = task.remainingSeconds?.takeIf { it > 0 }
        val suggested = maxOf(60, task.minimumBlockSeconds ?: 60, remaining ?: (25 * 60))
        val end = context.endsAt
        if (end == null || task.requiresSingleSitting) return suggested
        return minOf(suggested, maxOf(0, secondsBetween(now, end).toInt()))
    }
}

data class ScoredNextUp(
    val candidate: NextUpCandidate,
    val score: Double,
    val reason: NextUpReason,
    val explanation: String = reason.explanation,
) {
    val id: String get() = candidate.id

    companion object {
        fun of(candidate: NextUpCandidate, score: Double, reason: NextUpReason, explanation: String?) =
            ScoredNextUp(candidate, score, reason, explanation ?: reason.explanation)
    }
}

/**
 * Availability is evaluated before a deterministic precedence tuple. Numeric
 * scores are retained for compatibility; they never override deadline ordering.
 * Port of `NextUpSelector.swift`.
 */
object NextUpSelector {
    const val todayColumnID = "today"
    const val dueHorizonDays = 14
    const val minimumDeadlineBuffer: Double = 300.0
    const val deadlineBufferFraction: Double = 0.2

    fun next(candidates: List<NextUpCandidate>, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): ScoredNextUp? =
        rank(candidates, now, zone).firstOrNull()

    fun rank(
        candidates: List<NextUpCandidate>,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        context: FocusContext = FocusContext(),
    ): List<ScoredNextUp> = evaluate(candidates, now, zone, context).ranked

    fun evaluate(
        candidates: List<NextUpCandidate>,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
        context: FocusContext = FocusContext(),
    ): FocusRanking {
        val available = mutableListOf<NextUpCandidate>()
        val blocked = mutableListOf<BlockedFocusTask>()
        for (task in candidates) {
            val reasons = TaskAvailabilityPolicy.reasons(task, context, now)
            if (reasons.isEmpty()) available += task else blocked += BlockedFocusTask(task, reasons)
        }
        val order = Comparator<NextUpCandidate> { a, b ->
            when {
                precedes(a, b, now, zone) -> -1
                precedes(b, a, now, zone) -> 1
                else -> 0
            }
        }
        val sorted = available.sortedWith(order)
        val ranked = mutableListOf<NextUpCandidate>()
        var index = 0
        while (index < sorted.size) {
            val key = primary(sorted[index], now, zone)
            var end = index + 1
            while (end < sorted.size && primary(sorted[end], now, zone) == key) end++
            ranked += place(sorted.subList(index, end))
            index = end
        }
        val nextDay = now.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant()
        val boundaries = mutableListOf<Instant>()
        for (task in candidates) {
            listOfNotNull(task.startAt, task.effectiveDeadline(zone)).forEach { boundaries += it }
            if (task.dueDate == null) task.dueAt?.let { boundaries += it.plusMillis(1) }
            val deadline = task.effectiveDeadline(zone)
            val work = task.remainingSeconds
            if (deadline != null && work != null && work > 0) {
                boundaries += deadline.minusSeconds(work.toDouble() + buffer(work))
            }
            context.endsAt?.let { end ->
                boundaries += end.minusSeconds(maxOf(60, task.minimumBlockSeconds ?: 60).toDouble()).plusMillis(1)
                if (work != null && (context.mode == FocusTimeMode.FINISH || task.requiresSingleSitting)) {
                    boundaries += end.minusSeconds(maxOf(60, work, task.minimumBlockSeconds ?: 60).toDouble()).plusMillis(1)
                }
            }
        }
        context.endsAt?.let { boundaries += it }
        boundaries += nextDay
        return FocusRanking(
            ranked = ranked.map { score(it, now, zone) },
            blocked = blocked.sortedWith { a, b -> order.compare(a.candidate, b.candidate) },
            nextEvaluationAt = boundaries.filter { it > now }.minOrNull(),
        )
    }

    private fun buffer(seconds: Int): Double = maxOf(minimumDeadlineBuffer, seconds * deadlineBufferFraction)

    private fun primary(task: NextUpCandidate, now: Instant, zone: ZoneId): List<Double> {
        val due = task.effectiveDeadline(zone) ?: return listOf(3.0, 0.0)
        val late = if (task.dueDate == null) due < now else due <= now
        if (late) return listOf(0.0, epochSeconds(due))
        val isToday = task.dueDate?.let { it == TaskCalendarDate.string(now, zone) }
            ?: (due.atZone(zone).toLocalDate() == now.atZone(zone).toLocalDate())
        if (isToday) return listOf(1.0, epochSeconds(due), epochSeconds(task.createdAt))
        val work = task.remainingSeconds
        if (work != null && work > 0) {
            val slack = secondsBetween(now, due) - work - buffer(work)
            if (slack <= 0) return listOf(2.0, slack)
        }
        return listOf(3.0, 0.0)
    }

    private fun precedes(left: NextUpCandidate, right: NextUpCandidate, now: Instant, zone: ZoneId): Boolean {
        val lhs = primary(left, now, zone)
        val rhs = primary(right, now, zone)
        if (lhs != rhs) return lexicographicallyPrecedes(lhs, rhs)
        fun secondary(task: NextUpCandidate): List<Double> {
            val commitment = task.isDailyDueToday || task.kanbanColumn == todayColumnID
            val due = task.effectiveDeadline(zone)
            val days = due?.let { maxOf(0.0, secondsBetween(now, it) / 86_400) } ?: Double.POSITIVE_INFINITY
            return listOf(
                if (task.requirementGroups.isEmpty()) 1.0 else 0.0,
                if (task.startAt == null) 1.0 else 0.0,
                if (commitment) 0.0 else 1.0,
                -(task.matrixImportance ?: 0).toDouble(),
                -(task.priority ?: 0).toDouble(),
                if (days <= dueHorizonDays) days else Double.POSITIVE_INFINITY,
                -(task.matrixUrgency ?: 0).toDouble(),
                epochSeconds(task.createdAt),
                (task.remainingSeconds ?: Int.MAX_VALUE).toDouble(),
                task.sortOrder.toDouble(),
            )
        }
        val a = secondary(left)
        val b = secondary(right)
        return if (a == b) left.id < right.id else lexicographicallyPrecedes(a, b)
    }

    private fun place(tasks: List<NextUpCandidate>): List<NextUpCandidate> {
        val pinned = tasks.filter { it.focusRank != null }
            .sortedWith(compareBy<NextUpCandidate> { it.focusRank ?: 0 }.thenBy { it.id })
        val free = tasks.filter { it.focusRank == null }
        val result = mutableListOf<NextUpCandidate>()
        var pin = 0
        var unpinned = 0
        while (result.size < tasks.size) {
            if (pin < pinned.size && ((pinned[pin].focusRank ?: 0) <= result.size || unpinned == free.size)) {
                result += pinned[pin]; pin++
            } else {
                result += free[unpinned]; unpinned++
            }
        }
        return result
    }

    fun score(task: NextUpCandidate, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): ScoredNextUp {
        val key = primary(task, now, zone)
        var explanation: String? = null
        val reason: NextUpReason = when (key[0]) {
            0.0 -> {
                val days = maxOf(0, (secondsBetween(task.effectiveDeadline(zone) ?: now, now) / 86_400).toInt())
                explanation = if (days > 0) "overdue by $days days" else "past its deadline"
                NextUpReason.OVERDUE
            }
            1.0 -> {
                val age = (maxOf(0.0, secondsBetween(task.createdAt, now)) / 86_400).toInt()
                if (age >= 30) explanation = "due today; added $age days ago"
                NextUpReason.DUE_TODAY
            }
            2.0 -> NextUpReason.DEADLINE_RISK
            else -> {
                val due = task.effectiveDeadline(zone)
                when {
                    task.requirementGroups.isNotEmpty() -> NextUpReason.CONDITION
                    task.startAt != null -> NextUpReason.STARTED
                    task.isDailyDueToday -> NextUpReason.DAILY
                    task.kanbanColumn == todayColumnID -> NextUpReason.TODAY
                    (task.matrixImportance ?: 0) > 0 || (task.matrixUrgency ?: 0) > 0 -> NextUpReason.IMPORTANCE
                    (task.priority ?: 0) > 0 -> NextUpReason.PRIORITY
                    due != null && secondsBetween(now, due) <= dueHorizonDays * 86_400.0 -> NextUpReason.DUE_SOON
                    else -> NextUpReason.ORDER
                }
            }
        }
        return ScoredNextUp.of(task, (4 - key[0]) * 1000, reason, explanation)
    }

    private fun epochSeconds(instant: Instant): Double = instant.epochSecond + instant.nano / 1_000_000_000.0

    private fun lexicographicallyPrecedes(a: List<Double>, b: List<Double>): Boolean {
        for (i in 0 until minOf(a.size, b.size)) {
            if (a[i] < b[i]) return true
            if (a[i] > b[i]) return false
        }
        return a.size < b.size
    }
}

/** `Instant.minusSeconds` for fractional seconds, at nanosecond precision. */
internal fun Instant.minusSeconds(seconds: Double): Instant = minusNanos(Math.round(seconds * 1_000_000_000))
