package uk.co.maybeitsadam.takt.data.workspace

import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db

/**
 * `WorkspaceStoreError`, as an exception the UI can switch on by [error].
 * [detail] is the core's own sentence, where it gives one (a refused column).
 */
class WorkspaceStoreException(val error: WorkspaceStoreError, val detail: String? = null) : Exception(detail ?: error.message) {
    /** What to show: the core's sentence, else the case's. */
    val text: String get() = detail ?: error.message
}

enum class WorkspaceStoreError(val message: String) {
    EMPTY_NAME("A workspace item needs a name."),
    DUPLICATE_LEGACY_SOURCE_ID("The legacy task store contains duplicate task IDs."),
    MISSING_TASK("That task is no longer available."),
    MISSING_DAILY("That daily is no longer available."),
    NO_ACTIVE_FOCUS_TASK("This focus session has no active task."),
    MISSING_LIST("That list is no longer available."),
    MISSING_FOLDER("That folder is no longer available."),
    INVALID_TASK_MOVE("A task cannot be moved into itself or one of its subtasks."),
    DEPENDENCY_CYCLE("A task cannot wait on itself, or on a task that already waits on it."),
    INVALID_FOLDER_MOVE("A folder cannot be moved into itself or one of its subfolders."),
    SYSTEM_LIST_IS_PERMANENT("The Inbox cannot be archived or deleted. You can rename it instead."),
    MISSING_FILTER_LIST("That filter list is no longer available."),
    INVALID_FILTER("That filter has a rule this version does not understand."),
    /** A board edit the core refused, a drop a rule column cannot take among them; the core's sentence says why. */
    COLUMN_REFUSED("That column cannot take it."),
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

// The store's static helpers.

internal fun Db.nextOrder(table: String, whereSQL: String, vararg args: Any?): Int =
    int("SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM $table WHERE $whereSQL", *args) ?: 0

/** Swift's `nilIfEmpty` after trimming. */
internal fun String?.trimmedOrNull(): String? = this?.trimmedWhitespace()?.takeIf { it.isNotEmpty() }
