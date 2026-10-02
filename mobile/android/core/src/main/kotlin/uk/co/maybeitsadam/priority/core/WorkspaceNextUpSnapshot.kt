package uk.co.maybeitsadam.priority.core

/**
 * Everything the day and the focus ladder are drawn from, gathered in one read.
 * Port of the value half of `WorkspaceNextUpSnapshot.swift`; the store builds it
 * (see `nextUpSnapshot` in the data layer) from `DayPlanSelector.plan` over every
 * candidate and `NextUpSelector.evaluate`.
 */
data class WorkspaceNextUpSnapshot(
    val loggedSeconds: Map<String, Int>,
    val planning: Map<String, TaskPlanning>,
    val conditions: List<TaskCondition>,
    val todayPlan: List<DayPlanEntry>,
    val workProgress: WorkProgress,
    val ranking: FocusRanking,
    /** Every planned task and the head of the ladder, so drawing the day needs no further read. */
    val dayTasks: Map<String, WorkspaceTask>,
    /** Whether the ladder carries hand-placed positions. */
    val hasManualFocusOrder: Boolean,
) {
    companion object {
        /** How many ranked tasks the day shows when nothing was planned for it. */
        const val fallbackDayLength = 8

        /** The ids whose rows `dayTasks` must hold: the plan, then the ladder's head. */
        fun dayTaskIDs(plan: List<DayPlanEntry>, ranking: FocusRanking): List<String> =
            plan.map { it.id } + ranking.ranked.take(fallbackDayLength).map { it.candidate.id }
    }
}
