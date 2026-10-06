package uk.co.maybeitsadam.takt.ui.habits

import java.time.LocalDateTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.HabitExpiry
import uk.co.maybeitsadam.takt.core.HabitFrequency
import uk.co.maybeitsadam.takt.data.workspace.HabitDraft

/** The habit form's rules: frequency chips, the estimate and end-date fields, what it refuses. */
class HabitFormTest {
    private val zone = ZoneOffset.UTC
    private val now = LocalDateTime.of(2026, 10, 5, 12, 0).toInstant(zone)

    @Test fun switchingKindStartsFromTheMacsDefaults() {
        assertEquals(HabitFrequency.Weekdays(setOf(2, 3, 4, 5, 6)), HabitForm.withKind(HabitFrequency.Daily, HabitFrequencyKind.WEEKDAYS))
        assertEquals(HabitFrequency.EveryNDays(3), HabitForm.withKind(HabitFrequency.Daily, HabitFrequencyKind.EVERY_N_DAYS))
        assertEquals(HabitFrequency.EveryNDays(5), HabitForm.withKind(HabitFrequency.EveryNDays(5), HabitFrequencyKind.EVERY_N_DAYS))
        assertEquals(HabitFrequency.Weekly, HabitForm.withKind(HabitFrequency.Daily, HabitFrequencyKind.WEEKLY))
    }

    @Test fun weekdayChipsKeepOneDayAndSevenIsEveryDay() {
        val one = HabitFrequency.Weekdays(setOf(2))
        assertEquals(one, HabitForm.toggleWeekday(one, 2))
        assertEquals(HabitFrequency.Weekdays(setOf(2, 4)), HabitForm.toggleWeekday(one, 4))
        assertEquals(HabitFrequency.Daily, HabitForm.toggleWeekday(HabitFrequency.Weekdays(setOf(1, 2, 3, 4, 5, 6)), 7))
    }

    @Test fun theIntervalStaysBetweenTwoAndAYear() {
        assertEquals(HabitFrequency.EveryNDays(2), HabitForm.stepInterval(HabitFrequency.EveryNDays(2), -1))
        assertEquals(HabitFrequency.EveryNDays(366), HabitForm.stepInterval(HabitFrequency.EveryNDays(366), 1))
    }

    @Test fun estimatesReadBackAsTheyAreTyped() {
        assertEquals("", HabitForm.estimateText(null))
        assertEquals("30m", HabitForm.estimateText(1_800))
        assertEquals("1h", HabitForm.estimateText(3_600))
        assertEquals("1h30", HabitForm.estimateText(5_400))
    }

    @Test fun onlyAHabitFromATaskCanEndWithIt() {
        assertEquals(HabitExpiryKind.entries, HabitForm.expiryKinds(hasSource = true))
        assertEquals(listOf(HabitExpiryKind.DATE, HabitExpiryKind.NEVER), HabitForm.expiryKinds(hasSource = false))
        assertEquals("With its task", HabitForm.expiryLabel(HabitExpiryKind.SOURCE))
        assertEquals("Ends when “Learn drums” is done.", HabitForm.sourceHint("Learn drums"))
    }

    @Test fun validationReadsTheFieldsAndNamesWhatIsWrong() {
        val draft = HabitDraft.new(title = "  Practise drums ", sourceTaskId = "SOURCE")
        val valid = HabitForm.validate(draft, "45", "", now, zone) as HabitFormResult.Valid
        assertEquals("Practise drums", valid.draft.title)
        assertEquals(2_700, valid.draft.estimateSeconds)
        assertEquals(HabitExpiry.WhenSourceCompleted, valid.draft.expiry)

        assertEquals(HabitField.TITLE, (HabitForm.validate(draft.copy(title = " "), "", "", now, zone) as HabitFormResult.Invalid).field)
        assertEquals(HabitField.ESTIMATE, (HabitForm.validate(draft, "soon", "", now, zone) as HabitFormResult.Invalid).field)

        val dated = draft.copy(expiry = HabitExpiry.On(now))
        assertEquals(HabitField.EXPIRY_DATE, (HabitForm.validate(dated, "", "someday", now, zone) as HabitFormResult.Invalid).field)
        val ends = HabitForm.validate(dated, "", "2w", now, zone)
        assertTrue(ends is HabitFormResult.Valid)
        assertEquals(LocalDateTime.of(2026, 10, 19, 0, 0).toInstant(zone), (ends as HabitFormResult.Valid).draft.expiry.date)
    }
}
