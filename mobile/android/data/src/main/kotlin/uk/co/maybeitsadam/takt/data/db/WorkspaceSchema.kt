package uk.co.maybeitsadam.takt.data.db

/**
 * The tables the sync outbox and the undo journal cover, and their keys.
 *
 * The schema itself, and every migration that produced it, is the Rust core's
 * (`core/src/schema`, step two of docs/rust-core-migration.md):
 * [WorkspaceDatabase.open] calls it before opening the file. These lists are
 * what the repository and the sync store read at runtime; they match the
 * triggers the core installs.
 */
object WorkspaceSchema {
    /** Tables whose rows are the user's work, keyed by column (undo journal). Same order as Swift. */
    val journalledTables: List<Pair<String, String>> = listOf(
        "task_lists" to "id",
        "list_folders" to "id",
        "tasks" to "id",
        "task_metadata" to "taskId",
        "task_conditions" to "id",
        "dailies" to "id",
        "daily_contributions" to "id",
        "kanban_boards" to "id",
    )

    /** Every synced table and its key, parents first. */
    val syncedTables: List<Pair<String, String>> = listOf(
        "workspaces" to "id",
        "list_folders" to "id",
        "task_lists" to "id",
        "tasks" to "id",
        "task_metadata" to "taskId",
        "task_conditions" to "id",
        "kanban_boards" to "id",
        "dailies" to "id",
        "daily_contributions" to "id",
        "focus_sessions" to "id",
        "focus_queue_items" to "id",
        "focus_work_blocks" to "id",
        "focus_awards" to "id",
        // `v18_themes_and_preferences`. No foreign keys, so their place is free.
        "themes" to "id",
        "preferences" to "key",
    )

    fun syncKey(table: String): String? = syncedTables.firstOrNull { it.first == table }?.second
    fun journalKey(table: String): String? = journalledTables.firstOrNull { it.first == table }?.second
}
