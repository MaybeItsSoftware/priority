package uk.co.maybeitsadam.takt.ui.habits

import java.time.Instant
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.HabitExpiry
import uk.co.maybeitsadam.takt.core.HabitFrequency
import uk.co.maybeitsadam.takt.core.HabitPolicy
import uk.co.maybeitsadam.takt.data.workspace.HabitDraft

/** The four ways the form offers to say how often. */
enum class HabitFrequencyKind(val label: String) {
    DAILY("Every day"),
    WEEKDAYS("On days"),
    EVERY_N_DAYS("Every N days"),
    WEEKLY("Weekly"),
}

/** The three ways a habit can end; "when its task is done" only for one made from a task. */
enum class HabitExpiryKind { SOURCE, DATE, NEVER }

/** A field the form can point an error at. */
enum class HabitField { TITLE, ESTIMATE, EXPIRY_DATE }

sealed interface HabitFormResult {
    data class Valid(val draft: HabitDraft) : HabitFormResult
    data class Invalid(val message: String, val field: HabitField) : HabitFormResult
}

/**
 * The habit form's rules, apart from Compose: the same choices, defaults and
 * messages as the Mac's `WorkspaceHabitOverlay`, so a habit made on either
 * reads the same on the other.
 */
object HabitForm {
    /** Monday first, as the Mac's chips run. Calendar numbering (1 = Sunday). */
    val weekdayOrder = listOf(2, 3, 4, 5, 6, 7, 1)
    private val weekdayNames = listOf("", "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa")

    fun weekdayName(weekday: Int): String = weekdayNames[weekday]

    fun kind(frequency: HabitFrequency): HabitFrequencyKind = when (frequency) {
        HabitFrequency.Daily -> HabitFrequencyKind.DAILY
        is HabitFrequency.Weekdays -> HabitFrequencyKind.WEEKDAYS
        is HabitFrequency.EveryNDays -> HabitFrequencyKind.EVERY_N_DAYS
        HabitFrequency.Weekly -> HabitFrequencyKind.WEEKLY
    }

    /** Switching kind: weekdays start Monday to Friday, every N days starts at 3 (or keeps its N). */
    fun withKind(frequency: HabitFrequency, kind: HabitFrequencyKind): HabitFrequency = when (kind) {
        HabitFrequencyKind.DAILY -> HabitFrequency.Daily
        HabitFrequencyKind.WEEKDAYS -> frequency as? HabitFrequency.Weekdays ?: HabitFrequency.Weekdays(setOf(2, 3, 4, 5, 6))
        HabitFrequencyKind.EVERY_N_DAYS -> frequency as? HabitFrequency.EveryNDays ?: HabitFrequency.EveryNDays(3)
        HabitFrequencyKind.WEEKLY -> HabitFrequency.Weekly
    }

    /** Toggles a weekday; the last one cannot be taken away, and all seven is every day. */
    fun toggleWeekday(frequency: HabitFrequency, weekday: Int): HabitFrequency {
        val days = (frequency as? HabitFrequency.Weekdays)?.days ?: return frequency
        val next = if (weekday in days) {
            if (days.size <= 1) return frequency
            days - weekday
        } else {
            days + weekday
        }
        return if (next.size == 7) HabitFrequency.Daily else HabitFrequency.Weekdays(next)
    }

    /** Every N days, nudged: never under 2 (that is every day) nor over 366. */
    fun stepInterval(frequency: HabitFrequency, by: Int): HabitFrequency {
        val days = (frequency as? HabitFrequency.EveryNDays)?.days ?: return frequency
        return HabitFrequency.EveryNDays((days + by).coerceIn(2, 366))
    }

    fun expiryKind(expiry: HabitExpiry): HabitExpiryKind = when (expiry) {
        HabitExpiry.WhenSourceCompleted -> HabitExpiryKind.SOURCE
        is HabitExpiry.On -> HabitExpiryKind.DATE
        HabitExpiry.Never -> HabitExpiryKind.NEVER
    }

    fun expiryKinds(hasSource: Boolean): List<HabitExpiryKind> =
        if (hasSource) HabitExpiryKind.entries else listOf(HabitExpiryKind.DATE, HabitExpiryKind.NEVER)

    fun expiryLabel(kind: HabitExpiryKind, sourceTitle: String?): String = when (kind) {
        HabitExpiryKind.SOURCE -> "When ${sourceTitle ?: "its task"} is done"
        HabitExpiryKind.DATE -> "On a date"
        HabitExpiryKind.NEVER -> "Never"
    }

    /** `30m`, `1h`, `1h30`: what the estimate field shows for a stored estimate. */
    fun estimateText(seconds: Int?): String {
        if (seconds == null) return ""
        val minutes = seconds / 60
        return when {
            minutes >= 60 && minutes % 60 == 0 -> "${minutes / 60}h"
            minutes > 60 -> "${minutes / 60}h${minutes % 60}"
            else -> "${minutes}m"
        }
    }

    /** `2026-12-31` in [zone]: what the "Ends on" field reads. */
    fun dayText(date: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
        val day = date.atZone(zone).toLocalDate()
        return "%04d-%02d-%02d".format(day.year, day.monthValue, day.dayOfMonth)
    }

    /** A month from today: where "On a date" starts when nothing is typed. */
    fun defaultEndDate(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Instant =
        now.atZone(zone).toLocalDate().plusMonths(1).atStartOfDay(zone).toInstant()

    /** Checks and reads the typed fields into the draft the store saves. */
    fun validate(
        draft: HabitDraft,
        estimateText: String,
        expiryDateText: String,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): HabitFormResult {
        val title = draft.title.trim()
        if (title.isEmpty()) return HabitFormResult.Invalid("A habit needs a name.", HabitField.TITLE)
        val estimate = estimateText.trim()
        val seconds = if (estimate.isEmpty()) {
            null
        } else {
            HabitPolicy.estimateSeconds(estimate)
                ?: return HabitFormResult.Invalid("Write the estimate as 30m, 1h or 1h30.", HabitField.ESTIMATE)
        }
        val expiry = if (draft.expiry is HabitExpiry.On) {
            HabitPolicy.date(expiryDateText, now, zone)?.let { HabitExpiry.On(it) }
                ?: return HabitFormResult.Invalid("Write the end date as 2026-12-31, 3w or a weekday.", HabitField.EXPIRY_DATE)
        } else {
            draft.expiry
        }
        return HabitFormResult.Valid(draft.copy(title = title, estimateSeconds = seconds, expiry = expiry))
    }
}
