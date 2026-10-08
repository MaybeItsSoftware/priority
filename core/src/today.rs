//! Writes to Today's focus order: the ranks a user pins tasks at, which the
//! next-up ranking defers to until they are cleared.

use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::time::stored;

/// Gives each task in `ordered_task_ids` its position as its focus rank,
/// writing only the tasks whose rank changes. Replaces
/// `WorkspaceStore.arrangeDay` and `WorkspaceRepository.arrangeDay`.
pub fn arrange_day(
    transaction: &Transaction,
    ordered_task_ids: &[String],
    now_ms: i64,
) -> Result<(), CoreError> {
    for (rank, task_id) in ordered_task_ids.iter().enumerate() {
        require_task(transaction, task_id)?;
        let current: Option<Option<i64>> = transaction
            .query_row(
                "SELECT focusRank FROM task_metadata WHERE taskId = ?1",
                [task_id],
                |row| row.get(0),
            )
            .optional()?;
        if current.flatten() == Some(rank as i64) {
            continue;
        }
        set_rank(transaction, task_id, Some(rank as i64), now_ms)?;
    }
    Ok(())
}

/// Pins a task at `index` (zero or more) in the focus order. Replaces
/// `WorkspaceStore.pinTask` and `WorkspaceRepository.pinTask`.
pub fn pin_task(
    transaction: &Transaction,
    task_id: &str,
    index: i64,
    now_ms: i64,
) -> Result<(), CoreError> {
    require_task(transaction, task_id)?;
    set_rank(transaction, task_id, Some(index.max(0)), now_ms)
}

/// Puts tasks in Today's column or takes them out of it; taking one out also
/// drops its place in the day. Tasks already where they are asked to be are
/// left alone. Replaces `WorkspaceStore.setPlannedForToday` and its Kotlin
/// copy.
pub fn set_planned_for_today(
    transaction: &Transaction,
    planned: bool,
    task_ids: &[String],
    now_ms: i64,
) -> Result<(), CoreError> {
    let now = stored(now_ms);
    for task_id in task_ids {
        require_task(transaction, task_id)?;
        let column: Option<String> = transaction
            .query_row(
                "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
                [task_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if (column.as_deref() == Some("today")) == planned {
            continue;
        }
        transaction.execute(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
             VALUES (?1, '[]', '[]', ?2, ?3)
             ON CONFLICT(taskId) DO UPDATE SET
               kanbanColumn = excluded.kanbanColumn,
               focusRank = CASE WHEN excluded.kanbanColumn IS NULL THEN NULL ELSE focusRank END,
               updatedAt = excluded.updatedAt",
            params![task_id, planned.then_some("today"), now],
        )?;
    }
    Ok(())
}

/// Releases one task back to the ranking. A task with no metadata has no
/// rank to release. Replaces `WorkspaceStore.unpinTask` and its Kotlin copy.
pub fn unpin_task(transaction: &Transaction, task_id: &str, now_ms: i64) -> Result<(), CoreError> {
    transaction.execute(
        "UPDATE task_metadata SET focusRank = NULL, updatedAt = ?1 WHERE taskId = ?2",
        params![stored(now_ms), task_id],
    )?;
    Ok(())
}

/// Hands the whole ladder back to the ranking. Replaces
/// `WorkspaceStore.clearFocusOrder` and its Kotlin copy.
pub fn clear_focus_order(transaction: &Transaction, now_ms: i64) -> Result<(), CoreError> {
    transaction.execute(
        "UPDATE task_metadata SET focusRank = NULL, updatedAt = ?1 WHERE focusRank IS NOT NULL",
        [stored(now_ms)],
    )?;
    Ok(())
}

fn require_task(transaction: &Transaction, task_id: &str) -> Result<(), CoreError> {
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)",
        [task_id],
        |row| row.get(0),
    )?;
    if exists {
        Ok(())
    } else {
        Err(CoreError::MissingTask {
            id: task_id.to_string(),
        })
    }
}

