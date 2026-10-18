package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same cases as `BlockedSectionTests.swift`, so the phone and the Mac label alike. */
class BlockedSectionTest {
    @Test fun theLabelHeadsEachGroupsBlockedTail() {
        // An outline: a's subtasks drawn between it and its blocked siblings.
        val items = listOf(
            "a" to "root", "a1" to "a", "a2" to "a", "a3" to "a",
            "b" to "root", "c" to "root",
        )
        assertEquals(setOf("a2", "b"), BlockedSection.labelledIds(items, setOf("a2", "a3", "b", "c")))
    }

    /** Siblings drawn open, then blocked, then buried: each run labelled apart; both is buried. */
    @Test fun blockedAndBuriedRunsAreLabelledApart() {
        val items = listOf(
            "a" to "root", "a1" to "a", "a2" to "a",
            "b" to "root", "c" to "root", "c1" to "c", "d" to "root",
        )
        val (blocked, buried) = BlockedSection.labelledIds(items, setOf("b", "d"), setOf("a2", "c", "d"))
        assertEquals(setOf("b"), blocked)
        assertEquals(setOf("a2", "c"), buried)
    }

    @Test fun nothingBlockedNoLabel() =
        assertTrue(BlockedSection.labelledIds(listOf("a" to 0, "b" to 0), emptySet()).isEmpty())

    /** A blocked task with an open one after it is faded, not labelled. */
    @Test fun aBlockedTaskAboveAnOpenOneIsNotLabelled() {
        val items = listOf("a" to 0, "b" to 0, "c" to 0)
        assertTrue(BlockedSection.labelledIds(items, setOf("a")).isEmpty())
        assertEquals(setOf("c"), BlockedSection.labelledIds(items, setOf("a", "c")))
    }

    @Test fun aGroupOfOnlyBlockedTasksIsLabelledAtItsTop() {
        val items = listOf("a" to "done", "b" to "waiting", "c" to "waiting")
        assertEquals(setOf("b"), BlockedSection.labelledIds(items, setOf("b", "c")))
    }
}
