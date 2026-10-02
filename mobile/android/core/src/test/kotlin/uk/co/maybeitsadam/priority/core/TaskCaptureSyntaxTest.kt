package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class TaskCaptureSyntaxTest {
    /** Tuesday 29 September 2026, mid-morning. */
    private val now = date(2026, 9, 29, 10)
    private fun parse(text: String) = TaskCapture.parse(text, now, UTC)

    @Test fun aPlainTitleIsLeftExactlyAsTyped() {
        assertEquals(TaskCapture("Write the release notes"), parse("  Write the release notes "))
    }

    @Test fun everyKindOfTokenAtTheEnd() {
        val capture = parse("Write the release notes 45m #work @fri !1")
        assertEquals("Write the release notes", capture.title)
        assertEquals(45 * 60, capture.estimateSeconds)
        assertEquals(date(2026, 10, 2), capture.dueAt)
        assertEquals(listOf("work"), capture.tags)
        assertEquals(1, capture.priority)
        assertTrue(capture.hasDetails)
    }

    @Test fun tokensInTheMiddleOfATitleStayInIt() {
        assertEquals(TaskCapture("Buy 2m of cable"), parse("Buy 2m of cable"))
        assertEquals(TaskCapture("Read 30 pages"), parse("Read 30 pages"))
    }

    @Test fun aWordTheFieldDoesNotKnowEndsTheScan() {
        val capture = parse("Call mum @home 10m")
        assertEquals("Call mum @home", capture.title)
        assertEquals(10 * 60, capture.estimateSeconds)
    }

    @Test fun theFirstWordIsAlwaysTheTitle() {
        assertEquals(TaskCapture("30m"), parse("30m"))
        val capture = parse("30m #admin")
        assertEquals("30m", capture.title)
        assertEquals(listOf("admin"), capture.tags)
    }

    @Test fun estimateSpellings() {
        val cases = listOf(
            "30m" to 30, "90min" to 90, "5mins" to 5, "1h" to 60, "2hrs" to 120, "1.5h" to 90,
            "1h30m" to 90, "1h30" to 90, "~20m" to 20, "2hours" to 120, "45minutes" to 45,
            "0m" to null, "25h" to null, "1h75m" to null, "1.5h30" to null, "m" to null, "10" to null,
        )
        for ((word, minutes) in cases) {
            assertEquals("$word should be ${minutes}m", minutes?.let { it * 60 }, TaskCaptureToken.estimate(word))
        }
    }

    @Test fun dueSpellings() {
        val cases = listOf<Pair<String, Instant?>>(
            "today" to date(2026, 9, 29), "tod" to date(2026, 9, 29),
            "tomorrow" to date(2026, 9, 30), "tmr" to date(2026, 9, 30),
            "tue" to date(2026, 9, 29), "wednesday" to date(2026, 9, 30), "mon" to date(2026, 10, 5),
            "3d" to date(2026, 10, 2), "2w" to date(2026, 10, 13),
            "2026-12-25" to date(2026, 12, 25), "2027-1-4" to date(2027, 1, 4),
            "2026-02-31" to null, "home" to null, "0d" to null,
        )
        for ((word, expected) in cases) assertEquals(word, expected, TaskCaptureToken.due(word, now, UTC))
    }

    @Test fun dueNeedsItsAt() {
        assertEquals(TaskCapture("Stand up tomorrow"), parse("Stand up tomorrow"))
        assertEquals(date(2026, 9, 30), parse("Stand up @tomorrow").dueAt)
    }

    @Test fun tagsMustStartWithALetter() {
        assertEquals(TaskCapture("Fix issue #123"), parse("Fix issue #123"))
        assertEquals(TaskCapture("Chapter #1"), parse("Chapter #1"))
        assertEquals(listOf("q4-launch"), parse("Plan #q4-launch").tags)
    }

    @Test fun severalTagsKeepTheirOrderAndDropRepeats() {
        val capture = parse("Plan offsite #Work #travel #work")
        assertEquals("Plan offsite", capture.title)
        assertEquals(listOf("Work", "travel"), capture.tags)
    }

    @Test fun priorityIsOneToFour() {
        assertEquals(4, parse("Ship it !4").priority)
        assertEquals(TaskCapture("Ship it !5"), parse("Ship it !5"))
        assertEquals(TaskCapture("Ship it !"), parse("Ship it !"))
    }

    @Test fun aSecondTokenOfOneKindStaysInTheTitle() {
        val capture = parse("Draft 30m 45m")
        assertEquals("Draft 30m", capture.title)
        assertEquals(45 * 60, capture.estimateSeconds)
    }

    @Test fun labelsNameWhatWasFound() {
        assertEquals(
            listOf("1h 30m", "Tomorrow", "#work", "!2"),
            parse("Write notes 1h30m @tomorrow #work !2").detailLabels(now, UTC),
        )
        assertEquals(listOf("Fri 2 Oct"), parse("Book flights @2026-10-02").detailLabels(now, UTC))
        assertEquals(listOf("1 Mar 2027"), parse("Renew passport @2027-03-01").detailLabels(now, UTC))
    }
}
