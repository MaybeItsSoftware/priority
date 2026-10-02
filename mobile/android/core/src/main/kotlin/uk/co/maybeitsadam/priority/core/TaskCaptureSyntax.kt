package uk.co.maybeitsadam.priority.core

import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * What a typed task says about itself beyond its title. Port of
 * `TaskCaptureSyntax.swift`: `Write the release notes 45m #work @fri !1`.
 *
 * Only trailing words are read, and only while every one of them is a token;
 * the first word is never read as a token.
 */
data class TaskCapture(
    val title: String,
    val estimateSeconds: Int? = null,
    /** The start of the day it is due. */
    val dueAt: Instant? = null,
    val tags: List<String> = emptyList(),
    /** 1 to 4. */
    val priority: Int? = null,
) {
    val hasDetails: Boolean
        get() = estimateSeconds != null || dueAt != null || tags.isNotEmpty() || priority != null

    /** Short labels for what was found: `45m`, `Fri 3 Oct`, `#work`, `!1`. */
    fun detailLabels(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<String> {
        val labels = mutableListOf<String>()
        estimateSeconds?.let { labels += durationLabel(it) }
        dueAt?.let { labels += dueLabel(it, now, zone) }
        labels += tags.map { "#$it" }
        priority?.let { labels += "!$it" }
        return labels
    }

    companion object {
        /** Parses `text` as typed into an add field. */
        fun parse(text: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): TaskCapture {
            val trimmed = text.trim()
            val words = trimmed.split(" ").filter { it.isNotEmpty() }.toMutableList()
            var estimate: Int? = null
            var due: Instant? = null
            var priority: Int? = null
            val tags = mutableListOf<String>()

            scan@ while (words.size > 1) {
                val token = TaskCaptureToken.of(words.last(), now, zone) ?: break
                when (token) {
                    is TaskCaptureToken.Estimate -> {
                        if (estimate != null) break@scan
                        estimate = token.seconds
                    }
                    is TaskCaptureToken.Due -> {
                        if (due != null) break@scan
                        due = token.date
                    }
                    is TaskCaptureToken.Priority -> {
                        if (priority != null) break@scan
                        priority = token.value
                    }
                    is TaskCaptureToken.Tag -> {
                        tags.removeAll { it.equals(token.tag, ignoreCase = true) }
                        tags.add(0, token.tag)
                    }
                }
                words.removeAt(words.size - 1)
            }

            val capture = TaskCapture(trimmed, estimate, due, emptyList(), priority)
            if (!capture.hasDetails && tags.isEmpty()) return capture
            return capture.copy(title = words.joinToString(" "), tags = tags)
        }

        internal fun durationLabel(seconds: Int): String {
            val minutes = maxOf(0, seconds) / 60
            if (minutes < 60) return "${minutes}m"
            val remainder = minutes % 60
            return if (remainder == 0) "${minutes / 60}h" else "${minutes / 60}h ${remainder}m"
        }

        internal fun dueLabel(date: Instant, now: Instant, zone: ZoneId): String {
            val day = date.atZone(zone).toLocalDate()
            val today = now.atZone(zone).toLocalDate()
            if (day == today) return "Today"
            if (day == today.plusDays(1)) return "Tomorrow"
            val pattern = if (day.year == today.year) "EEE d MMM" else "d MMM yyyy"
            return DateTimeFormatter.ofPattern(pattern, Locale.UK).format(day)
        }
    }
}

/** One trailing word the add field understands. */
sealed interface TaskCaptureToken {
    data class Estimate(val seconds: Int) : TaskCaptureToken
    data class Due(val date: Instant) : TaskCaptureToken
    data class Tag(val tag: String) : TaskCaptureToken
    data class Priority(val value: Int) : TaskCaptureToken

    companion object {
        /** Anything past a day is a typo or not an estimate. */
        const val MAXIMUM_ESTIMATE_SECONDS = 24 * 60 * 60

        fun of(word: String, now: Instant, zone: ZoneId): TaskCaptureToken? {
            val lower = word.lowercase()
            estimate(lower)?.let { return Estimate(it) }
            if (lower.startsWith("@")) due(lower.drop(1), now, zone)?.let { return Due(it) }
            tag(word)?.let { return Tag(it) }
            priority(lower)?.let { return Priority(it) }
            return null
        }

        private val estimatePattern =
            Regex("""^(?:(\d+(?:\.\d+)?)(h|hr|hrs|hour|hours)(?:(\d+)(m|min|mins)?)?|(\d+)(m|min|mins|minute|minutes))$""")

        /** `30m`, `90min`, `1h`, `1.5h`, `2hrs`, `1h30m`, `1h30`, each optionally after a `~`. */
        fun estimate(word: String): Int? {
            val body = word.removePrefix("~")
            val match = estimatePattern.find(body) ?: return null
            fun group(i: Int): String? = match.groups[i]?.value
            val minutes: Double
            val hours = group(1)?.toDoubleOrNull()
            if (hours != null) {
                val extra = group(3)?.toDoubleOrNull() ?: 0.0
                if (extra > 0 && Math.rint(hours) != hours) return null
                if (extra >= 60) return null
                minutes = hours * 60 + extra
            } else {
                minutes = group(5)?.toDoubleOrNull() ?: return null
            }
            // Swift's `.rounded()` is half away from zero; values here are positive.
            val seconds = Math.round(minutes * 60).toInt()
            if (seconds <= 0 || seconds > MAXIMUM_ESTIMATE_SECONDS) return null
            return seconds
        }

        private val relative = Regex("""(\d{1,3})([dw])""")
        private val isoDay = Regex("""(\d{4})-(\d{1,2})-(\d{1,2})""")

        /** `today`, `tomorrow`, a weekday (today included), `3d`/`2w`, or `yyyy-mm-dd`. The start of that day. */
        fun due(word: String, now: Instant, zone: ZoneId): Instant? {
            val today = now.atZone(zone).toLocalDate()
            fun days(count: Int): Instant = today.plusDays(count.toLong()).atStartOfDay(zone).toInstant()
            when (word) {
                "today", "tod" -> return days(0)
                "tomorrow", "tmr", "tom" -> return days(1)
            }
            weekdays.firstOrNull { word in it.second }?.first?.let { weekday ->
                val current = calendarWeekday(today)
                return days((weekday - current + 7) % 7)
            }
            relative.matchEntire(word)?.let { m ->
                val count = m.groupValues[1].toIntOrNull()
                if (count != null && count > 0) return days(if (m.groupValues[2] == "w") count * 7 else count)
            }
            isoDay.matchEntire(word)?.let { m ->
                val year = m.groupValues[1].toInt()
                val month = m.groupValues[2].toInt()
                val day = m.groupValues[3].toInt()
                // Reject a date the calendar would roll over rather than filing it in March.
                val date = try {
                    LocalDate.of(year, month, day)
                } catch (_: DateTimeException) {
                    return null
                }
                return date.atStartOfDay(zone).toInstant()
            }
            return null
        }

        private val tagBody = Regex("""\p{L}[\p{L}\p{N}_\-/]*""")

        /** `#word` where the word starts with a letter, so `#1` stays in the title. */
        fun tag(word: String): String? {
            if (word.codePointCount(0, word.length) <= 1 || !word.startsWith("#")) return null
            val body = word.drop(1)
            return if (tagBody.matches(body)) body else null
        }

        /** `!1` to `!4`. */
        fun priority(word: String): Int? {
            if (word.length != 2 || !word.startsWith("!")) return null
            val value = word.drop(1).toIntOrNull() ?: return null
            return if (value in 1..4) value else null
        }

        private val weekdays: List<Pair<Int, Set<String>>> = listOf(
            1 to setOf("sun", "sunday"), 2 to setOf("mon", "monday"), 3 to setOf("tue", "tues", "tuesday"),
            4 to setOf("wed", "wednesday"), 5 to setOf("thu", "thur", "thurs", "thursday"),
            6 to setOf("fri", "friday"), 7 to setOf("sat", "saturday"),
        )
    }
}

