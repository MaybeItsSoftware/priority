package uk.co.maybeitsadam.takt.ui.commands

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The palette's keys and titles are the core's catalogue, translated for a hardware keyboard. */
class KeyCatalogTest {
    @Test fun everyCommandIsInTheCatalogueOrAndroidsOwn() {
        val own = setOf("planSelectNext", "planSelectPrevious", "windowHistory", "windowSettings")
        for (command in KeyCommand.entries) {
            assertTrue(command.id, command.id in own || KeyCatalog.entry(command.id) != null)
        }
    }

    @Test fun theMacsCommandIsCtrlAndItsOptionIsAlt() {
        assertEquals("Ctrl+T", KeyCommand.GO_TODAY.keys)
        assertEquals("Ctrl+1", KeyCommand.GO_BOARD.keys)
        assertEquals("Alt+Up", KeyCommand.TASK_MOVE_UP.keys)
        assertEquals("Show as a board", KeyCommand.GO_BOARD.title)
    }

    @Test fun controlChordsAndSequencesHaveNoTranslationSoAndroidAddsItsOwn() {
        // The Mac's undo is also `ctrl+z` and `uu`; Ctrl+Y is Android's.
        assertEquals("Ctrl+Z", KeyCommand.WINDOW_UNDO.keys)
        assertEquals("Ctrl+Shift+Z / Ctrl+Y", KeyCommand.WINDOW_REDO.keys)
        // The Mac plans for today on Control+T.
        assertEquals("Alt+T", KeyCommand.TASK_TOGGLE_PLANNED_TODAY.keys)
        assertEquals("Z", KeyCommand.PLAN_TOGGLE_FOLD.keys)
    }

    @Test fun aBareKeyIsTypingAndAShellShortcutLeavesIt() {
        val search = KeyCommand.GO_SEARCH.chords
        assertTrue(search.any { it.typing })
        assertTrue(search.any { !it.typing && it.ctrl })
        assertEquals(4, KeyCommand.PLAN_MATRIX_PLACE.chords.size)
    }
}
