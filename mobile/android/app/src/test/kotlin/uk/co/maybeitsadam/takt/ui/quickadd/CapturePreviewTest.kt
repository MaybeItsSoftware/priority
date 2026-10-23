package uk.co.maybeitsadam.takt.ui.quickadd

import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CapturePreviewTest {
    // Friday 2 October 2026, 09:00 UTC.
    private val now = Instant.parse("2026-10-02T09:00:00Z")
    private val utc = ZoneOffset.UTC

    @Test
    fun everyTokenBecomesAChipOfItsKindInDetailOrder() {
        val preview = CapturePreview.of("Write the release notes 45m #work @tomorrow !1 #launch", now, utc)
        assertEquals("Write the release notes", preview.title)
        assertEquals(
            listOf(
                CaptureChip("45m", CaptureChipKind.ESTIMATE),
                CaptureChip("due tomorrow", CaptureChipKind.DUE),
                CaptureChip("#work", CaptureChipKind.TAG),
                CaptureChip("#launch", CaptureChipKind.TAG),
                CaptureChip("!1", CaptureChipKind.PRIORITY, priority = 1),
            ),
            preview.chips,
        )
        assertTrue(preview.canAdd)
        assertEquals("Will set 45m, due tomorrow, #work, #launch, !1", preview.spoken)
    }

    @Test
    fun plainTextHasNoChipsAndKeepsItsTitle() {
        val preview = CapturePreview.of("  Buy milk  ", now, utc)
        assertEquals("Buy milk", preview.title)
        assertTrue(preview.chips.isEmpty())
        assertEquals("", preview.spoken)
    }

    @Test
    fun theFirstWordIsNeverAToken() {
        val preview = CapturePreview.of("30m", now, utc)
        assertEquals("30m", preview.title)
        assertTrue(preview.chips.isEmpty())
    }

    @Test
    fun aTokenInTheMiddleStaysInTheTitle() {
        val preview = CapturePreview.of("Call #mum about 1h plans @fri", now, utc)
        assertEquals("Call #mum about 1h plans", preview.title)
        assertEquals(listOf(CaptureChipKind.DUE), preview.chips.map { it.kind })
        assertEquals("due today", preview.chips.single().label)
    }

    @Test
    fun aStartAndADueDayAreTwoChips() {
        val preview = CapturePreview.of("write essay ^fri @2026-10-09", now, utc)
        assertEquals(
            listOf(CaptureChip("starts today", CaptureChipKind.START), CaptureChip("due Fri 9 Oct", CaptureChipKind.DUE)),
            preview.chips,
        )
        assertTrue(preview.canAdd)
    }

    @Test
    fun aStartAfterTheDueDayCannotBeAdded() {
        val preview = CapturePreview.of("write essay ^mon @fri", now, utc)
        assertEquals("Start must be before the deadline.", preview.problem)
        assertFalse(preview.canAdd)
        assertEquals("Will set starts Mon 5 Oct, due today. Start must be before the deadline.", preview.spoken)
    }

    @Test
    fun blankTextCannotBeAdded() {
        assertFalse(CapturePreview.of("   ", now, utc).canAdd)
        assertEquals(CapturePreview.Empty, CapturePreview.of("", now, utc))
    }
}
