package uk.co.maybeitsadam.takt.ui.lists

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskListRole
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.core.WorkspaceListTree
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.ListScopeData
import uk.co.maybeitsadam.takt.data.workspace.SidebarData
import uk.co.maybeitsadam.takt.data.workspace.TaskDecoration

class ListsShapingTest {
    private val zone = ZoneOffset.UTC
    private val today = LocalDate.of(2026, 10, 2)
    private val t0 = Instant.parse("2026-01-01T00:00:00Z")

    private fun list(
        id: String,
        name: String = id,
        folder: String? = null,
        role: TaskListRole? = null,
        archived: Boolean = false,
        order: Int = 0,
    ) = TaskList(id, "w", folder, name, null, order, archived, role, null, null, t0, t0)

    private var order = 0

    private fun task(
        id: String,
        listId: String,
        parent: String? = null,
        status: TaskStatus = TaskStatus.OPEN,
        kind: WorkspaceItemKind? = null,
        due: Instant? = null,
    ) = WorkspaceTask(
        id, listId, parent, id.replaceFirstChar { it.uppercase() }, "", status, order++, due, null, null, null, kind, null, null,
        createdAt = t0, updatedAt = t0,
    )

    private fun scope(
        lists: List<TaskList>,
        tasks: List<WorkspaceTask>,
        decorations: Map<String, TaskDecoration> = emptyMap(),
        dailies: Set<String> = emptySet(),
    ) = ListScopeData(
        lists, lists.associate { l -> l.id to WorkspaceListTree(l.id, tasks.filter { it.listId == l.id }) }, decorations, dailies, lists,
    )

    private val home = list("home")
    private val tasks = listOf(
        task("a", "home"),
        task("a1", "home", parent = "a"),
        task("a2", "home", parent = "a", status = TaskStatus.COMPLETED),
        task("a2x", "home", parent = "a2"),
        task("b", "home", due = Instant.parse("2026-10-01T00:00:00Z")),
    )

    @Test fun foldingHidesABranchButKeepsItsRow() {
        val shape = OutlineShaping.shape(scope(listOf(home), tasks), false, setOf("a"), false, emptySet(), zone, today)
        assertEquals(listOf("a", "b"), shape.rows.map { it.id })
        assertTrue(shape.rows.first().isFolded)
        assertTrue(shape.rows.first().hasChildren)
        assertEquals(setOf("a", "a2"), shape.parentIds)
    }

    @Test fun hidingCompletedDropsTheBranchBeneath() {
        val shape = OutlineShaping.shape(scope(listOf(home), tasks), false, emptySet(), true, emptySet(), zone, today)
        assertEquals(listOf("a", "a1", "b"), shape.rows.map { it.id })
    }

    @Test fun foldedAwayRowsLeaveTheOutline() {
        val shape = OutlineShaping.shape(scope(listOf(home), tasks), false, emptySet(), false, setOf("a2"), zone, today)
        assertEquals(listOf("a", "a1", "b"), shape.rows.map { it.id })
    }

    @Test fun rowsCarryDecorationsAndAnOverdueLabel() {
        val decorations = mapOf("b" to TaskDecoration(priority = 1, tags = listOf("work"), kanbanColumn = "today"))
        val shape = OutlineShaping.shape(scope(listOf(home), tasks, decorations, setOf("a")), false, emptySet(), false, emptySet(), zone, today)
        val b = shape.rows.first { it.id == "b" }
        assertEquals(1, b.priority)
        assertEquals(listOf("work"), b.tags)
        assertTrue(b.isPlanned)
        assertTrue(b.due!!.isOverdue)
        assertEquals("Yesterday", b.due!!.text)
        assertTrue(shape.rows.first { it.id == "a" }.isDaily)
    }

    @Test fun everythingHasAHeaderPerListWithRows() {
        val work = list("work")
        val all = tasks + task("w", "work")
        val shape = OutlineShaping.shape(scope(listOf(home, work, list("empty")), all), true, emptySet(), false, emptySet(), zone, today)
        val headers = shape.entries.filterIsInstance<OutlineEntry.Header>()
        assertEquals(listOf("home", "work"), headers.map { it.listId })
        // a, a1, b, and a2x (open beneath a closed task).
        assertEquals(4, headers.first().count)
    }

    @Test fun ancestorsAreFoundForReveal() {
        assertEquals(setOf("a", "a2"), OutlineShaping.ancestors(scope(listOf(home), tasks), "a2x"))
        assertTrue(OutlineShaping.ancestors(scope(listOf(home), tasks), "a").isEmpty())
    }

