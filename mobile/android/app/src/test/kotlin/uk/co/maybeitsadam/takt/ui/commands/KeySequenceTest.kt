package uk.co.maybeitsadam.takt.ui.commands

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.takt.ui.commands.KeySequence.Result

/** `-` waits for a digit, as on the Mac, so `-3` is priority −3 rather than −1 and then 3. */
class KeySequenceTest {
    private val sequence = KeySequence(KeyCatalog.sequences.keys)

    @Test fun theCatalogueGivesTheFourMinusPriorities() {
        assertEquals(setOf("-1", "-2", "-3", "-4"), KeyCatalog.sequences.keys)
        assertEquals(KeyCommand.TASK_SET_PRIORITY, KeyCatalog.sequences["-3"])
    }

    @Test fun minusThenADigitIsOneCommand() {
        assertEquals(Result.Pending, sequence.advance("-", 0))
        assertEquals(Result.Command("-3"), sequence.advance("3", 400))
        assertEquals("", sequence.prefix)
    }

    @Test fun aLoneMinusRunsWhenTheHoldTimesOut() {
        assertEquals(Result.Pending, sequence.advance("-", 100))
        assertNull(sequence.expire(50))
        assertEquals("-", sequence.expire(100))
        assertNull(sequence.expire(100))
    }

    @Test fun aDigitTooLateIsItsOwnKey() {
        sequence.advance("-", 0)
        assertEquals(Result.Flush("-"), sequence.advance("3", KeySequence.TIMEOUT_MS + 1))
    }

    @Test fun anyOtherKeyReleasesTheMinusFirst() {
        sequence.advance("-", 0)
        assertEquals(Result.Flush("-"), sequence.advance("", 10))
        sequence.advance("-", 20)
        assertEquals(Result.FlushAndHold("-"), sequence.advance("-", 30))
        assertEquals(Result.Flush("-"), sequence.advance("9", 40))
    }

    @Test fun aDigitWithNothingHeldPasses() {
        assertEquals(Result.Pass, sequence.advance("3", 0))
        assertEquals(Result.Pass, sequence.advance("", 0))
    }
}
