//! The undo journal: taking back the last thing done, and doing it again.
//!
//! Step three of docs/rust-core-migration.md. Rather than every write
//! declaring its own inverse, the database records what changed: triggers on
//! the tables that hold the user's work (`schema::triggers`) write each row's
//! before and after into `change_log` while `undo_control` is armed, and undo
//! replays a group of entries backwards. A write is one undoable step when it
//! runs between [`begin`] and [`finish`] in one transaction.
//!
//! Focus sessions and the focus queue are deliberately not journalled. A
//! timer is a record of what happened, not an edit to take back.

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};

use crate::CoreError;
use crate::schema::triggers::JOURNALLED_TABLES;

/// How many steps the journal keeps. Whole groups only: half an undo step is
/// worse than none.
pub const JOURNAL_DEPTH: i64 = 100;

/// One named step in the journal, as [`history`] reports it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UndoStep {
    /// The journal group the step's changes share.
    pub id: String,
    /// What the step is offered back as: "New Task", "Delete List".
    pub label: String,
    /// Undone steps are the redo stack.
    pub is_undone: bool,
    /// How many rows the step touched.
    pub change_count: u32,
}

/// The task and list the next undo (or redo) affects, so a client can reveal
/// the work that comes back.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct HistoryTarget {
    pub task_id: Option<String>,
    pub list_id: Option<String>,
}

/// Arms the journal for one step inside `transaction` and returns the step's
/// group id, which [`finish`] needs.
///
/// Recording is off by default, so a write that has not opted in (a
/// migration, an import, the focus tables) is not an undo step.
pub fn begin(transaction: &Transaction, label: &str) -> Result<String, CoreError> {
    let group = uuid::Uuid::new_v4().to_string().to_uppercase();
    let armed = transaction.execute(
        "UPDATE undo_control SET groupId = ?1, label = ?2, suppressed = 0 WHERE id = 0",
        params![group, label],
    )?;
    if armed != 1 {
        return Err(CoreError::NoJournal);
    }
    Ok(group)
}

/// Disarms the journal, and if the step changed anything, makes it the new
/// branch of history: the redo stack goes, and the journal is trimmed to
/// [`JOURNAL_DEPTH`] steps. Returns whether the step changed anything.
///
/// A key pressed at the end of a list can be a no-op; only an actual change
/// invalidates redo.
pub fn finish(transaction: &Transaction, group: &str) -> Result<bool, CoreError> {
    transaction.execute("UPDATE undo_control SET suppressed = 1 WHERE id = 0", [])?;
    let changed: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM change_log WHERE groupId = ?1)",
        [group],
        |row| row.get(0),
    )?;
    if changed {
        transaction.execute("DELETE FROM change_log WHERE undone = 1", [])?;
    }
    transaction.execute(
        "DELETE FROM change_log WHERE groupId IN (
           SELECT groupId FROM change_log GROUP BY groupId
           ORDER BY MAX(id) DESC LIMIT -1 OFFSET ?1)",
        [JOURNAL_DEPTH],
    )?;
    Ok(changed)
}

/// Runs `work` as one undoable step in its own immediate transaction: the
/// way every write the core owns is made. A failure anywhere rolls back the
/// rows, the journal entries and the armed `undo_control` together.
pub fn journalled<T>(
    connection: &mut Connection,
    label: &str,
    work: impl FnOnce(&Transaction) -> Result<T, CoreError>,
) -> Result<T, CoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let group = begin(&transaction, label)?;
    let result = work(&transaction)?;
    finish(&transaction, &group)?;
    transaction.commit()?;
    Ok(result)
}

