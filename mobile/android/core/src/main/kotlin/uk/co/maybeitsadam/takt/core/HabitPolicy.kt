package uk.co.maybeitsadam.takt.core

import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

// Port of `HabitPolicy.swift`: whether a habit appears on a day, whether it
// has expired, and which board column it lands in. Pure; the data layer's
// `WorkspaceRepositoryHabits.kt` applies it, row for row as the Mac's
// `WorkspaceStore+Habits.swift` does.

/**
 * The board column a habit's appearance lands in. The raw values are the ids
 * of the default board's columns, because that is what a task's
 * `kanbanColumn` stores.
 */
enum class HabitPlacement(val raw: String, val label: String) {
    TODAY("today", "Today"),
    THIS_WEEK("this-week", "This week"),
    WAITING("waiting-on", "Waiting"),
    ;

    companion object {
        fun of(raw: String?): HabitPlacement? = entries.firstOrNull { it.raw == raw }
    }
}

/** When a habit stops appearing. */
sealed interface HabitExpiry {
    /** When the task it was made from is completed: the default for a habit made from a task. */
    data object WhenSourceCompleted : HabitExpiry

    /** From the start of this day onwards. */
    data class On(override val date: Instant) : HabitExpiry

    data object Never : HabitExpiry

    /** The stored `expiryRule` value. */
    val rule: String
        get() = when (this) {
            WhenSourceCompleted -> "source"
            is On -> "date"
            Never -> "never"
        }

    /** The day a date expiry takes effect. */
    val date: Instant? get() = null

    companion object {
        /**
         * Reads the stored pair back. An unknown rule, or a date rule with no
         * date, is [Never]: a habit that silently stopped would be worse than
         * one that keeps coming round until it is archived by hand.
         */
        fun of(rule: String?, date: Instant?): HabitExpiry = when (rule) {
            "source" -> WhenSourceCompleted
            "date" -> date?.let { On(it) } ?: Never
            else -> Never
        }
    }
}

/** A daily's schedule as it is stored: the weekday set (1 = Sunday) and an interval. */
data class HabitSchedule(val weekdays: Set<Int>, val intervalDays: Int?)

/**
 * How often a habit appears, as the form offers it. Stored as the daily's
 * weekday mask and interval ([storage]), so everything that reads a daily's
 * schedule reads a habit's too.
 */
sealed interface HabitFrequency {
    data object Daily : HabitFrequency

    /** On these weekdays, calendar numbering (1 = Sunday). */
    data class Weekdays(val days: Set<Int>) : HabitFrequency

    /** Every N days from the day it was made. */
    data class EveryNDays(val days: Int) : HabitFrequency

    /** Once a week, on the weekday it was made: every seven days. */
    data object Weekly : HabitFrequency

    val storage: HabitSchedule
        get() = when (this) {
            Daily -> HabitSchedule(ALL_DAYS, null)
            is Weekdays -> HabitSchedule(days.ifEmpty { ALL_DAYS }, null)
            is EveryNDays -> HabitSchedule(ALL_DAYS, if (days <= 1) null else minOf(366, days))
            Weekly -> HabitSchedule(ALL_DAYS, WEEKLY_INTERVAL)
        }

    val label: String
        get() = when (this) {
            Daily -> "Every day"
            Weekly -> "Every week"
            is EveryNDays -> if (days == 2) "Every other day" else "Every $days days"
            is Weekdays -> when (days) {
                setOf(2, 3, 4, 5, 6) -> "Weekdays"
                setOf(1, 7) -> "Weekends"
                else -> days.sorted().filter { it in 1..7 }.joinToString(" ") { WEEKDAY_NAMES[it] }
            }
        }

    companion object {
        const val WEEKLY_INTERVAL = 7
        val ALL_DAYS: Set<Int> = (1..7).toSet()
        private val WEEKDAY_NAMES = listOf("", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")

        fun of(weekdays: Set<Int>, intervalDays: Int?): HabitFrequency = when {
            intervalDays != null && intervalDays > 1 ->
                if (intervalDays == WEEKLY_INTERVAL) Weekly else EveryNDays(intervalDays)
            weekdays.isEmpty() || weekdays == ALL_DAYS -> Daily
            else -> Weekdays(weekdays)
        }
    }
}

/** Everything that decides whether a habit shows up on a day, with no database behind it. */
data class HabitRule(
    val weekdays: Set<Int> = HabitFrequency.ALL_DAYS,
    val intervalDays: Int? = null,
    /** A day the interval lands on; also the first day the habit can appear. */
    val anchor: Instant,
    /** Off: a missed appearance is carried until it is done. On: a missed day is a gap. */
    val dropsAtDayEnd: Boolean = true,
    val expiry: HabitExpiry = HabitExpiry.Never,
    val placement: HabitPlacement = HabitPlacement.TODAY,
)

/** One day's appearance of a habit. */
data class HabitAppearance(
    /** The board column it lands in. */
    val column: String,
    /** The start of the scheduled day it belongs to: today, or an earlier day it is still owed for. */
    val dueDay: Instant,
    val isCarriedOver: Boolean,
)

/** What the engine should do with a habit's card: write [column] (null takes it out). */
data class HabitColumnChange(val column: String?)

/** Should a habit appear on a day, has it expired, and where does it land. */
object HabitPolicy {
    /** How far back a carried appearance is looked for. */
    const val CARRY_LOOKBACK_DAYS = 366

