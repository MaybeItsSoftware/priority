package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import java.util.Locale

/**
 * Turns Checkvist's free-text `due` string into an instant, when it names one.
 * Port of `DueDateParsing.swift`.
 *
 * Order matches Swift: ISO 8601 internet date-time (with and without fractional
 * seconds), then ISO full date (read as UTC midnight, as `ISO8601DateFormatter`
 * does), then the POSIX formatters, which read in `zone` (Swift's
 * `DateFormatter` default of the current time zone), then the leading
 * `yyyy-MM-dd` of anything longer.
 */
object DueDateParsing {
    private fun local(pattern: String): DateTimeFormatter =
        DateTimeFormatter.ofPattern(pattern, Locale.US).withResolverStyle(ResolverStyle.STRICT)

    private val dayFormatters = listOf(
        local("uuuu-MM-dd"),
        local("uuuu-M-d"),
        local("uuuu/MM/dd"),
    )
    private val zonedFormatters = listOf(
        local("uuuu-MM-dd HH:mm:ss Z"),
        local("uuuu/MM/dd HH:mm:ss Z"),
    )

    /** Null for an empty string, and for a keyword like `asap` that names no calendar date. */
    fun date(due: String?, zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val raw = due?.trim()
        if (raw.isNullOrEmpty()) return null
        iso(raw)?.let { return it }
        formatted(raw, zone)?.let { return it }
        if (raw.length >= 10) formatted(raw.take(10), zone)?.let { return it }
        return null
    }

    private fun iso(raw: String): Instant? {
        try {
            return OffsetDateTime.parse(raw, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
        } catch (_: DateTimeParseException) {
        }
        if (Regex("""\d{4}-\d{2}-\d{2}""").matches(raw)) {
            try {
                return LocalDate.parse(raw).atStartOfDay(ZoneId.of("UTC")).toInstant()
            } catch (_: DateTimeParseException) {
            }
        }
        return null
    }

    private fun formatted(raw: String, zone: ZoneId): Instant? {
        for (formatter in dayFormatters) {
            try {
                return LocalDate.parse(raw, formatter).atStartOfDay(zone).toInstant()
            } catch (_: DateTimeParseException) {
            }
        }
        for (formatter in zonedFormatters) {
            try {
                return ZonedDateTime.parse(raw, formatter).toInstant()
            } catch (_: DateTimeParseException) {
            }
        }
        return null
    }
}