    @Test fun dropsLandAmongSiblingsOnly() {
        val rows = OutlineShaping.shape(scope(listOf(home), tasks), false, emptySet(), false, emptySet(), zone, today).rows
        // rows: a, a1, a2, a2x, b
        assertEquals(OutlineDrop.Before("a"), OutlineShaping.planDrop(rows, 4, 0))
        assertEquals(OutlineDrop.ToEnd, OutlineShaping.planDrop(rows, 0, 5))
        assertEquals(OutlineDrop.Before("a1"), OutlineShaping.planDrop(rows, 2, 1))
        // Where it already is.
        assertNull(OutlineShaping.planDrop(rows, 1, 2))
        // Into another parent's children.
        assertNull(OutlineShaping.planDrop(rows, 4, 2))
    }

    @Test fun unplacedCardsGoToTheFirstColumnAndSubtasksFollowTheirParent() {
        val decorations = mapOf("b" to TaskDecoration(kanbanColumn = "today"), "a1" to TaskDecoration(kanbanColumn = "today"))
        val board = BoardShaping.shape(scope(listOf(home), tasks, decorations), false, emptyMap(), emptySet(), false, zone, today)
        assertEquals("home/root", board.key)
        assertEquals(WorkspaceKanbanColumn.blitzitDefaults.map { it.id }, board.columns.map { it.id })
        val backlog = board.columns.first()
        assertEquals(listOf("a"), backlog.cards.map { it.id })
        assertEquals(listOf("a1", "a2", "a2x"), backlog.cards.first().subtasks.map { it.id })
        val todayColumn = board.columns.first { it.id == "today" }
        // a1 is filed apart from its parent, so it is a card of its own there.
        assertEquals(listOf("b", "a1"), todayColumn.cards.map { it.id })
        assertEquals("A", todayColumn.cards.last().parentTitle)
    }

    @Test fun aFoldedCardDrawsNoSubtasks() {
        val board = BoardShaping.shape(scope(listOf(home), tasks), false, emptyMap(), setOf("a"), false, zone, today)
        val card = board.columns.first().cards.first()
        assertTrue(card.subtasks.isEmpty())
        assertEquals(3, card.subtaskCount)
    }

    @Test fun theMatrixPlacesBoardCardsByQuadrant() {
        val decorations = mapOf(
            "a" to TaskDecoration(matrixUrgency = 1, matrixImportance = 1),
            "b" to TaskDecoration(matrixUrgency = 0, matrixImportance = 0),
        )
        val board = BoardShaping.shape(
            scope(listOf(home), tasks + task("c", "home"), decorations), false, emptyMap(), emptySet(), false, zone, today,
        )
        val matrix = BoardShaping.matrix(board)
        assertEquals(MatrixCell.DO_NOW, matrix.cellOf("a"))
        assertEquals(MatrixCell.ELIMINATE, matrix.cellOf("b"))
        assertEquals(listOf("c"), matrix.unplaced.map { it.id })
    }

    @Test fun resolvedColumnsKeepAColumnACardIsFiledUnder() {
        val custom = listOf(WorkspaceKanbanColumn("now", "Now"))
        val columns = BoardShaping.resolvedColumns("home/root", false, mapOf("home/root" to custom), listOf("home"), setOf("today"))
        assertEquals(listOf("now", "today"), columns.map { it.id })
    }

    @Test fun columnIdsAreSluggedAndUnique() {
        val columns = listOf(WorkspaceKanbanColumn("waiting-on", "Waiting on"))
        assertEquals("waiting-on-2", BoardShaping.uniqueColumnId("Waiting  on!", columns))
        assertEquals("column", BoardShaping.uniqueColumnId("!!", columns))
    }

    @Test fun theTreeListsInboxFoldersAndArchived() {
        val inbox = list("inbox", "Inbox", role = TaskListRole.INBOX)
        val inFolder = list("x", "X", folder = "f")
        val loose = list("y", "Y", order = 1)
        val gone = list("z", "Z", archived = true)
        val folder = ListFolder("f", "w", null, "Folder", 0, t0, t0)
        val nestedTasks = listOf(task("n", "y", kind = WorkspaceItemKind.LIST), task("n1", "y", parent = "n"), task("open", "x"))
        val data = SidebarData(
            listOf(folder),
            listOf(inbox, inFolder, loose, gone),
            listOf(inbox, inFolder, loose).associate { l -> l.id to WorkspaceListTree(l.id, nestedTasks.filter { it.listId == l.id }) },
        )
        val state = ListsTreeShaping.shape(data, emptySet(), showArchived = true)
        assertEquals(
            listOf("row:everything", "list:inbox", "folder:f", "list:x", "list:y", "nested:y:n", "row:archived", "archived:z"),
            state.rows.map { it.key },
        )
        assertEquals(2, (state.rows[0] as TreeRow.Everything).openCount)
        assertEquals(1, (state.rows.first { it.key == "nested:y:n" } as TreeRow.NestedRow).openCount)

        val collapsed = ListsTreeShaping.shape(data, setOf("f"), showArchived = false)
        assertFalse(collapsed.rows.any { it.key == "list:x" })
        assertFalse(collapsed.rows.any { it.key == "archived:z" })
    }
}
