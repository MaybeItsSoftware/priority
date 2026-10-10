package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The shapes Checkvist returns, as the Rust core reads them on every platform. */
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
        // The Mac's Foundation read the day and ignored the rest, and the core keeps that.
        assertEquals(date(2026, 10, 2), DueDateParsing.date("2026/10/02 09:00:00 +0100", UTC))
        assertEquals(date(2026, 10, 2), DueDateParsing.date("2026-10-02 sometime", UTC))
    }
}
