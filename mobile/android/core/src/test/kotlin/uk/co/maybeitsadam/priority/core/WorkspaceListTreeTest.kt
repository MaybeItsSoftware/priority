package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The in-memory parts of `WorkspaceListTreeTests.swift`. The Swift suite also
 * checks each shape against the store's own queries; that half belongs to the
 * data module's repository tests.
 */
class WorkspaceListTreeTest {
    private val archivedAt = epoch(1_000)
    private var order = 0
    private fun t(id: String, parent: String? = null, list: Boolean = false, status: TaskStatus = TaskStatus.OPEN,
                  archived: Boolean = false, listId: String = "work") =
        task(id, listId = listId, parent = parent, status = status, sortOrder = order++,
            kind = if (list) WorkspaceItemKind.LIST else null, archivedAt = if (archived) archivedAt else null)

    /** Nesting, a nested list, an archived nested list with children, a finished task and a closed list. */
    private fun seed(): List<WorkspaceTask> = listOf(
        t("Project"), t("Step one", "Project"), t("Step two", "Project", status = TaskStatus.COMPLETED),
        t("Reading", list = true), t("Papers", "Reading", list = true), t("Paper A", "Papers"),
        t("Old", list = true, archived = true), t("Hidden", "Old"),
        t("Closed", list = true, status = TaskStatus.COMPLETED), t("Inside closed", "Closed"),
    )

    private fun listRecord(id: String, root: String? = null) = TaskList(
        id = id, workspaceId = "ws", folderId = null, name = id, colorHex = null, sortOrder = 0, isArchived = false,
        systemRole = null, visibleRootTaskId = root, completedAt = null, createdAt = epoch(0), updatedAt = epoch(0),
    )

    @Test fun outlineIsDepthFirstInSiblingOrder() {
        val tree = WorkspaceListTree("work", seed())
        assertEquals(
            listOf("Project", "Step one", "Step two", "Reading", "Papers", "Paper A", "Old", "Hidden", "Closed", "Inside closed"),
            tree.outline().map { it.id },
        )
        assertEquals(listOf(0, 1, 1, 0, 1, 2, 0, 1, 0, 1), tree.outline().map { it.depth })
        assertEquals(listOf("Papers", "Paper A"), tree.outline("Reading").map { it.id })
    }

    @Test fun visibleOutlineDropsArchivedListsAndTheirContents() {
        val tree = WorkspaceListTree("work", seed())
        assertFalse(tree.visibleOutline().any { it.id == "Old" || it.id == "Hidden" })
        assertEquals(tree.outline().size - 2, tree.visibleOutline().size)
    }

    @Test fun actionableTasksSkipListsInactiveContainersAndFinishedWork() {
        val tree = WorkspaceListTree("work", seed())
        assertEquals(listOf("Project", "Step one", "Paper A"), tree.actionableTasks(null).map { it.id })
        assertEquals(listOf("Step one", "Paper A"), tree.actionableTasks("Project").map { it.id })
    }

    @Test fun visibleRootIsOnlyTheWrapperWhileItIsTheOnlyRoot() {
        val tree = WorkspaceListTree("work", listOf(t("Wrapper"), t("Child", "Wrapper")))
        assertEquals("Wrapper", tree.visibleRootParentTaskID("Wrapper"))
        assertNull(tree.visibleRootParentTaskID("Child"))
        assertNull(tree.visibleRootParentTaskID(null))
        val grown = WorkspaceListTree("work", tree.tasks + t("Second root"))
        assertNull(grown.visibleRootParentTaskID("Wrapper"))
    }

    @Test fun sidebarIndexCountsEveryTaskAndNestsListsByListDepth() {
        val trees = mapOf(
            "work" to WorkspaceListTree("work", seed()),
            "home" to WorkspaceListTree("home", listOf(t("Groceries", listId = "home"))),
        )
        val index = WorkspaceSidebarIndex.build(listOf(listRecord("work"), listRecord("home")), trees)
        assertEquals(10, index.taskCounts["work"])
        assertEquals(1, index.taskCounts["home"])
        assertEquals(listOf("Reading", "Papers", "Closed"), index.nestedLists.map { it.task.title })
        assertEquals(listOf(0, 1, 0), index.nestedLists.map { it.depth })
        assertEquals(listOf("Old"), index.archivedNestedLists.map { it.id })
    }

    @Test fun boardTreesReachEveryLevelBeneathEveryCardAndInsideIt() {
        val tasks = listOf(
            t("Project"), t("Step", "Project"), t("Part", "Step"), t("Detail", "Part", status = TaskStatus.COMPLETED),
            t("Sibling", "Project"), t("Old", "Project", list = true, archived = true), t("Hidden", "Old"), t("Elsewhere"),
        )
        val tree = WorkspaceListTree("work", tasks)
        val board = WorkspaceBoardTrees.build(setOf("Project"), listOf(tree))
        val beneath = board.descendants.getValue("Project")
        assertEquals(listOf("Step", "Part", "Detail", "Sibling"), beneath.map { it.task.title })
        assertEquals(listOf(0, 1, 2, 0), beneath.map { it.depth })
        assertEquals(TaskStatus.COMPLETED, beneath[2].task.status)
        assertEquals(listOf("Part", "Detail"), board.descendants["Step"]?.map { it.task.title })
        assertEquals(listOf(0, 1), board.descendants["Step"]?.map { it.depth })
        assertEquals(emptyList<TaskOutlineItem>(), board.descendants["Detail"])
        assertEquals(emptyList<TaskOutlineItem>(), board.descendants["Sibling"])
        assertNull(board.descendants["Elsewhere"])
        assertEquals("Part", board.parents["Detail"]?.id)
        assertNull(board.parents["Project"])

        val scoped = WorkspaceBoardTrees.build(setOf("Step", "Sibling"), listOf(tree))
        assertEquals(listOf(0, 1), scoped.descendants["Step"]?.map { it.depth })
        assertNull(scoped.descendants["Project"])
        assertEquals(setOf("Step", "Part", "Detail", "Sibling"), scoped.descendants.keys)
    }
}
