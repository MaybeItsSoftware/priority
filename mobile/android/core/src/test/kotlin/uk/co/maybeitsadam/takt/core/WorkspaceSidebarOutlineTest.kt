package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.WorkspaceSidebarRowKind as K

class WorkspaceSidebarOutlineTest {
    private fun outline(
        inbox: SidebarListDescriptor? = SidebarListDescriptor("inbox", null),
        lists: List<SidebarListDescriptor> = emptyList(),
        folders: List<SidebarFolderDescriptor> = emptyList(),
        nested: List<SidebarNestedListDescriptor> = emptyList(),
        expanded: Set<String> = emptySet(),
    ) = WorkspaceSidebarOutline.rows(inbox, lists, folders, nested, expanded)

    @Test fun everythingComesFirst() {
        val rows = outline()
        assertEquals(K.Everything, rows.first().kind)
        assertFalse(rows.any { it.id == "row:focus" || it.id == "row:timeline" })
    }

    @Test fun theOrderIsInboxThenPinnedThenFoldersThenLooseLists() {
        val rows = outline(
            lists = listOf(SidebarListDescriptor("loose", null), SidebarListDescriptor("filed", "work")),
            folders = listOf(SidebarFolderDescriptor("work", null)),
            nested = listOf(SidebarNestedListDescriptor("pin", "inbox", 0, true)),
            expanded = setOf("work"),
        )
        assertEquals(
            listOf(K.Everything, K.List("inbox"), K.NestedList("pin"), K.NestedList("pin"), K.Folder("work"), K.List("filed"), K.List("loose")),
            rows.map { it.kind },
        )
    }

    @Test fun aPinnedListAppearsTwiceWithTwoDistinctRowIDs() {
        val rows = outline(nested = listOf(SidebarNestedListDescriptor("pin", "inbox", 0, true)))
        val pinned = rows.filter { it.kind == K.NestedList("pin") }
        assertEquals(2, pinned.size)
        assertEquals(2, pinned.map { it.id }.toSet().size)
        assertEquals(rows.size, rows.map { it.id }.toSet().size)
    }

    @Test fun walkingReachesEveryRowIncludingTheSecondCopy() {
        val rows = outline(nested = listOf(SidebarNestedListDescriptor("pin", "inbox", 0, true)))
        val visited = mutableListOf<String>()
        var cursor: String? = rows.first().id
        while (cursor != null) {
            visited += cursor
            val next = WorkspaceSidebarOutline.row(cursor, 1, rows)
            cursor = if (next?.id == cursor) null else next?.id
        }
        assertEquals(rows.map { it.id }, visited)
    }

    @Test fun aCollapsedFolderHidesItsContents() {
        val lists = listOf(SidebarListDescriptor("filed", "work"))
        val folders = listOf(SidebarFolderDescriptor("work", null))
        assertFalse(outline(lists = lists, folders = folders).any { it.kind == K.List("filed") })
        assertTrue(outline(lists = lists, folders = folders, expanded = setOf("work")).any { it.kind == K.List("filed") })
    }

    @Test fun nestingIsReportedAsDepth() {
        val rows = outline(
            inbox = null,
            lists = listOf(SidebarListDescriptor("filed", "inner")),
            folders = listOf(SidebarFolderDescriptor("outer", null), SidebarFolderDescriptor("inner", "outer")),
            nested = listOf(SidebarNestedListDescriptor("deep", "filed", 1, false)),
            expanded = setOf("outer", "inner"),
        )
        fun depth(kind: K) = rows.firstOrNull { it.kind == kind }?.depth
        assertEquals(0, depth(K.Folder("outer")))
        assertEquals(1, depth(K.Folder("inner")))
        assertEquals(2, depth(K.List("filed")))
        assertEquals(4, depth(K.NestedList("deep")))
    }

    @Test fun aFolderCycleTerminates() {
        val rows = outline(
            inbox = null,
            folders = listOf(SidebarFolderDescriptor("a", "b"), SidebarFolderDescriptor("b", "a")),
            expanded = setOf("a", "b"),
        )
        assertEquals(listOf<K>(K.Everything), rows.map { it.kind })
    }

    @Test fun theCursorStopsAtEitherEndRatherThanWrapping() {
        val rows = outline()
        assertEquals(rows.first().id, WorkspaceSidebarOutline.row(rows.first().id, -1, rows)?.id)
        assertEquals(rows.last().id, WorkspaceSidebarOutline.row(rows.last().id, 1, rows)?.id)
    }

    @Test fun anUnknownCursorStartsFromTheNearEnd() {
        val rows = outline()
        assertEquals(rows.first().id, WorkspaceSidebarOutline.row(null, 1, rows)?.id)
        assertEquals(rows.last().id, WorkspaceSidebarOutline.row(null, -1, rows)?.id)
    }

    @Test fun theRowIsRecoverableFromWhatIsSelected() {
        val rows = outline(lists = listOf(SidebarListDescriptor("loose", null)))
        assertEquals(K.List("loose"), WorkspaceSidebarOutline.rowMatching("loose", false, rows)?.kind)
        assertEquals(K.Everything, WorkspaceSidebarOutline.rowMatching(null, true, rows)?.kind)
        assertNull(WorkspaceSidebarOutline.rowMatching("gone", false, rows))
    }

    // WorkspaceFolderScopeTests

    private fun folder(id: String, parent: String? = null) = SidebarFolderDescriptor(id, parent)
    private fun list(id: String, folder: String?) = SidebarListDescriptor(id, folder)

    @Test fun aFolderStandsForItsOwnLists() {
        assertEquals(listOf("a", "b"), WorkspaceSidebarOutline.listIDs("work", listOf(folder("work")),
            listOf(list("a", "work"), list("b", "work"), list("loose", null))))
    }

    @Test fun subFolderListsAreIncludedEvenWhenCollapsed() {
        assertEquals(listOf("a", "b", "c"), WorkspaceSidebarOutline.listIDs("work",
            listOf(folder("work"), folder("clients", "work"), folder("deep", "clients")),
            listOf(list("a", "work"), list("b", "clients"), list("c", "deep"))))
    }

    @Test fun theFoldersOwnListsComeFirst() {
        assertEquals("own", WorkspaceSidebarOutline.listIDs("work", listOf(folder("work"), folder("clients", "work")),
            listOf(list("nested", "clients"), list("own", "work"))).first())
    }

    @Test fun aSiblingFolderIsNotIncluded() {
        assertEquals(listOf("a"), WorkspaceSidebarOutline.listIDs("work", listOf(folder("work"), folder("home")),
            listOf(list("a", "work"), list("b", "home"))))
    }

    @Test fun anEmptyFolderStandsForNothing() {
        assertTrue(WorkspaceSidebarOutline.listIDs("work", listOf(folder("work")), emptyList()).isEmpty())
    }

    @Test fun aCycleInTheParentChainTerminates() {
        assertEquals(setOf("one", "two"), WorkspaceSidebarOutline.listIDs("a", listOf(folder("a", "b"), folder("b", "a")),
            listOf(list("one", "a"), list("two", "b"))).toSet())
    }
}