/// Sets a task's focus rank, creating its metadata row as both clients did
/// when it had none.
fn set_rank(
    transaction: &Transaction,
    task_id: &str,
    rank: Option<i64>,
    now_ms: i64,
) -> Result<(), CoreError> {
    transaction.execute(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, focusRank, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3)
         ON CONFLICT(taskId) DO UPDATE SET focusRank = excluded.focusRank, updatedAt = excluded.updatedAt",
        params![task_id, rank, stored(now_ms)],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;
    use crate::journal::{journalled, undo};
    use crate::schema::migrate;

    const T: &str = "2024-01-01 00:00:00.000";

    fn workspace() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("PRAGMA foreign_keys = ON")
            .unwrap();
        migrate(&mut connection).unwrap();
        connection
            .execute_batch(&format!(
                "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
                 INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
                   VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
                 INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt) VALUES
                   ('a', 'l', 'A', 0, '{T}', '{T}'), ('b', 'l', 'B', 1, '{T}', '{T}'), ('c', 'l', 'C', 2, '{T}', '{T}');
                 INSERT INTO task_metadata (taskId, focusRank, updatedAt) VALUES ('b', 1, '{T}');"
            ))
            .unwrap();
        connection
    }

    fn ranks(connection: &Connection) -> Vec<(String, Option<i64>)> {
        let mut statement = connection
            .prepare("SELECT t.id, m.focusRank FROM tasks t LEFT JOIN task_metadata m ON m.taskId = t.id ORDER BY t.id")
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn entries(connection: &Connection) -> i64 {
        connection
            .query_row("SELECT COUNT(*) FROM change_log", [], |row| row.get(0))
            .unwrap()
    }

    #[test]
    fn arranging_the_day_writes_only_the_ranks_that_change() {
        let mut connection = workspace();
        let order = ["c".to_string(), "b".to_string(), "a".to_string()];
        journalled(&mut connection, "Reorder Today", |tx| {
            arrange_day(tx, &order, 1)
        })
        .unwrap();
        assert_eq!(
            ranks(&connection),
            [
                ("a".into(), Some(2)),
                ("b".into(), Some(1)),
                ("c".into(), Some(0))
            ]
        );
        assert_eq!(entries(&connection), 2);
        let missing = ["a".to_string(), "nope".to_string()];
        assert!(matches!(
            journalled(&mut connection, "Reorder Today", |tx| arrange_day(
                tx, &missing, 1
            )),
            Err(CoreError::MissingTask { .. })
        ));
    }

    #[test]
    fn planning_for_today_moves_only_what_needs_moving_and_leaving_drops_the_rank() {
        let mut connection = workspace();
        let both = ["a".to_string(), "b".to_string()];
        journalled(&mut connection, "Plan for Today", |tx| {
            set_planned_for_today(tx, true, &both, 1)
        })
        .unwrap();
        let column = |c: &Connection, id: &str| -> (Option<String>, Option<i64>) {
            c.query_row(
                "SELECT kanbanColumn, focusRank FROM task_metadata WHERE taskId = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap()
        };
        assert_eq!(column(&connection, "a"), (Some("today".into()), None));
        assert_eq!(column(&connection, "b"), (Some("today".into()), Some(1)));
        let before = entries(&connection);
        journalled(&mut connection, "Plan for Today", |tx| {
            set_planned_for_today(tx, true, &both, 1)
        })
        .unwrap();
        assert_eq!(entries(&connection), before);
        journalled(&mut connection, "Take off Today", |tx| {
            set_planned_for_today(tx, false, &both[1..], 1)
        })
        .unwrap();
        assert_eq!(column(&connection, "b"), (None, None));
    }

    #[test]
    fn pinning_unpinning_and_clearing_the_ladder() {
        let mut connection = workspace();
        journalled(&mut connection, "Pin Task", |tx| pin_task(tx, "a", -3, 1)).unwrap();
        journalled(&mut connection, "Pin Task", |tx| pin_task(tx, "c", 4, 1)).unwrap();
        assert_eq!(
            ranks(&connection),
            [
                ("a".into(), Some(0)),
                ("b".into(), Some(1)),
                ("c".into(), Some(4))
            ]
        );
        journalled(&mut connection, "Unpin Task", |tx| unpin_task(tx, "c", 1)).unwrap();
        assert_eq!(ranks(&connection)[2], ("c".into(), None));
        journalled(&mut connection, "Clear Focus Order", |tx| {
            clear_focus_order(tx, 1)
        })
        .unwrap();
        assert!(ranks(&connection).iter().all(|(_, rank)| rank.is_none()));
        assert_eq!(
            undo(&mut connection).unwrap().as_deref(),
            Some("Clear Focus Order")
        );
        assert_eq!(ranks(&connection)[0], ("a".into(), Some(0)));
    }
}