/// What undo would take back, phrased for a menu item.
pub fn undoable_label(connection: &Connection) -> Result<Option<String>, CoreError> {
    Ok(connection
        .query_row(
            "SELECT label FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .flatten())
}

/// What redo would put back.
pub fn redoable_label(connection: &Connection) -> Result<Option<String>, CoreError> {
    Ok(connection
        .query_row(
            "SELECT label FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .flatten())
}

/// The journal's named steps, newest first, at most `limit` of them.
///
/// Undone steps (the redo stack) come first, since they were done later than
/// anything still standing; the last of them is the next redo, and the first
/// step that is not undone is the next undo.
pub fn history(connection: &Connection, limit: u32) -> Result<Vec<UndoStep>, CoreError> {
    let mut statement = connection.prepare(
        "SELECT groupId, MAX(label), MAX(undone), COUNT(*), MAX(id) AS lastId
         FROM change_log
         WHERE groupId IS NOT NULL
         GROUP BY groupId
         ORDER BY lastId DESC
         LIMIT ?1",
    )?;
    let steps = statement
        .query_map([limit], |row| {
            Ok(UndoStep {
                id: row.get(0)?,
                label: row
                    .get::<_, Option<String>>(1)?
                    .unwrap_or_else(|| "Change".to_string()),
                is_undone: row.get::<_, Option<bool>>(2)?.unwrap_or(false),
                change_count: row.get(3)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(steps)
}

/// The task and list the next undo (`for_undo`) or redo affects.
pub fn history_target(connection: &Connection, for_undo: bool) -> Result<HistoryTarget, CoreError> {
    let group: Option<String> = connection
        .query_row(
            if for_undo {
                "SELECT groupId FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1"
            } else {
                "SELECT groupId FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1"
            },
            [],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    let Some(group) = group else {
        return Ok(HistoryTarget::default());
    };
    // Undo brings back what the step deleted; redo, what it inserted.
    let operation = if for_undo { "delete" } else { "insert" };
    let task_id = connection
        .query_row(
            "SELECT rowId FROM change_log WHERE groupId = ?1 AND tableName = 'tasks'
             ORDER BY CASE WHEN operation = ?2 THEN 0 ELSE 1 END, id DESC LIMIT 1",
            params![group, operation],
            |row| row.get(0),
        )
        .optional()?;
    let list_id = connection
        .query_row(
            "SELECT rowId FROM change_log WHERE groupId = ?1 AND tableName = 'task_lists' AND operation = ?2
             ORDER BY id DESC LIMIT 1",
            params![group, operation],
            |row| row.get(0),
        )
        .optional()?;
    Ok(HistoryTarget { task_id, list_id })
}

/// Reverses the most recent step. Returns its label, or nothing when there
/// was nothing to undo.
pub fn undo(connection: &mut Connection) -> Result<Option<String>, CoreError> {
    step(connection, true)
}

/// Puts back the most recently undone step.
pub fn redo(connection: &mut Connection) -> Result<Option<String>, CoreError> {
    step(connection, false)
}

fn step(connection: &mut Connection, reversed: bool) -> Result<Option<String>, CoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let group: Option<(String, Option<String>)> = transaction
        .query_row(
            if reversed {
                "SELECT groupId, label FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1"
            } else {
                "SELECT groupId, label FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1"
            },
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((group, label)) = group else {
        return Ok(None);
    };
    replay(&transaction, &group, reversed)?;
    transaction.execute(
        "UPDATE change_log SET undone = ?1 WHERE groupId = ?2",
        params![reversed, group],
    )?;
    transaction.commit()?;
    Ok(label)
}

struct Entry {
    table: String,
    key: String,
    operation: String,
    before: Option<String>,
    after: Option<String>,
}

fn replay(transaction: &Transaction, group: &str, reversed: bool) -> Result<(), CoreError> {
    // Recording is already off outside a journalled write; set explicitly so
    // a replay can never record undoing as another thing to undo.
    transaction.execute("UPDATE undo_control SET suppressed = 1 WHERE id = 0", [])?;
    // A subtree comes back parent-first or child-first depending on the order
    // its rows were deleted in, and either way one end of it briefly points
    // at a row that is not there yet.
    transaction.execute_batch("PRAGMA defer_foreign_keys = ON")?;

    let mut statement = transaction.prepare(if reversed {
        "SELECT tableName, rowId, operation, beforeJSON, afterJSON FROM change_log WHERE groupId = ?1 ORDER BY id DESC"
    } else {
        "SELECT tableName, rowId, operation, beforeJSON, afterJSON FROM change_log WHERE groupId = ?1 ORDER BY id ASC"
    })?;
    let entries: Vec<Entry> = statement
        .query_map([group], |row| {
            Ok(Entry {
                table: row.get(0)?,
                key: row.get(1)?,
                operation: row.get(2)?,
                before: row.get(3)?,
                after: row.get(4)?,
            })
        })?
        .collect::<Result<_, _>>()?;

    for entry in entries {
        // Only the journalled tables are ever replayed, which is also what
        // makes interpolating the table name below safe.
        let Some(&(table, key_column)) = JOURNALLED_TABLES.iter().find(|(t, _)| *t == entry.table)
        else {
            continue;
        };
        let json = if reversed {
            &entry.before
        } else {
            &entry.after
        };
        match (entry.operation.as_str(), reversed) {
            ("insert", true) | ("delete", false) => {
                transaction.execute(
                    &format!("DELETE FROM {table} WHERE {key_column} = ?1"),
                    [&entry.key],
                )?;
            }
            ("delete", true) | ("insert", false) => {
                let Some(json) = json else { continue };
                let columns = columns(transaction, table)?;
                let names = columns
                    .iter()
                    .map(|c| format!("\"{c}\""))
                    .collect::<Vec<_>>();
                let values = columns
                    .iter()
                    .map(|c| format!("json_extract(?1, '$.{c}')"))
                    .collect::<Vec<_>>();
                transaction.execute(
                    &format!(
                        "INSERT INTO {table} ({}) VALUES ({})",
                        names.join(", "),
                        values.join(", ")
                    ),
                    [json],
                )?;
            }
            ("update", _) => {
                let Some(json) = json else { continue };
                // An UPDATE, never INSERT OR REPLACE: a replace deletes the
                // row first, and a delete cascades, so putting back a task's
                // old title would take its subtree with it.
                let columns = columns(transaction, table)?;
                let assignments = columns
                    .iter()
                    .map(|c| format!("\"{c}\" = json_extract(?1, '$.{c}')"))
                    .collect::<Vec<_>>();
                transaction.execute(
                    &format!(
                        "UPDATE {table} SET {} WHERE \"{key_column}\" = ?2",
                        assignments.join(", ")
                    ),
                    params![json, entry.key],
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn columns(connection: &Connection, table: &str) -> Result<Vec<String>, CoreError> {
    let mut statement =
        connection.prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")?;
    let columns = statement
        .query_map([table], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(columns)
}

#[cfg(test)]
mod tests;
