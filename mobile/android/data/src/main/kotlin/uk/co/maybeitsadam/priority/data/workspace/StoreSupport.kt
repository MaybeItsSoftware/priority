package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import uk.co.maybeitsadam.priority.core.ListFolder
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.data.db.Db

/** `WorkspaceStoreError`, as an exception the UI can switch on by [error]. */
class WorkspaceStoreException(val error: WorkspaceStoreError) : Exception(error.message)

enum class WorkspaceStoreError(val message: String) {
    EMPTY_NAME("A workspace item needs a name."),
    DUPLICATE_LEGACY_SOURCE_ID("The legacy task store contains duplicate task IDs."),
    MISSING_TASK("That task is no longer available."),
    MISSING_DAILY("That daily is no longer available."),
    NO_ACTIVE_FOCUS_TASK("This focus session has no active task."),
    MISSING_LIST("That list is no longer available."),
    MISSING_FOLDER("That folder is no longer available."),
    INVALID_TASK_MOVE("A task cannot be moved into itself or one of its subtasks."),
    INVALID_FOLDER_MOVE("A folder cannot be moved into itself or one of its subfolders."),
    SYSTEM_LIST_IS_PERMANENT("The Inbox cannot be archived or deleted. You can rename it instead."),
    ;

    fun exception() = WorkspaceStoreException(this)
}

internal fun fail(error: WorkspaceStoreError): Nothing = throw error.exception()

/** Identifiers as GRDB's `UUID().uuidString` writes them: uppercase. */
internal fun newId(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
internal fun String.trimmedWhitespace(): String = trim { it.isWhitespace() }

internal fun nonEmptyName(raw: String): String {
    val value = raw.trimmedWhitespace()
    if (value.isEmpty()) fail(WorkspaceStoreError.EMPTY_NAME)
    return value
}

/** Trimmed, non-empty, de-duplicated case-insensitively, first spelling kept. */
internal fun normalizedStrings(values: List<String>): List<String> {
    val seen = HashSet<String>()
    return values.mapNotNull { value ->
        val trimmed = value.trimmedWhitespace()
        if (trimmed.isEmpty() || !seen.add(trimmed.lowercase(Locale.getDefault()))) null else trimmed
    }
}

internal fun decodeStringArray(json: String): List<String> {
    val values = runCatching {
        (Json.parseToJsonElement(json) as JsonArray).map { element ->
            val primitive = element as JsonPrimitive
            require(primitive.isString)
            primitive.content
        }
    }.getOrNull() ?: return emptyList()
    return normalizedStrings(values)
}

/** A JSON string literal as Foundation's `JSONEncoder` writes one (it escapes `/`). */
internal fun jsonString(value: String): String = buildString {
    append('"')
    for (c in value) {
        when (c) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '/' -> append("\\/")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
    }
    append('"')
}

internal fun encodeStringArray(values: List<String>): String = values.joinToString(",", "[", "]") { jsonString(it) }

// The store's static helpers.

internal fun Db.nextOrder(table: String, whereSQL: String, vararg args: Any?): Int =
    int("SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM $table WHERE $whereSQL", *args) ?: 0

internal fun Db.persistTaskOrder(tasks: List<WorkspaceTask>, now: Instant) {
    tasks.forEachIndexed { index, task -> update(task.copy(sortOrder = index, updatedAt = now)) }
}

internal fun Db.persistListOrder(lists: List<TaskList>, now: Instant) {
    lists.forEachIndexed { index, list -> update(list.copy(sortOrder = index, updatedAt = now)) }
}

internal fun Db.persistFolderOrder(folders: List<ListFolder>, now: Instant) {
    folders.forEachIndexed { index, folder -> update(folder.copy(sortOrder = index, updatedAt = now)) }
}

internal fun Db.taskDescendantIDs(taskId: String): Set<String> = descendantIDs("tasks", "parentTaskId", taskId)

internal fun Db.folderDescendantIDs(folderId: String): Set<String> =
    descendantIDs("list_folders", "parentFolderId", folderId)

private fun Db.descendantIDs(table: String, parentColumn: String, rootId: String): Set<String> {
    val descendants = LinkedHashSet<String>()
    var frontier = listOf(rootId)
    while (frontier.isNotEmpty()) {
        val children = frontier.chunked(500).flatMap { chunk ->
            strings(
                "SELECT id FROM $table WHERE $parentColumn IN (${chunk.joinToString(",") { "?" }})",
                *chunk.toTypedArray(),
            )
        }
        frontier = children.filter { descendants.add(it) }
    }
    return descendants
}

/** Swift's `nilIfEmpty` after trimming. */
internal fun String?.trimmedOrNull(): String? = this?.trimmedWhitespace()?.takeIf { it.isNotEmpty() }
