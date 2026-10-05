package uk.co.maybeitsadam.takt.data.db

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * Dates exactly as GRDB writes them: `yyyy-MM-dd HH:mm:ss.SSS` in UTC, so the
 * Swift app, the CLI and this module compare the same text in SQL.
 */
object SqlDates {
    private val writer = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS").withZone(ZoneOffset.UTC)

    fun format(instant: Instant): String = writer.format(instant)

    /** GRDB keeps milliseconds; anything finer would not survive a round trip. */
    fun truncate(instant: Instant): Instant = instant.truncatedTo(ChronoUnit.MILLIS)

    /**
     * Reads every shape GRDB accepts for a date column: `yyyy-MM-dd`,
     * `yyyy-MM-dd HH:mm[:ss[.SSS]]` with a space or `T`, optionally zoned,
     * and a bare number of seconds since 1970.
     */
    fun parse(text: String): Instant? {
        val value = text.trim()
        if (value.isEmpty()) return null
        value.toDoubleOrNull()?.let { seconds ->
            return Instant.ofEpochMilli(Math.round(seconds * 1000))
        }
        if (value.length == 10) {
            return runCatching { LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC) }.getOrNull()
        }
        val normalised = value.replace(' ', 'T')
        runCatching { return OffsetDateTime.parse(normalised).toInstant() }
        if (normalised.endsWith("Z")) {
            runCatching { return LocalDateTime.parse(normalised.dropLast(1)).toInstant(ZoneOffset.UTC) }
        }
        return runCatching { LocalDateTime.parse(normalised).toInstant(ZoneOffset.UTC) }.getOrNull()
    }
}
