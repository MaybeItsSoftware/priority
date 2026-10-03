package uk.co.maybeitsadam.priority.ui.review

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.CompletedWorkDayKind
import uk.co.maybeitsadam.priority.core.TaskProgressPeriod
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.ui.search.SearchMatching
import uk.co.maybeitsadam.priority.ui.settings.ThemeChoice
import uk.co.maybeitsadam.priority.ui.settings.ThemeChoices

private val utc = ZoneOffset.UTC

class ChartScaleTest {
    @Test
    fun roundsUpToANiceAxis() {
        assertEquals(listOf(0.0, 2.0, 4.0, 6.0, 8.0), ChartScale.nice(7.0).ticks)
        assertEquals(10.0, ChartScale.nice(10.0).max, 0.0)
        assertEquals(150.0, ChartScale.nice(137.0).max, 0.0)
        assertEquals(listOf(0.0, 50.0, 100.0, 150.0), ChartScale.nice(137.0).ticks)
    }

    @Test
    fun smallWholeNumbersUseWholeSteps() {
        val scale = ChartScale.nice(1.0)
        assertEquals(1.0, scale.max, 0.0)
        assertEquals(listOf(0.0, 1.0), scale.ticks)
    }

    @Test
    fun anEmptySeriesStillHasAnAxis() {
        val scale = ChartScale.nice(0.0)
        assertEquals(4.0, scale.max, 0.0)
        assertEquals(0f, scale.fraction(0.0))
    }

    @Test
    fun fractionsClampToThePlot() {
        val scale = ChartScale.nice(8.0)
        assertEquals(0.5f, scale.fraction(4.0))
        assertEquals(1f, scale.fraction(20.0))
        assertEquals(0f, scale.fraction(-3.0))
    }

    @Test
    fun barsShareTheWidthWithGaps() {
        val (left0, width0) = barSlot(0, 4, 400f)
        val (left3, width3) = barSlot(3, 4, 400f)
        assertEquals(75f, width0)
        assertEquals(12.5f, left0)
        assertEquals(width0, width3)
        assertEquals(312.5f, left3)
        assertEquals(0f to 100f, barSlot(0, 1, 100f))
        assertEquals(0f to 0f, barSlot(0, 0, 100f))
    }
}

class ReviewGroupingTest {
    private fun task(id: String, completedAt: String?, listId: String = "l1", status: TaskStatus = TaskStatus.COMPLETED) = WorkspaceTask(
        id = id, listId = listId, parentTaskId = null, title = id, notes = "", status = status, sortOrder = 0,
        dueAt = null, estimateSeconds = null, sourceSystem = null, sourceId = null, itemKind = null, isPromoted = null, archivedAt = null,
        completedAt = completedAt?.let(Instant::parse), createdAt = Instant.EPOCH, updatedAt = Instant.EPOCH,
    )

    private val now = Instant.parse("2026-10-02T12:00:00Z")

    @Test
    fun groupsByDayNewestFirstWithListNames() {
        val groups = doneGroups(
            listOf(
                task("a", "2026-10-02T09:00:00Z"),
                task("b", "2026-10-02T11:00:00Z", listId = "l2"),
                task("c", "2026-10-01T20:00:00Z", status = TaskStatus.CANCELLED),
                task("d", "2026-09-20T08:00:00Z"),
            ),
            mapOf("l1" to "Inbox", "l2" to "Work"),
            now, utc,
        )
        assertEquals(listOf("Today", "Yesterday", "Sun 20 Sep"), groups.map { it.title(utc) })
        assertEquals(listOf("b", "a"), groups[0].items.map { it.task.id })
        assertEquals("Work", groups[0].items[0].listName)
        assertEquals(CompletedWorkDayKind.EARLIER, groups[2].kind)
    }

    @Test
    fun aDayThisWeekIsNamed() {
        assertEquals(
            "Monday",
            doneDayTitle(Instant.parse("2026-09-28T00:00:00Z"), CompletedWorkDayKind.THIS_WEEK, utc),
        )
    }

    @Test
    fun theDayStripEndsToday() {
        val strip = dayStrip(LocalDate.of(2026, 10, 2), 3)
        assertEquals(listOf(LocalDate.of(2026, 9, 30), LocalDate.of(2026, 10, 1), LocalDate.of(2026, 10, 2)), strip)
    }

