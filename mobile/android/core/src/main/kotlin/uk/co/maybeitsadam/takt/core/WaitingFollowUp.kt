package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** A task in the Waiting on column, as the follow-up engine reads it. Port of the Swift `WaitingTaskState`. */
data class WaitingTaskState(
    val taskId: String,
    val title: String,
    val isOpen: Boolean,
    /** The board column it is filed in. Only `waiting-on` is waiting. */
    val column: String?,
    /** Who or what it waits on — "Sam", "Legal", "invoice". */
    val waitingOn: String?,
    /** When to chase it, if ever. */
    val followUpAt: Instant?,
    /**
     * The follow-up already made for this task, if any. Compared with the id
     * the current follow-up time would make, so a follow-up is made once per
     * time set, and setting a new time makes a new one.
     */
    val madeFollowUpTaskId: String?,
)

/** The follow-up task to make: "Follow up with Sam: Contract signed". */
data class WaitingFollowUpPlan(
    /** Deterministic — see [WaitingFollowUp.followUpTaskId]. */
    val taskId: String,
    val sourceTaskId: String,
    val title: String,
    /** The follow-up time, which is the new task's due time. */
    val dueAt: Instant,
)

/**
 * Waiting on: a task filed in the `waiting-on` column can name who or what it
 * waits on and when to chase it. At that time, if it is still open and still
 * waiting, a follow-up task lands in Today, as in `WaitingFollowUp.swift`.
 * The rule, the title and the id are the Rust core's (`core/src/waiting.rs`);
 * the date words a card shows stay here, since every waiting row asks for them.
 *
 * The follow-up's id is derived from the source's id and the follow-up time,
 * so the Mac and this device, both noticing the same follow-up, make the same
 * row, and sync merges the two into one rather than leaving a pair.
 */
object WaitingFollowUp {
    /** The board column a waiting task is filed in. */
    const val WAITING_COLUMN_ID = "waiting-on"

    /** Where the follow-up lands. */
    const val FOLLOW_UP_COLUMN_ID = "today"

    /** The longest tag kept: it is a chip, not a note. */
    const val MAXIMUM_TAG_LENGTH = 40

    /**
     * The follow-up to make for [task] at [now], or null.
     *
     * Null unless the task is open, still in `waiting-on`, has a follow-up time
     * at or before [now], and has not already had the follow-up for that time
     * made. A task that left waiting before its time never gets one.
     */
    fun dueFollowUp(task: WaitingTaskState, now: Instant): WaitingFollowUpPlan? {
        val followUpAt = task.followUpAt ?: return null
        val state = uniffi.takt_core.WaitingState(
            taskId = task.taskId,
            title = task.title,
            isOpen = task.isOpen,
            column = task.column,
            waitingOn = task.waitingOn,
            followUpAtMs = followUpAt.toEpochMilli(),
            madeFollowUpTaskId = task.madeFollowUpTaskId,
        )
        val plan = uniffi.takt_core.waitingDueFollowUp(state, now.toEpochMilli()) ?: return null
        return WaitingFollowUpPlan(plan.taskId, plan.sourceTaskId, plan.title, followUpAt)
    }

    /** "Follow up with Sam: Contract signed", or "Follow up: Contract signed" when nothing is named. */
    fun title(title: String, waitingOn: String?): String = uniffi.takt_core.waitingFollowUpTitle(title, waitingOn)

    /**
     * A tag trimmed and clipped to [MAXIMUM_TAG_LENGTH] characters, as Swift
     * counts them (grapheme clusters, so an emoji is not split), or null when
     * there is nothing left.
     */
    fun normalizedTag(text: String?): String? = uniffi.takt_core.waitingNormalizedTag(text)

    /**
     * A UUID-shaped id from SHA-256 of `takt.follow-up:<source>:<epoch seconds>`,
     * uppercased as Swift's `UUID().uuidString` writes them, with the version 5
     * and RFC 4122 variant bits set, made by the Rust core for every client.
     */
    fun followUpTaskId(sourceTaskId: String, followUpAt: Instant): String =
        // `toEpochMilli` is the floor, so the whole second is the one Swift's `.rounded(.down)` reads.
        uniffi.takt_core.waitingFollowUpTaskId(sourceTaskId, followUpAt.toEpochMilli())

    /** `↻ Thu 14:00` — the follow-up time as a card shows it. */
    fun label(date: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String =
        "↻ " + dateTimeText(date, now.atZone(zone).toLocalDate(), zone)

    /** [label] against a [today] the caller already has, as row shaping does. */
    fun label(date: Instant, today: LocalDate, zone: ZoneId): String = "↻ " + dateTimeText(date, today, zone)

    /** `Today 14:00`, `Tomorrow 09:00`, `Thu 14:00`, `8 Oct 14:00`, `8 Oct 2027 14:00`. */
    fun dateTimeText(date: Instant, today: LocalDate, zone: ZoneId): String {
        val local = LocalDateTime.ofInstant(date, zone)
        val time = "%02d:%02d".format(local.hour, local.minute)
        val day = local.toLocalDate()
        val prefix = when (ChronoUnit.DAYS.between(today, day)) {
            0L -> "Today"
            1L -> "Tomorrow"
            in 2L..6L -> weekday.format(day)
            else -> (if (day.year == today.year) dayMonth else dayMonthYear).format(day)
        }
        return "$prefix $time"
    }

    /** `2026-10-08 14:00` — what a follow-up field reads back. */
    fun editableText(date: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
        val local = LocalDateTime.ofInstant(date, zone)
        return "%04d-%02d-%02d %02d:%02d".format(local.year, local.monthValue, local.dayOfMonth, local.hour, local.minute)
    }

    private val weekday = DateTimeFormatter.ofPattern("EEE", Locale.UK)
    private val dayMonth = DateTimeFormatter.ofPattern("d MMM", Locale.UK)
    private val dayMonthYear = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.UK)
}