    private fun day(instant: Instant, zone: ZoneId): LocalDate = instant.atZone(zone).toLocalDate()

    private fun start(date: LocalDate, zone: ZoneId): Instant = date.atStartOfDay(zone).toInstant()

    private fun isScheduled(rule: HabitRule, target: LocalDate, anchor: LocalDate): Boolean {
        if (target < anchor) return false
        val interval = rule.intervalDays
        if (interval != null && interval > 1) return ChronoUnit.DAYS.between(anchor, target) % interval == 0L
        return calendarWeekday(target) in rule.weekdays.ifEmpty { HabitFrequency.ALL_DAYS }
    }

    /** Whether [day] is one of the habit's scheduled days. Never before the anchor. */
    fun isScheduled(rule: HabitRule, day: Instant, zone: ZoneId = ZoneId.systemDefault()): Boolean =
        isScheduled(rule, day(day, zone), day(rule.anchor, zone))

    /**
     * Whether the habit has stopped for good by [day]. [sourceCompleted] is
     * whether the task it was made from is closed (or gone); only
     * [HabitExpiry.WhenSourceCompleted] consults it.
     */
    fun isExpired(rule: HabitRule, day: Instant, sourceCompleted: Boolean, zone: ZoneId = ZoneId.systemDefault()): Boolean =
        when (val expiry = rule.expiry) {
            HabitExpiry.Never -> false
            HabitExpiry.WhenSourceCompleted -> sourceCompleted
            is HabitExpiry.On -> day(day, zone) >= day(expiry.date, zone)
        }

    /** The start of the most recent scheduled day on or before [day], if any since the anchor. */
    fun lastScheduledDay(rule: HabitRule, onOrBefore: Instant, zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val anchor = day(rule.anchor, zone)
        var cursor = day(onOrBefore, zone)
        repeat(CARRY_LOOKBACK_DAYS + 1) {
            if (cursor < anchor) return null
            if (isScheduled(rule, cursor, anchor)) return start(cursor, zone)
            cursor = cursor.minusDays(1)
        }
        return null
    }

    /**
     * Where the habit stands on [day]: null when it should not be showing.
     * [lastDoneDay] is the latest day it was ticked off, if ever.
     */
    fun appearance(
        rule: HabitRule,
        day: Instant,
        lastDoneDay: Instant?,
        sourceCompleted: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
    ): HabitAppearance? {
        if (isExpired(rule, day, sourceCompleted, zone)) return null
        val today = day(day, zone)
        val lastDone = lastDoneDay?.let { day(it, zone) }
        if (lastDone == today) return null
        if (isScheduled(rule, today, day(rule.anchor, zone))) {
            return HabitAppearance(rule.placement.raw, start(today, zone), isCarriedOver = false)
        }
        if (rule.dropsAtDayEnd) return null
        val owed = lastScheduledDay(rule, day, zone) ?: return null
        if (lastDone != null && start(lastDone, zone) >= owed) return null
        return HabitAppearance(rule.placement.raw, owed, isCarriedOver = true)
    }

    /**
     * The column a habit's task should be in now, given where it is: a
     * change to write, or null to leave it alone. A card the user moved
     * somewhere else by hand is theirs; only the habit's own column, or no
     * column at all, is managed.
     */
    fun reconciledColumn(current: String?, appearance: HabitAppearance?, placement: HabitPlacement): HabitColumnChange? {
        if (appearance != null) return if (current == null) HabitColumnChange(appearance.column) else null
        return if (current == placement.raw) HabitColumnChange(null) else null
    }

    /** `30m`, `1h`, `1h30`, `90` (minutes): the capture bar's estimate syntax plus a bare number, as seconds. */
    fun estimateSeconds(text: String): Int? {
        val word = text.trim().lowercase().replace(" ", "")
        if (word.isEmpty()) return null
        word.toIntOrNull()?.let { minutes ->
            if (minutes > 0) return minOf(minutes * 60, TaskCaptureToken.MAXIMUM_ESTIMATE_SECONDS)
        }
        return TaskCaptureToken.estimate(word)
    }

    /** `2026-12-31`, `3w`, `friday`, `tomorrow`: the capture bar's date words. */
    fun date(text: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val word = text.trim().lowercase()
        if (word.isEmpty()) return null
        return TaskCaptureToken.due(word, now, zone)
    }

    /**
     * The Habits list's id in [workspaceId]: a UUID-shaped SHA-256 of
     * `takt.habits-list:<workspace id>`, as `WaitingFollowUp.followUpTaskId`
     * makes one. The Mac derives the same, so two devices that each make the
     * list before syncing make one row, which sync merges.
     */
    fun habitsListId(workspaceId: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest("takt.habits-list:$workspaceId".toByteArray(Charsets.UTF_8))
        val bytes = digest.copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()
        val hex = bytes.joinToString("") { "%02X".format(it.toInt() and 0xFF) }
        return listOf(0..7, 8..11, 12..15, 16..19, 20..31).joinToString("-") { hex.substring(it) }
    }

    /** The list a new habit goes in. */
    const val HABITS_LIST_NAME = "Habits"
}