    @Test
    fun progressBucketsFocusMinutesAndRunningTotals() {
        val summary = ProgressSummary.build(
            TaskProgressPeriod.WEEK,
            completions = listOf(Instant.parse("2026-10-01T10:00:00Z"), Instant.parse("2026-10-02T10:00:00Z"), Instant.parse("2026-10-02T11:00:00Z")),
            creations = listOf(Instant.parse("2026-09-30T10:00:00Z")),
            blocks = listOf(1500 to Instant.parse("2026-10-02T09:00:00Z"), 600 to Instant.parse("2026-10-02T10:00:00Z")),
            now = now, zone = utc,
        )
        assertEquals(7, summary.days.size)
        assertEquals(35, summary.days.last().focusMinutes)
        assertEquals(3, summary.days.last().cumulativeCompleted)
        assertEquals(1, summary.days.last().cumulativeAdded)
        assertEquals(2, summary.net)
        assertEquals(Instant.parse("2026-10-02T00:00:00Z"), summary.bestDay?.day)
    }

    @Test
    fun timelineGroupsBlocksByTaskAndColoursThem() {
        val day = LocalDate.of(2026, 10, 2)
        val timeline = TimelineDay.build(
            day,
            listOf(
                TimelineDay.Input("b1", "t1", "Write", 1500, Instant.parse("2026-10-02T10:00:00Z")),
                TimelineDay.Input("b2", "t2", "Read", 600, Instant.parse("2026-10-02T11:00:00Z")),
                TimelineDay.Input("b3", "t1", "Write (renamed)", 1200, Instant.parse("2026-10-02T12:00:00Z")),
            ),
            awards = emptyList(),
            live = null,
            completions = listOf(task("done", "2026-10-02T11:30:00Z")),
            now = now, zone = utc,
        )
        assertEquals(3300, timeline.totalSeconds)
        assertEquals(listOf("t1", "t2"), timeline.summaries.map { it.id })
        assertEquals("Write (renamed)", timeline.summaries[0].title)
        assertEquals(0, timeline.hue("b3"))
        assertEquals(1, timeline.hue("b2"))
        assertTrue((timeline.offsetMinutes(Instant.parse("2026-10-02T11:30:00Z")) ?: -1.0) > 0)
        assertNull(timeline.offsetMinutes(Instant.parse("2026-10-02T23:30:00Z")))
    }
}

class SearchMatchingTest {
    @Test
    fun matchesWordPrefixesCaseInsensitively() {
        assertEquals(listOf(0..2, 10..12), SearchMatching.ranges("Write the report", "wri rep"))
        assertEquals(emptyList<IntRange>(), SearchMatching.ranges("Rewrite", "write"))
        assertEquals(listOf(0..3), SearchMatching.ranges("Project", "pro proj"))
    }

    @Test
    fun arrowKeysClamp() {
        assertEquals(0, SearchMatching.move(null, 1, 3))
        assertEquals(2, SearchMatching.move(null, -1, 3))
        assertEquals(2, SearchMatching.move(2, 1, 3))
        assertEquals(0, SearchMatching.move(0, -1, 3))
        assertNull(SearchMatching.move(1, 1, 0))
    }
}

class ThemeChoicesTest {
    @Test
    fun readsTheChoiceFromTheActiveJson() {
        assertEquals(ThemeChoice.Chalk, ThemeChoices.choice(null))
        assertEquals(ThemeChoice.ChalkDark, ThemeChoices.choice(ThemeChoices.chalkDarkJson))
        assertEquals(ThemeChoice.Imported("Paper"), ThemeChoices.choice("""{"name":"Paper"}"""))
        assertEquals(ThemeChoice.Chalk, ThemeChoices.choice("not json"))
    }

    @Test
    fun keepsTheImportedThemeWhileAnotherIsActive() {
        val paper = """{"name":"Paper"}"""
        assertEquals(paper, ThemeChoices.importedJson(null, paper))
        assertEquals(paper, ThemeChoices.importedJson(paper, null))
        assertNull(ThemeChoices.importedJson(ThemeChoices.chalkDarkJson, null))
    }
}
