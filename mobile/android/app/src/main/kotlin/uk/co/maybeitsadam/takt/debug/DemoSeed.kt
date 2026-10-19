package uk.co.maybeitsadam.takt.debug

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository

/**
 * A small, believable workspace for screenshots and poking around: the
 * iPhone's `seedDemo` (`WorkspaceModel+Seed.swift`), plus enough on the Work
 * list to spread a board. Debug builds only — [MainActivity] reaches it
 * behind `BuildConfig.DEBUG`, so R8 drops it from a release build — from
 * `adb shell am start -n uk.co.maybeitssoftware.takt/uk.co.maybeitsadam.takt.MainActivity --ez demo true`.
 */
object DemoSeed {
    const val EXTRA_DEMO = "demo"

    /**
     * Seeds the workspace unless it already has a list besides the Inbox,
     * so a second launch with the extra never doubles it. Returns whether it seeded.
     */
    suspend fun seedIfEmpty(
        repository: WorkspaceRepository,
        workspaceId: String,
        zone: ZoneId = ZoneId.systemDefault(),
        today: LocalDate = LocalDate.now(zone),
    ): Boolean {
        val inboxId = repository.inbox(workspaceId)?.id
        if (repository.lists(workspaceId).any { it.id != inboxId }) return false
        seed(repository, workspaceId, inboxId) { offset, hour ->
            today.plusDays(offset.toLong()).atTime(hour ?: 0, 0).atZone(zone).toInstant()
        }
        return true
    }

    private suspend fun seed(
        store: WorkspaceRepository,
        workspaceId: String,
        inboxId: String?,
        day: (offset: Int, hour: Int?) -> Instant,
    ) {
        fun day(offset: Int) = day(offset, null)
        val folder = store.createFolder(workspaceId, "Personal")
        val work = store.createList(workspaceId, "Work")
        val home = store.createList(workspaceId, "Home", folderId = folder.id)
        val reading = store.createList(workspaceId, "Reading", folderId = folder.id)
        store.updateList(work.id, "Work", "#007fff")
        store.updateList(home.id, "Home", "#4cc38e")

        // Named arguments throughout: the capturing overload takes two strings first too.
        val launch = store.createTask(
            listId = work.id, title = "Ship the iOS app", estimateSeconds = 7_200, priority = 1,
            kanbanColumn = "in-progress",
        )
        val design = store.createTask(
            listId = work.id, title = "Polish the outline rows", parentTaskId = launch.id, dueAt = day(0),
            estimateSeconds = 2_700,
        )
        store.createTask(listId = work.id, title = "Hairline separators", parentTaskId = design.id)
        store.createTask(listId = work.id, title = "Fold chevrons", parentTaskId = design.id)
        val readme = store.createTask(
            listId = work.id, title = "Write the README", parentTaskId = launch.id, estimateSeconds = 1_800,
        )
        val screenshots = store.createTask(
            listId = work.id, title = "Take screenshots", parentTaskId = launch.id, dueAt = day(1),
            estimateSeconds = 1_200,
        )
        store.createTask(
            listId = work.id, title = "Submit for review", parentTaskId = launch.id, dueAt = day(3),
            estimateSeconds = 900,
        )
        store.createTask(
            listId = work.id, title = "Review sync protocol", dueAt = day(-1), estimateSeconds = 3_600,
            tags = listOf("sync"), kanbanColumn = "in-progress",
        )
        store.createTask(
            listId = work.id, title = "Reply to Sam about the roadmap", estimateSeconds = 900,
            kanbanColumn = "in-progress",
        )
        val quarterly = store.createTask(listId = work.id, title = "Quarterly planning", kind = WorkspaceItemKind.LIST)
        store.createTask(listId = work.id, title = "Draft goals", parentTaskId = quarterly.id)
        // Enough besides to spread the Work board over its columns.
        store.createTask(
            listId = work.id, title = "Update the privacy policy", estimateSeconds = 1_800, kanbanColumn = "this-week",
        )
        store.createTask(
            listId = work.id, title = "Try a denser calendar week", tags = listOf("idea"), kanbanColumn = "backlog",
        )
        val widget = store.createTask(
            listId = work.id, title = "Fix the widget refresh", estimateSeconds = 2_700, priority = 2,
            kanbanColumn = "in-progress",
        )
        store.createTask(
            listId = work.id, title = "Tidy the settings screen", estimateSeconds = 1_800, tags = listOf("design"),
            kanbanColumn = "in-progress",
        )
        store.createTask(
            listId = work.id, title = "Move the sync server to the new region", dueAt = day(2),
            estimateSeconds = 5_400, kanbanColumn = "in-progress",
        )
        store.createTask(listId = work.id, title = "Invoice for October", waitingOn = "Accounts", estimateSeconds = 600)
        store.createTask(
            listId = work.id, title = "Prepare the client demo", dueAt = day(4), estimateSeconds = 3_600,
            kanbanColumn = "this-week",
        )

        store.createTask(listId = home.id, title = "Book the boiler service", dueAt = day(2, 10))
        val groceries = store.createTask(listId = home.id, title = "Groceries", estimateSeconds = 2_400)
        store.createTask(listId = home.id, title = "Oat milk", parentTaskId = groceries.id)
        store.createTask(listId = home.id, title = "Coffee beans", parentTaskId = groceries.id)
        store.createTask(listId = home.id, title = "Water the plants", startAt = day(0))
        val book = store.createTask(
            listId = reading.id, title = "Read ‘A Pattern Language’", estimateSeconds = 3_600,
        )
        if (inboxId != null) {
            store.createTask(listId = inboxId, title = "Call the dentist", estimateSeconds = 600)
            store.createTask(listId = inboxId, title = "Idea: weekly review template")
        }
        store.setPlannedForToday(true, listOf(screenshots.id, groceries.id, readme.id, widget.id))
        store.makeDaily(design.id, targetSeconds = 1_800)
        store.makeDaily(book.id, targetSeconds = 1_200)
        store.setMatrixPosition(TaskMatrixPosition(urgency = 1, importance = 1), launch.id)
    }
}
