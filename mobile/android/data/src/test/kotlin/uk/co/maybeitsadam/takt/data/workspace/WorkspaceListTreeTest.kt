package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.DayPlanSelector
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceBoardTrees
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceSidebarIndex
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** Port of workspace-tests/WorkspaceListTreeTests.swift: the in-memory shapes against the store's own reads. */
class WorkspaceListTreeTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val list: TaskList, val other: TaskList) {
        val store get() = w.repository

        data class Seeded(val project: WorkspaceTask, val nested: WorkspaceTask, val archived: WorkspaceTask)

        suspend fun seed(): Seeded {
            val project = store.createTask(listId = list.id, title = "Project")
            store.createTask(listId = list.id, title = "Step one", parentTaskId = project.id)
            val done = store.createTask(listId = list.id, title = "Step two", parentTaskId = project.id)
            store.setStatus(TaskStatus.COMPLETED, done.id)
            val nested = store.createTask(listId = list.id, title = "Reading", kind = WorkspaceItemKind.LIST)
            val inner = store.createTask(listId = list.id, title = "Papers", parentTaskId = nested.id, kind = WorkspaceItemKind.LIST)
            store.createTask(listId = list.id, title = "Paper A", parentTaskId = inner.id)
            val archived = store.createTask(listId = list.id, title = "Old", kind = WorkspaceItemKind.LIST)
            store.createTask(listId = list.id, title = "Hidden", parentTaskId = archived.id)
            store.setNestedListArchived(true, archived.id)
            val closed = store.createTask(listId = list.id, title = "Closed", kind = WorkspaceItemKind.LIST)
            store.createTask(listId = list.id, title = "Inside closed", parentTaskId = closed.id)
            store.setStatus(TaskStatus.COMPLETED, closed.id)
            store.createTask(listId = other.id, title = "Groceries")
            return Seeded(project, nested, archived)
        }
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspaceId = store.bootstrapIfNeeded().id
            val list = store.createList(workspaceId = workspaceId, name = "Work")
            val other = store.createList(workspaceId = workspaceId, name = "Home")
            Fixture(w, workspaceId, list, other).test()
        }
    }

    @Test
    fun treeShapesMatchTheStoresOwnQueries() = fixture {
        val seeded = seed()
        val tree = store.listTree(list.id)
        for (parent in listOf(null, seeded.project.id, seeded.nested.id, seeded.archived.id)) {
            assertEquals(store.outline(list.id, parent), tree.outline(parent))
            assertEquals(store.visibleOutline(list.id, parent), tree.visibleOutline(parent))
            assertEquals(store.tasks(list.id, parent), tree.children(parent))
        }
        assertEquals(store.visibleRootParentTaskId(list), tree.visibleRootParentTaskID(list.visibleRootTaskId))
    }

    @Test
    fun actionableTasksMatchAcrossLists() = fixture {
        seed()
        val lists = store.lists(workspaceId)
        val trees = store.listTrees(lists.map { it.id })
        val shaped = lists.flatMap { trees[it.id]?.actionableTasks(it.visibleRootTaskId) ?: emptyList() }
        assertEquals(store.actionableTasks(workspaceId), shaped)
        assertFalse(shaped.any { it.title == "Hidden" || it.title == "Inside closed" || it.isList })
    }

    @Test
    fun visibleRootIsOnlyTheWrapperWhileItIsTheOnlyRoot() = fixture {
        val wrapper = store.createTask(listId = list.id, title = "Wrapper")
        val child = store.createTask(listId = list.id, title = "Child", parentTaskId = wrapper.id)
        val tree = store.listTree(list.id)
        assertEquals(wrapper.id, tree.visibleRootParentTaskID(wrapper.id))
        assertNull(tree.visibleRootParentTaskID(child.id))
        assertNull(tree.visibleRootParentTaskID(null))
        store.createTask(listId = list.id, title = "Second root")
        assertNull(store.listTree(list.id).visibleRootParentTaskID(wrapper.id))
    }

    @Test
    fun sidebarIndexCountsEveryTaskAndNestsListsByListDepth() = fixture {
        val seeded = seed()
        val lists = store.lists(workspaceId)
        val index = WorkspaceSidebarIndex.build(lists, store.listTrees(lists.map { it.id }))
        assertEquals(store.outline(list.id).size, index.taskCounts[list.id])
        assertEquals(1, index.taskCounts[other.id])
        assertEquals(listOf("Reading", "Papers", "Closed"), index.nestedLists.map { it.task.title })
        assertEquals(listOf(0, 1, 0), index.nestedLists.map { it.depth })
        assertEquals(listOf(seeded.archived.id), index.archivedNestedLists.map { it.id })
    }

    @Test
    fun boardTreesReachEveryLevelBeneathEveryCardAndInsideIt() = fixture {
        val project = store.createTask(listId = list.id, title = "Project")
        val step = store.createTask(listId = list.id, title = "Step", parentTaskId = project.id)
        val part = store.createTask(listId = list.id, title = "Part", parentTaskId = step.id)
        val detail = store.createTask(listId = list.id, title = "Detail", parentTaskId = part.id)
        store.setStatus(TaskStatus.COMPLETED, detail.id)
        val sibling = store.createTask(listId = list.id, title = "Sibling", parentTaskId = project.id)
        val archived = store.createTask(listId = list.id, title = "Old", parentTaskId = project.id, kind = WorkspaceItemKind.LIST)
        store.createTask(listId = list.id, title = "Hidden", parentTaskId = archived.id)
        store.setNestedListArchived(true, archived.id)
        val elsewhere = store.createTask(listId = list.id, title = "Elsewhere")
        val tree = store.listTree(list.id)

        val board = WorkspaceBoardTrees.build(setOf(project.id), listOf(tree))
        val beneath = board.descendants[project.id]!!
        assertEquals(listOf("Step", "Part", "Detail", "Sibling"), beneath.map { it.task.title })
        assertEquals(listOf(0, 1, 2, 0), beneath.map { it.depth })
        assertEquals(TaskStatus.COMPLETED, beneath[2].task.status)
        assertEquals(listOf("Part", "Detail"), board.descendants[step.id]?.map { it.task.title })
        assertEquals(listOf(0, 1), board.descendants[step.id]?.map { it.depth })
        assertEquals(emptyList<Any>(), board.descendants[detail.id])
        assertEquals(emptyList<Any>(), board.descendants[sibling.id])
        assertNull(board.descendants[elsewhere.id])
        assertEquals(part.id, board.parents[detail.id]?.id)
        assertNull(board.parents[project.id])

        val scoped = WorkspaceBoardTrees.build(setOf(step.id, sibling.id), listOf(tree))
        assertEquals(listOf(0, 1), scoped.descendants[step.id]?.map { it.depth })
        assertNull(scoped.descendants[project.id])
        assertEquals(setOf(step.id, part.id, detail.id, sibling.id), scoped.descendants.keys)
    }

    @Test
    fun tasksByIdReadsOnlyWhatExists() = fixture {
        val task = store.createTask(listId = list.id, title = "One")
        assertEquals(listOf(task.id), store.tasks(listOf(task.id, "missing", task.id)).keys.sorted())
        assertTrue(store.tasks(emptyList()).isEmpty())
    }

    @Test
    fun nextUpSnapshotAgreesWithTheIndividualReads() = fixture {
        val task = store.createTask(listId = list.id, title = "Write report")
        store.createTask(listId = other.id, title = "Groceries")
        val now = w.clock.instant
        val snapshot = store.nextUpSnapshot(workspaceId, FocusContext(), null, now = now)
        val candidates = store.nextUpCandidates(now = now)
        val ranking = NextUpSelector.evaluate(candidates, now = now, zone = UTC, context = FocusContext())

        assertEquals(ranking.ranked, snapshot.ranking.ranked)
        assertEquals(DayPlanSelector.plan(candidates, now = now, zone = UTC), snapshot.todayPlan)
        assertEquals(store.loggedWorkTotals(), snapshot.loggedSeconds)
        assertEquals(store.taskPlanningValues(), snapshot.planning)
        assertEquals(store.conditions(workspaceId), snapshot.conditions)
        val progress = store.workProgress(now = now)
        // WorkProgress is a class (it clamps in its initialiser), so it is compared by field.
        assertEquals(progress.today, snapshot.workProgress.today)
        assertEquals(progress.week, snapshot.workProgress.week)
        assertEquals(progress.elapsedDays, snapshot.workProgress.elapsedDays)
        assertEquals(store.task(task.id), snapshot.dayTasks[task.id])
    }
}
