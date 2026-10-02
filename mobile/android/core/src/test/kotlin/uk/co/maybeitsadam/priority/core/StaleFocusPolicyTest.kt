package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Test

class StaleFocusPolicyTest {
    private val boundary = DayBoundary(4, UTC)
    private fun d(day: Int, hour: Int) = date(2026, 9, day, hour)
    private fun resolve(pausedAt: java.time.Instant?, seconds: Int, now: java.time.Instant, hasActiveTask: Boolean = true) =
        StaleFocusPolicy.resolution(pausedAt, seconds, hasActiveTask, now, boundary)

    @Test fun aRunningSessionIsLeftAlone() = assertEquals(StaleFocusResolution.KEEP, resolve(null, 900, d(25, 15)))
    @Test fun aBlockPausedEarlierTodayStaysPaused() = assertEquals(StaleFocusResolution.KEEP, resolve(d(25, 9), 900, d(25, 15)))
    @Test fun aBlockPausedAfterMidnightBelongsToTheDayThatStarted() = assertEquals(StaleFocusResolution.KEEP, resolve(d(25, 23), 900, d(26, 1)))
    @Test fun yesterdaysBlockWithRealTimeIsClosedOut() = assertEquals(StaleFocusResolution.CLOSE, resolve(d(24, 15), 900, d(25, 15)))
    @Test fun yesterdaysBlockWithNoTimeIsDiscarded() = assertEquals(StaleFocusResolution.DISCARD, resolve(d(24, 15), 0, d(25, 15)))

    @Test fun anythingUnderAMinuteIsNotASitting() {
        assertEquals(StaleFocusResolution.DISCARD, resolve(d(24, 15), 59, d(25, 15)))
        assertEquals(StaleFocusResolution.CLOSE, resolve(d(24, 15), 60, d(25, 15)))
    }

    @Test fun aSessionWithNoActiveTaskHasNothingToCredit() =
        assertEquals(StaleFocusResolution.DISCARD, resolve(d(24, 15), 900, d(25, 15), hasActiveTask = false))

    @Test fun aWeekOldBlockIsStillResolvedRatherThanRestored() = assertEquals(StaleFocusResolution.CLOSE, resolve(d(18, 11), 1_500, d(25, 15)))
}
