package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * project / step / detail, other; solo. Swift builds the tree through the store;
 * here it comes from WorkspaceListTree, which the store's `outline` is built on.
 */
class TaskOutlineFoldingTest {
    private val tree = WorkspaceListTree(
        "list",
        listOf(
            task("project", sortOrder = 0), task("solo", sortOrder = 1),
            task("step", parent = "project", sortOrder = 0), task("other", parent = "project", sortOrder = 1),
            task("detail", parent = "step"),
        ),
    ).outline()

    private fun titles(items: List<TaskOutlineItem>) = items.map { it.task.title }

    @Test fun theTreeReadsAsDrawn() = assertEquals(listOf("project", "step", "detail", "other", "solo"), titles(tree))

    @Test fun nothingFoldedDrawsEveryRow() = assertEquals(tree, TaskOutlineFolding.visible(tree, emptySet()))

    @Test fun foldingHidesTheWholeBranchButKeepsTheTask() =
        assertEquals(listOf("project", "solo"), titles(TaskOutlineFolding.visible(tree, setOf("project"))))

    @Test fun foldingANestedTaskKeepsItsSiblings() =
        assertEquals(listOf("project", "step", "other", "solo"), titles(TaskOutlineFolding.visible(tree, setOf("step"))))

    @Test fun aFoldBeneathAFoldChangesNothingUntilTheAncestorOpens() =
        assertEquals(listOf("project", "solo"), titles(TaskOutlineFolding.visible(tree, setOf("project", "step"))))

    @Test fun parentsAreTheRowsWithSomethingBeneathThem() =
        assertEquals(setOf("project", "step"), TaskOutlineFolding.parentIDs(tree))

    @Test fun parentAndFirstChild() {
        assertEquals("step", TaskOutlineFolding.parentID("detail", tree))
        assertEquals("project", TaskOutlineFolding.parentID("other", tree))
        assertNull(TaskOutlineFolding.parentID("solo", tree))
        assertEquals("step", TaskOutlineFolding.firstChildID("project", tree))
        assertNull(TaskOutlineFolding.firstChildID("other", tree))
        assertNull(TaskOutlineFolding.firstChildID("solo", tree))
    }

    @Test fun descendants() {
        assertEquals(listOf("step", "detail", "other"), TaskOutlineFolding.descendantIDs("project", tree))
        assertEquals(emptyList<String>(), TaskOutlineFolding.descendantIDs("solo", tree))
    }
}
