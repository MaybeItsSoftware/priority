package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** No Swift suite targets DueDateParsing directly; these pin the formats its doc comment lists. */
class DueDateParsingTest {
    @Test fun emptyAndKeywordsNameNoDate() {
        assertNull(DueDateParsing.date(null))
        assertNull(DueDateParsing.date("  "))
        assertNull(DueDateParsing.date("asap"))
    }

    @Test fun acceptsEachShapeCheckvistReturns() {
        assertEquals(date(2026, 10, 2), DueDateParsing.date("2026-10-02", UTC))
        assertEquals(date(2026, 10, 2, 9, 30), DueDateParsing.date("2026-10-02T09:30:00Z", UTC))
        assertEquals(date(2026, 10, 2, 9, 30), DueDateParsing.date("2026-10-02T10:30:00.000+01:00", UTC))
        assertEquals(date(2026, 1, 5), DueDateParsing.date("2026-1-5", UTC))
        assertEquals(date(2026, 10, 2), DueDateParsing.date("2026/10/02", UTC))
        assertEquals(date(2026, 10, 2, 8), DueDateParsing.date("2026/10/02 09:00:00 +0100", UTC))
        assertEquals(date(2026, 10, 2), DueDateParsing.date("2026-10-02 sometime", UTC))
    }
}
