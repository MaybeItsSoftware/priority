package uk.co.maybeitsadam.takt.ui.actions

import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.data.workspace.RecurrenceClashChoice
import uk.co.maybeitsadam.takt.data.workspace.TaskRecurrenceClash

/** The wording is the Mac's and the iPhone's, word for word. */
class RecurrenceClashTextTest {
    private val utc = ZoneOffset.UTC
    private val tuesday = Instant.parse("2026-10-20T09:00:00Z")

    private fun clash(movedTo: Instant) = TaskRecurrenceClash("t", "daily", nextTurn = tuesday, movedTo = movedTo)

    @Test
    fun theTitleNamesTheTaskAndTheDayItComesRoundAgain() {
        assertEquals(
            "Stretch comes round again on Tue 20 Oct",
            RecurrenceClashText.title("Stretch", clash(tuesday), utc),
        )
    }

    @Test
    fun theMessageSaysWhetherTheMoveLandsOnTheTurnOrGoesPastIt() {
        val sameDay = clash(Instant.parse("2026-10-20T18:00:00Z"))
        assertTrue(RecurrenceClashText.landsOnTurn(sameDay, utc))
        assertEquals("Moving it to Tue 20 Oct lands on that turn.", RecurrenceClashText.message(sameDay, utc))

        val later = clash(Instant.parse("2026-10-22T09:00:00Z"))
        assertFalse(RecurrenceClashText.landsOnTurn(later, utc))
        assertEquals("Moving it to Thu 22 Oct goes past that turn.", RecurrenceClashText.message(later, utc))
    }

    @Test
    fun theChoicesAreTheSameThreeInTheSameOrder() {
        assertEquals(listOf("Stack on that day", "Keep both", "Cancel"), RecurrenceClashChoice.entries.map { it.title })
    }

    @Test
    fun aNewQuestionCancelsTheOneStillOpen() = runBlocking {
        val clashes = RecurrenceClashQuestions()
        val first = async(start = CoroutineStart.UNDISPATCHED) { clashes.choose("A", clash(tuesday)) }
        val second = async(start = CoroutineStart.UNDISPATCHED) { clashes.choose("B", clash(tuesday)) }
        assertEquals(RecurrenceClashChoice.CANCEL, first.await())
        assertEquals("B", clashes.pending.value?.taskTitle)
        clashes.answer(RecurrenceClashChoice.KEEP_BOTH)
        assertEquals(RecurrenceClashChoice.KEEP_BOTH, second.await())
        assertEquals(null, clashes.pending.value)
    }

    @Test
    fun noClashIsStackWithoutAsking() = runBlocking {
        val clashes = RecurrenceClashQuestions()
        assertEquals(RecurrenceClashChoice.STACK, clashes.choose("A", null))
        assertEquals(null, clashes.pending.value)
    }
}
