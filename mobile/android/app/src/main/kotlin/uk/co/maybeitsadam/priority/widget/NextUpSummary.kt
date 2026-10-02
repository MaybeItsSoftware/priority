package uk.co.maybeitsadam.priority.widget

import uk.co.maybeitsadam.priority.core.DayPlanReason
import uk.co.maybeitsadam.priority.core.WorkspaceNextUpSnapshot

/** What the Next up widget shows, reduced from the day's snapshot so it can be compared and tested. */
data class NextUpSummary(
    val taskId: String?,
    val title: String?,
    /** Why it is next: the plan's reason, or the ranking's explanation. */
    val reason: String?,
    /** The open items making up today. */
    val todayCount: Int,
    val isRunning: Boolean,
) {
    companion object {
        val EMPTY = NextUpSummary(null, null, null, 0, false)

        /**
         * The running task first; otherwise the head of the day's plan; with
         * nothing planned, the head of the ranked ladder.
         */
        fun of(snapshot: WorkspaceNextUpSnapshot, runningId: String?): NextUpSummary {
            val todayCount = snapshot.todayPlan.size
            val running = runningId?.let { snapshot.dayTasks[it] }
            if (running != null) {
                return NextUpSummary(running.id, running.title, DayPlanReason.RUNNING.label, todayCount, isRunning = true)
            }
            snapshot.todayPlan.firstNotNullOfOrNull { entry -> snapshot.dayTasks[entry.id]?.let { entry to it } }
                ?.let { (entry, task) ->
                    return NextUpSummary(task.id, task.title, entry.reason.label, todayCount, isRunning = false)
                }
            val head = snapshot.ranking.ranked.firstOrNull()
                ?: return EMPTY.copy(todayCount = todayCount)
            val title = snapshot.dayTasks[head.id]?.title ?: head.candidate.title
            return NextUpSummary(head.id, title, head.explanation.capitalisedFirst(), todayCount, isRunning = false)
        }
    }
}

internal fun String.capitalisedFirst(): String = if (isEmpty()) this else this[0].uppercaseChar() + substring(1)
