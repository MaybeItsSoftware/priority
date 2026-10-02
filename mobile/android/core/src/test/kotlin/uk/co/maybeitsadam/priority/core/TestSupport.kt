package uk.co.maybeitsadam.priority.core

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

val UTC: ZoneId = ZoneId.of("UTC")

fun date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, zone: ZoneId = UTC): Instant =
    LocalDateTime.of(year, month, day, hour, minute).atZone(zone).toInstant()

fun epoch(seconds: Long): Instant = Instant.ofEpochSecond(seconds)

fun Instant.plusSecondsD(seconds: Double): Instant = plusNanos(Math.round(seconds * 1_000_000_000))

fun startOfDay(instant: Instant, zone: ZoneId = UTC): Instant = instant.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant()

fun task(
    id: String,
    title: String = id,
    listId: String = "list",
    parent: String? = null,
    status: TaskStatus = TaskStatus.OPEN,
    sortOrder: Int = 0,
    kind: WorkspaceItemKind? = null,
    archivedAt: Instant? = null,
): WorkspaceTask = WorkspaceTask(
    id = id, listId = listId, parentTaskId = parent, title = title, notes = "", status = status,
    sortOrder = sortOrder, dueAt = null, estimateSeconds = null, sourceSystem = null, sourceId = null,
    itemKind = kind, isPromoted = null, archivedAt = archivedAt, completedAt = null,
    createdAt = epoch(0), updatedAt = epoch(0),
)
