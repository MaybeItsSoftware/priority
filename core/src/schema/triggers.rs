//! The undo journal's and the sync outbox's triggers, generated from a
//! table's current columns.
//!
//! Both kinds name every column of their table, so a migration that adds or
//! removes a column on a journalled or synced table must reinstall them. The
//! captured migrations carry the text as it was at the time; a new migration
//! written here calls [`reinstall`] at the end instead of pasting SQL. The
//! text is the Swift app's `installChangeLogTriggers` and `installSyncTriggers`
//! to the character, which `triggers_match_the_fixture` holds it to.

use rusqlite::Connection;

/// Tables whose rows are the user's work, and their key column. The undo
/// journal covers these. Order matters: it is the order triggers are created.
pub const JOURNALLED_TABLES: &[(&str, &str)] = &[
    ("task_lists", "id"),
    ("list_folders", "id"),
    ("tasks", "id"),
    ("task_metadata", "taskId"),
    ("task_conditions", "id"),
    ("dailies", "id"),
    ("daily_contributions", "id"),
    ("kanban_boards", "id"),
];

/// Every synced table and its key, parents first.
pub const SYNCED_TABLES: &[(&str, &str)] = &[
    ("workspaces", "id"),
    ("list_folders", "id"),
    ("task_lists", "id"),
    ("tasks", "id"),
    ("task_metadata", "taskId"),
    ("task_conditions", "id"),
    ("kanban_boards", "id"),
    ("dailies", "id"),
    ("daily_contributions", "id"),
    ("focus_sessions", "id"),
    ("focus_queue_items", "id"),
    ("focus_work_blocks", "id"),
    ("focus_awards", "id"),
    ("themes", "id"),
    ("preferences", "key"),
];

/// Drops and recreates every journal and outbox trigger for the tables that
/// exist, from their columns as they are now.
pub fn reinstall(connection: &Connection) -> rusqlite::Result<()> {
    for statement in change_log_statements(connection)? {
        connection.execute_batch(&statement)?;
    }
    if table_exists(connection, "sync_outbox")? {
        for statement in sync_statements(connection)? {
            connection.execute_batch(&statement)?;
        }
    }
    Ok(())
}

fn table_exists(connection: &Connection, table: &str) -> rusqlite::Result<bool> {
    connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [table],
        |row| row.get(0),
    )
}

fn columns(connection: &Connection, table: &str) -> rusqlite::Result<Vec<String>> {
    let mut statement =
        connection.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")?;
    statement.query_map([table], |row| row.get(0))?.collect()
}

/// `WorkspaceStore.installChangeLogTriggers`.
pub(crate) fn change_log_statements(connection: &Connection) -> rusqlite::Result<Vec<String>> {
    let guard = "WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0";
    let entry = "INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON)";
    let context = "(SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0)";
    let mut out = Vec::new();
    for (table, key) in JOURNALLED_TABLES {
        if !table_exists(connection, table)? {
            continue;
        }
        let columns = columns(connection, table)?;
        let json = |prefix: &str| {
            let pairs: Vec<String> = columns
                .iter()
                .map(|c| format!("'{c}', {prefix}.\"{c}\""))
                .collect();
            format!("json_object({})", pairs.join(", "))
        };
        for suffix in ["insert", "update", "delete"] {
            out.push(format!(
                "DROP TRIGGER IF EXISTS change_log_{table}_{suffix}"
            ));
        }
        out.push(format!(
            "CREATE TRIGGER change_log_{table}_insert AFTER INSERT ON {table} {guard}\nBEGIN\n  {entry} VALUES ({context}, '{table}', NEW.\"{key}\", 'insert', NULL, {});\nEND",
            json("NEW")
        ));
        out.push(format!(
            "CREATE TRIGGER change_log_{table}_update AFTER UPDATE ON {table} {guard}\nBEGIN\n  {entry} VALUES ({context}, '{table}', NEW.\"{key}\", 'update', {}, {});\nEND",
            json("OLD"),
            json("NEW")
        ));
        out.push(format!(
            "CREATE TRIGGER change_log_{table}_delete AFTER DELETE ON {table} {guard}\nBEGIN\n  {entry} VALUES ({context}, '{table}', OLD.\"{key}\", 'delete', {}, NULL);\nEND",
            json("OLD")
        ));
    }
    Ok(out)
}

/// `WorkspaceStore.installSyncTriggers`.
pub(crate) fn sync_statements(connection: &Connection) -> rusqlite::Result<Vec<String>> {
    let guard = "WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1\n  AND (SELECT applying FROM sync_control WHERE id = 0) = 0";
    let now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";
    let entry = "INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs)";
    let mut out = Vec::new();
    for (table, key) in SYNCED_TABLES {
        if !table_exists(connection, table)? {
            continue;
        }
        let changed: Vec<String> = columns(connection, table)?
            .iter()
            .map(|c| format!("CASE WHEN OLD.\"{c}\" IS NOT NEW.\"{c}\" THEN '{c}' END"))
            .collect();
        let changed = format!("json_array({})", changed.join(", "));
        for suffix in ["insert", "update", "delete"] {
            out.push(format!(
                "DROP TRIGGER IF EXISTS sync_outbox_{table}_{suffix}"
            ));
        }
        out.push(format!(
            "CREATE TRIGGER sync_outbox_{table}_insert AFTER INSERT ON {table} {guard}\nBEGIN {entry} VALUES ('{table}', NEW.\"{key}\", 'insert', NULL, {now}); END"
        ));
        out.push(format!(
            "CREATE TRIGGER sync_outbox_{table}_update AFTER UPDATE ON {table} {guard}\nBEGIN {entry} VALUES ('{table}', NEW.\"{key}\", 'update', {changed}, {now}); END"
        ));
        out.push(format!(
            "CREATE TRIGGER sync_outbox_{table}_delete AFTER DELETE ON {table} {guard}\nBEGIN {entry} VALUES ('{table}', OLD.\"{key}\", 'delete', NULL, {now}); END"
        ));
    }
    Ok(out)
}
