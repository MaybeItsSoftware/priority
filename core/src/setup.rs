//! Writes that set a workspace up and keep its fixtures in place, and the
//! themes and preferences rows that sync between devices. None of these is an
//! undo step: nobody asked for them, or (themes, preferences) they are
//! settings rather than work.

use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::lists::new_id;
use crate::time::stored;

/// The workspace, made on first launch with its Inbox and starting
/// conditions; an existing one gets its Inbox back if it lost it. Returns the
/// workspace's id. `WorkspaceStore.bootstrapIfNeeded`.
pub fn bootstrap(transaction: &Transaction, now_ms: i64) -> Result<String, CoreError> {
    let existing: Option<String> = transaction
        .query_row("SELECT id FROM workspaces LIMIT 1", [], |row| row.get(0))
        .optional()?;
    if let Some(id) = existing {
        ensure_inbox(transaction, &id, now_ms)?;
        return Ok(id);
    }
    let id = new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES (?1, 'My Workspace', ?2, ?2)",
        params![id, now],
    )?;
    ensure_inbox(transaction, &id, now_ms)?;
    crate::schema::data::seed_conditions(transaction, &id, &now)?;
    Ok(id)
}

/// The workspace's Inbox, made if it is missing and brought back into view if
/// it was archived; returns its id. Quick capture always has somewhere to
/// land. `WorkspaceStore.ensureInbox`.
pub fn ensure_inbox(
    transaction: &Transaction,
    workspace_id: &str,
    now_ms: i64,
) -> Result<String, CoreError> {
    let existing: Option<(String, bool)> = transaction
        .query_row(
            "SELECT id, isArchived FROM task_lists WHERE workspaceId = ?1 AND systemRole = 'inbox'",
            [workspace_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((id, archived)) = existing {
        if archived {
            transaction.execute(
                "UPDATE task_lists SET isArchived = 0, updatedAt = ?1 WHERE id = ?2",
                params![stored(now_ms), id],
            )?;
        }
        return Ok(id);
    }
    let order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?1 AND folderId IS NULL",
        [workspace_id],
        |row| row.get(0),
    )?;
    let id = new_id();
    transaction.execute(
        "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived,
                                 createdAt, updatedAt, systemRole, visibleRootTaskId, completedAt)
         VALUES (?1, ?2, NULL, 'Inbox', NULL, ?3, 0, ?4, ?4, 'inbox', NULL, NULL)",
        params![id, workspace_id, order, stored(now_ms)],
    )?;
    Ok(id)
}

/// Stores a theme's JSON. False, writing nothing, when the row already holds
/// exactly that text. `WorkspaceStore.upsertTheme`.
pub fn upsert_theme(
    transaction: &Transaction,
    id: &str,
    json: &str,
    now_ms: i64,
) -> Result<bool, CoreError> {
    let current: Option<String> = transaction
        .query_row("SELECT json FROM themes WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .optional()?;
    match current.as_deref() {
        Some(current) if current == json => Ok(false),
        Some(_) => {
            transaction.execute(
                "UPDATE themes SET json = ?1, updatedAt = ?2 WHERE id = ?3",
                params![json, stored(now_ms), id],
            )?;
            Ok(true)
        }
        None => {
            transaction.execute(
                "INSERT INTO themes (id, json, updatedAt) VALUES (?1, ?2, ?3)",
                params![id, json, stored(now_ms)],
            )?;
            Ok(true)
        }
    }
}

/// Removes a theme; false when there was none. `WorkspaceStore.deleteTheme`.
pub fn delete_theme(transaction: &Transaction, id: &str) -> Result<bool, CoreError> {
    Ok(transaction.execute("DELETE FROM themes WHERE id = ?1", [id])? > 0)
}

/// Stores a preference. A `None` value is kept as a row holding null rather
/// than deleted, so clearing a choice syncs as an edit. False, writing
/// nothing, when the row already holds that value.
/// `WorkspaceStore.setPreference`.
pub fn set_preference(
    transaction: &Transaction,
    key: &str,
    value: Option<&str>,
    now_ms: i64,
) -> Result<bool, CoreError> {
    let existing: Option<Option<String>> = transaction
        .query_row(
            "SELECT value FROM preferences WHERE key = ?1",
            [key],
            |row| row.get(0),
        )
        .optional()?;
    match existing {
        Some(current) if current.as_deref() == value => Ok(false),
        Some(_) => {
            transaction.execute(
                "UPDATE preferences SET value = ?1, updatedAt = ?2 WHERE key = ?3",
                params![value, stored(now_ms), key],
            )?;
            Ok(true)
        }
        None => {
            transaction.execute(
                "INSERT INTO preferences (key, value, updatedAt) VALUES (?1, ?2, ?3)",
                params![key, value, stored(now_ms)],
            )?;
            Ok(true)
        }
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;
    use crate::schema::migrate;

    fn database() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("PRAGMA foreign_keys = ON")
            .unwrap();
        migrate(&mut connection).unwrap();
        connection
    }

    fn count(connection: &Connection, sql: &str) -> i64 {
        connection.query_row(sql, [], |row| row.get(0)).unwrap()
    }

    #[test]
    fn bootstrapping_makes_one_workspace_with_its_inbox_and_conditions_once() {
        let mut connection = database();
        let tx = connection.transaction().unwrap();
        let first = bootstrap(&tx, 1).unwrap();
        let again = bootstrap(&tx, 2).unwrap();
        tx.commit().unwrap();
        assert_eq!(first, again);
        assert_eq!(count(&connection, "SELECT COUNT(*) FROM workspaces"), 1);
        assert_eq!(
            count(
                &connection,
                "SELECT COUNT(*) FROM task_lists WHERE systemRole = 'inbox'"
            ),
            1
        );
        assert_eq!(
            count(&connection, "SELECT COUNT(*) FROM task_conditions"),
            4
        );
        assert_eq!(count(&connection, "SELECT COUNT(*) FROM change_log"), 0);

        connection
            .execute("UPDATE task_lists SET isArchived = 1", [])
            .unwrap();
        let tx = connection.transaction().unwrap();
        bootstrap(&tx, 3).unwrap();
        tx.commit().unwrap();
        assert_eq!(
            count(
                &connection,
                "SELECT isArchived FROM task_lists WHERE systemRole = 'inbox'"
            ),
            0
        );
    }

    #[test]
    fn themes_and_preferences_write_only_what_changed() {
        let mut connection = database();
        let tx = connection.transaction().unwrap();
        assert!(upsert_theme(&tx, "dusk", "{}", 1).unwrap());
        assert!(!upsert_theme(&tx, "dusk", "{}", 2).unwrap());
        assert!(upsert_theme(&tx, "dusk", r#"{"a":1}"#, 3).unwrap());
        assert!(delete_theme(&tx, "dusk").unwrap());
        assert!(!delete_theme(&tx, "dusk").unwrap());

        assert!(set_preference(&tx, "theme", Some("dusk"), 1).unwrap());
        assert!(!set_preference(&tx, "theme", Some("dusk"), 2).unwrap());
        assert!(set_preference(&tx, "theme", None, 3).unwrap());
        assert!(!set_preference(&tx, "theme", None, 4).unwrap());
        tx.commit().unwrap();
        let value: Option<String> = connection
            .query_row(
                "SELECT value FROM preferences WHERE key = 'theme'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(value, None);
    }
}
