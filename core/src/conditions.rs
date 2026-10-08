//! Writes to conditions: the places and circumstances a task can require
//! ("Home", "Campus", "Floor space") before it is worth starting.

use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::lists::new_id;
use crate::time::{non_empty_name, stored};

/// Creates a condition in a workspace and returns its id. Replaces
/// `WorkspaceStore.createCondition` and `WorkspaceRepository.createCondition`.
pub fn create_condition(
    transaction: &Transaction,
    workspace_id: &str,
    name: &str,
    is_location: bool,
    now_ms: i64,
) -> Result<String, CoreError> {
    let name = non_empty_name(name)?;
    let workspace_exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?1)",
        [workspace_id],
        |row| row.get(0),
    )?;
    if !workspace_exists {
        return Err(CoreError::InvalidCondition);
    }
    let id = new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO task_conditions (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt)
         VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)",
        params![id, workspace_id, name, is_location, now],
    )?;
    Ok(id)
}

/// Saves a condition's name, whether it is a place, and whether it is
/// archived. Saving what is already there records nothing. Replaces
/// `WorkspaceStore.saveCondition` and `WorkspaceRepository.saveCondition`.
pub fn save_condition(
    transaction: &Transaction,
    id: &str,
    name: &str,
    is_location: bool,
    is_archived: bool,
    now_ms: i64,
) -> Result<(), CoreError> {
    let name = non_empty_name(name)?;
    let current: (String, bool, bool) = transaction
        .query_row(
            "SELECT name, isLocation, isArchived FROM task_conditions WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?
        .ok_or(CoreError::InvalidCondition)?;
    if current == (name.clone(), is_location, is_archived) {
        return Ok(());
    }
    transaction.execute(
        "UPDATE task_conditions SET name = ?1, isLocation = ?2, isArchived = ?3, updatedAt = ?4 WHERE id = ?5",
        params![name, is_location, is_archived, stored(now_ms), id],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;
    use crate::journal::{journalled, undo};
    use crate::schema::migrate;

    fn workspace() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("PRAGMA foreign_keys = ON")
            .unwrap();
        migrate(&mut connection).unwrap();
        connection
            .execute_batch(
                "INSERT INTO workspaces (id, name, createdAt, updatedAt)
                 VALUES ('w', 'Mine', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');",
            )
            .unwrap();
        connection
    }

    fn row(connection: &Connection, id: &str) -> (String, bool, bool) {
        connection
            .query_row(
                "SELECT name, isLocation, isArchived FROM task_conditions WHERE id = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap()
    }

    #[test]
    fn a_condition_is_created_saved_and_undone() {
        let mut connection = workspace();
        let id = journalled(&mut connection, "New Condition", |tx| {
            create_condition(tx, "w", " Library ", true, 1_700_000_000_000)
        })
        .unwrap();
        assert_eq!(row(&connection, &id), ("Library".into(), true, false));

        journalled(&mut connection, "Edit Condition", |tx| {
            save_condition(tx, &id, "Quiet room", false, true, 1_700_000_000_000)
        })
        .unwrap();
        assert_eq!(row(&connection, &id), ("Quiet room".into(), false, true));
        let steps = |c: &Connection| -> i64 {
            c.query_row("SELECT COUNT(DISTINCT groupId) FROM change_log", [], |r| {
                r.get(0)
            })
            .unwrap()
        };
        let before = steps(&connection);
        journalled(&mut connection, "Edit Condition", |tx| {
            save_condition(tx, &id, "Quiet room", false, true, 1_700_000_000_000)
        })
        .unwrap();
        assert_eq!(steps(&connection), before);

        assert_eq!(
            undo(&mut connection).unwrap().as_deref(),
            Some("Edit Condition")
        );
        assert_eq!(row(&connection, &id), ("Library".into(), true, false));
    }

    #[test]
    fn a_condition_needs_a_workspace_a_name_and_to_exist() {
        let mut connection = workspace();
        assert!(matches!(
            journalled(&mut connection, "New Condition", |tx| create_condition(
                tx, "nope", "X", false, 0
            )),
            Err(CoreError::InvalidCondition)
        ));
        assert!(matches!(
            journalled(&mut connection, "New Condition", |tx| create_condition(
                tx, "w", "  ", false, 0
            )),
            Err(CoreError::EmptyName)
        ));
        assert!(matches!(
            journalled(&mut connection, "Edit Condition", |tx| save_condition(
                tx, "nope", "X", false, false, 0
            )),
            Err(CoreError::InvalidCondition)
        ));
    }
}
