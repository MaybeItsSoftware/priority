package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

// Port of Takt/WorkspaceViewModel+Export.swift. The files are meant to be
// interchangeable with the Mac's, so the JSON is written byte for byte the way
// Foundation's JSONEncoder writes it with `.prettyPrinted, .sortedKeys` and
// `.iso8601` dates: two-space indent, `"key" : value`, keys in order, a nil
// left out, `/` escaped, an empty array as `[`, a blank line, `]`.

/** The two formats the workspace is written out in. */
enum class WorkspaceExportFormat(val title: String, val fileExtension: String, val mimeType: String) {
    MARKDOWN("Markdown", "md", "text/markdown"),
    JSON("JSON", "json", "application/json");

    /** The name the save dialog suggests, as on the Mac. */
    val suggestedFileName: String get() = "Takt workspace.$fileExtension"
}

/** One list and its whole task tree, depth first. */
data class ExportedList(val list: TaskList, val tasks: List<WorkspaceTask>)

/** Every list, archived included, with its whole task tree. */
data class WorkspaceExportSnapshot(val exportedAt: Instant, val workspace: String, val lists: List<ExportedList>)

object WorkspaceExport {
    fun document(snapshot: WorkspaceExportSnapshot, format: WorkspaceExportFormat): String = when (format) {
        WorkspaceExportFormat.JSON -> json(snapshot)
        WorkspaceExportFormat.MARKDOWN -> markdown(snapshot)
    }

    /**
     * Depth first, in the outline's own order, so the JSON reads top to
     * bottom the way the list does. [children] gives a parent's direct
     * children (null for the roots) in sort order.
     */
    fun taskTree(children: (parentTaskId: String?) -> List<WorkspaceTask>): List<WorkspaceTask> {
        fun walk(parent: String?): List<WorkspaceTask> = children(parent).flatMap { listOf(it) + walk(it.id) }
        return walk(null)
    }

    fun markdown(snapshot: WorkspaceExportSnapshot): String {
        val lines = mutableListOf("# ${snapshot.workspace}", "")
        for (entry in snapshot.lists) {
            val suffix = if (entry.list.isArchived) " (archived)" else ""
            lines += "## ${entry.list.name}$suffix"
            lines += ""
            val depth = HashMap<String, Int>()
            for (task in entry.tasks) {
                val level = task.parentTaskId?.let { parent -> depth[parent]?.plus(1) } ?: 0
                depth[task.id] = level
                val box = if (task.status == TaskStatus.OPEN) "[ ]" else "[x]"
                val indent = "  ".repeat(level)
                lines += "$indent- $box ${task.title}"
                for (note in task.notes.split('\n').filter { it.isNotEmpty() }) {
                    lines += "$indent  > $note"
                }
            }
            lines += ""
        }
        return lines.joinToString("\n")
    }

    fun json(snapshot: WorkspaceExportSnapshot): String = JsonWriter().apply {
        obj(
            "exportedAt" to snapshot.exportedAt,
            "lists" to snapshot.lists.map { entry ->
                Obj(listOf("list" to listFields(entry.list), "tasks" to entry.tasks.map(::taskFields)))
            },
            "workspace" to snapshot.workspace,
        )
    }.toString()

    private fun listFields(list: TaskList) = Obj(
        listOf(
            "colorHex" to list.colorHex,
            "completedAt" to list.completedAt,
            "createdAt" to list.createdAt,
            "folderId" to list.folderId,
            "id" to list.id,
            "isArchived" to list.isArchived,
            "name" to list.name,
            "sortOrder" to list.sortOrder,
            "systemRole" to list.systemRole?.raw,
            "updatedAt" to list.updatedAt,
            "visibleRootTaskId" to list.visibleRootTaskId,
            "workspaceId" to list.workspaceId,
        ),
    )

    private fun taskFields(task: WorkspaceTask) = Obj(
        listOf(
            "archivedAt" to task.archivedAt,
            "completedAt" to task.completedAt,
            "createdAt" to task.createdAt,
            "dueAt" to task.dueAt,
            "estimateSeconds" to task.estimateSeconds,
            "id" to task.id,
            "isPromoted" to task.isPromoted,
            "itemKind" to task.itemKind?.raw,
            "listId" to task.listId,
            "notes" to task.notes,
            "parentTaskId" to task.parentTaskId,
            "sortOrder" to task.sortOrder,
            "sourceId" to task.sourceId,
            "sourceSystem" to task.sourceSystem,
            "status" to task.status.raw,
            "title" to task.title,
            "updatedAt" to task.updatedAt,
        ),
    )

    /** An object's fields; sorted on writing, a null field left out. */
    private class Obj(val fields: List<Pair<String, Any?>>)

    private class JsonWriter {
        private val out = StringBuilder()

        fun obj(vararg fields: Pair<String, Any?>) = value(Obj(fields.toList()), 0)

        private fun value(value: Any?, level: Int) {
            when (value) {
                is Obj -> {
                    val present = value.fields.filter { it.second != null }.sortedBy { it.first }
                    if (present.isEmpty()) {
                        out.append("{\n\n").append(indent(level)).append('}')
                        return
                    }
                    out.append("{\n")
                    present.forEachIndexed { index, (key, field) ->
                        out.append(indent(level + 1))
                        string(key)
                        out.append(" : ")
                        value(field, level + 1)
                        if (index < present.lastIndex) out.append(',')
                        out.append('\n')
                    }
                    out.append(indent(level)).append('}')
                }
                is List<*> -> {
                    if (value.isEmpty()) {
                        out.append("[\n\n").append(indent(level)).append(']')
                        return
                    }
                    out.append("[\n")
                    value.forEachIndexed { index, item ->
                        out.append(indent(level + 1))
                        value(item, level + 1)
                        if (index < value.lastIndex) out.append(',')
                        out.append('\n')
                    }
                    out.append(indent(level)).append(']')
                }
                is String -> string(value)
                is Instant -> string(ISO.format(value.truncatedTo(ChronoUnit.SECONDS)))
                is Boolean, is Int, is Long -> out.append(value.toString())
                else -> error("Unsupported JSON value: $value")
            }
        }

        private fun string(text: String) {
            out.append('"')
            for (char in text) {
                when (char) {
                    '"' -> out.append("\\\"")
                    '\\' -> out.append("\\\\")
                    '/' -> out.append("\\/")
                    '\n' -> out.append("\\n")
                    '\r' -> out.append("\\r")
                    '\t' -> out.append("\\t")
                    '\b' -> out.append("\\b")
                    '\u000C' -> out.append("\\f")
                    else -> if (char < ' ') out.append("\\u%04x".format(char.code)) else out.append(char)
                }
            }
            out.append('"')
        }

        private fun indent(level: Int) = "  ".repeat(level)

        override fun toString() = out.toString()
    }

    private val ISO: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
}
