//! Task dependencies: a task that waits on others until they are done.
//!
//! An edge in `task_dependencies` says `taskId` is blocked by
//! `blockedByTaskId`. A task is *blocked* while it is open and any task it
//! waits on is still open; a completed or cancelled blocker no longer holds it
//! back. Blockers may sit in any list.
//!
//! The rule every client draws from lives here, so the Mac, the phones and the
//! CLI cannot disagree about it:
//!
//! - **Order.** Among its siblings a blocked task sorts after every unblocked
//!   one, otherwise keeping its place ([`BLOCKED_LAST`] in the reads that hand
//!   back a list's rows, and in the sibling order a reorder works on).
//! - **Next up.** A blocked task is not a candidate (`focus::candidates`).
//! - **Greyed.** [`blocked_task_ids`] names the tasks a client draws dimmed.
//!
//! An edge's id is derived from its two ends, so two devices that add the same
//! dependency write the same row, and it merges rather than duplicates. Cycles
//! are refused when an edge is added; two devices can still each add half of
//! one while offline, which leaves every task in it blocked until either edge
//! is removed. Nothing here walks the graph beyond that check, so a cycle that
//! arrives through sync costs nothing but the dimming.
//!
//! Deleting either task deletes the edge (`ON DELETE CASCADE`); the journal and
//! the outbox both see the cascade, so undo puts it back and the tombstone
//! syncs.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};

use crate::CoreError;
use crate::records::{TaskRow, all};
use crate::time::stored;

/// An `ORDER BY` term, over a query whose task table is named `tasks`, that is
/// 1 for a blocked task and 0 otherwise. Sorting on it ahead of `sortOrder`
/// sinks blocked tasks below their unblocked siblings.
pub(crate) const BLOCKED_LAST: &str = "(tasks.status = 'open' AND EXISTS (\
     SELECT 1 FROM task_dependencies blocking_edge \
     JOIN tasks blocking_task ON blocking_task.id = blocking_edge.blockedByTaskId \
     WHERE blocking_edge.taskId = tasks.id AND blocking_task.status = 'open'))";

/// The term [`blocked_last`] stands in with before the table exists.
pub(crate) const NOT_BLOCKED: &str = "(tasks.id IS NULL)";

/// [`BLOCKED_LAST`] where the database has the table, and a constant where it
/// does not yet: the CLI reads and writes a database the app may not have
/// migrated.
pub(crate) fn blocked_last(connection: &Connection) -> Result<&'static str, CoreError> {
    Ok(if has_table(connection)? {
        BLOCKED_LAST
    } else {
        // An expression that is always false: a constant, even in brackets,
        // is read by ORDER BY as a column number.
        NOT_BLOCKED
    })
}

fn has_table(connection: &Connection) -> Result<bool, CoreError> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'task_dependencies')",
        [],
        |row| row.get(0),
    )?)
}

/// The edge's id: a UUID-shaped string from SHA-256 of
/// `takt.dependency:<taskId>:<blockedByTaskId>`, uppercased, with the version
/// 5 and RFC 4122 variant bits set. Every device derives the same id.
pub fn dependency_id(task_id: &str, blocked_by_task_id: &str) -> String {
    let digest =
        Sha256::digest(format!("takt.dependency:{task_id}:{blocked_by_task_id}").as_bytes());
    let mut bytes: [u8; 16] = digest[..16]
        .try_into()
        .expect("a digest is longer than 16 bytes");
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Makes `task_id` wait on `blocked_by_task_id`. Returns whether anything
/// changed: adding an edge that is already there is not an error.
///
/// Refuses a task waiting on itself, and an edge that would close a cycle
/// (the blocker already waits, directly or not, on the task).
pub fn add_blocker(
    transaction: &Transaction,
    task_id: &str,
    blocked_by_task_id: &str,
    now_ms: i64,
) -> Result<bool, CoreError> {
    for id in [task_id, blocked_by_task_id] {
        if !task_exists(transaction, id)? {
            return Err(CoreError::MissingTask { id: id.to_string() });
        }
    }
    if task_id == blocked_by_task_id || waits_on(transaction, blocked_by_task_id, task_id)? {
        return Err(CoreError::DependencyCycle);
    }
    let changed = transaction.execute(
        "INSERT INTO task_dependencies (id, taskId, blockedByTaskId, createdAt)
         SELECT ?1, ?2, ?3, ?4
         WHERE NOT EXISTS (SELECT 1 FROM task_dependencies WHERE taskId = ?2 AND blockedByTaskId = ?3)",
        params![
            dependency_id(task_id, blocked_by_task_id),
            task_id,
            blocked_by_task_id,
            stored(now_ms)
        ],
    )?;
    Ok(changed > 0)
}

/// Stops `task_id` waiting on `blocked_by_task_id`. Returns whether there was
/// such an edge.
pub fn remove_blocker(
    transaction: &Transaction,
    task_id: &str,
    blocked_by_task_id: &str,
) -> Result<bool, CoreError> {
    let changed = transaction.execute(
        "DELETE FROM task_dependencies WHERE taskId = ?1 AND blockedByTaskId = ?2",
        params![task_id, blocked_by_task_id],
    )?;
    Ok(changed > 0)
}

/// Whether `from` waits on `target`, directly or through other tasks.
fn waits_on(connection: &Connection, from: &str, target: &str) -> Result<bool, CoreError> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut frontier = vec![from.to_string()];
    let mut statement = connection
        .prepare_cached("SELECT blockedByTaskId FROM task_dependencies WHERE taskId = ?1")?;
    while let Some(id) = frontier.pop() {
        if id == target {
            return Ok(true);
        }
        if !seen.insert(id.clone()) {
            continue;
        }
        let next = statement
            .query_map([&id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        frontier.extend(next);
    }
    Ok(false)
}

fn task_exists(connection: &Connection, id: &str) -> Result<bool, CoreError> {
    Ok(connection
        .query_row("SELECT 1 FROM tasks WHERE id = ?1", [id], |_| Ok(()))
        .optional()?
        .is_some())
}

/// The tasks `task_id` waits on, open ones first, each group oldest edge
/// first.
pub fn blockers(connection: &Connection, task_id: &str) -> Result<Vec<TaskRow>, CoreError> {
    if !has_table(connection)? {
        return Ok(Vec::new());
    }
    all(
        connection,
        "SELECT tasks.* FROM task_dependencies d JOIN tasks ON tasks.id = d.blockedByTaskId
         WHERE d.taskId = ?1
         ORDER BY tasks.status <> 'open', d.createdAt, tasks.title",
        [task_id],
        TaskRow::from_row,
    )
}

/// The tasks waiting on `task_id`, open ones first.
pub fn blocked_by(connection: &Connection, task_id: &str) -> Result<Vec<TaskRow>, CoreError> {
    if !has_table(connection)? {
        return Ok(Vec::new());
    }
    all(
        connection,
        "SELECT tasks.* FROM task_dependencies d JOIN tasks ON tasks.id = d.taskId
         WHERE d.blockedByTaskId = ?1
         ORDER BY tasks.status <> 'open', d.createdAt, tasks.title",
        [task_id],
        TaskRow::from_row,
    )
}

/// Every open task that waits on at least one open task: what a client draws
/// dimmed. Usually a handful, so it crosses whole rather than per list.
pub fn blocked_task_ids(connection: &Connection) -> Result<Vec<String>, CoreError> {
    if !has_table(connection)? {
        return Ok(Vec::new());
    }
    all(
        connection,
        "SELECT DISTINCT d.taskId FROM task_dependencies d
         JOIN tasks ON tasks.id = d.taskId
         JOIN tasks blocker ON blocker.id = d.blockedByTaskId
         WHERE tasks.status = 'open' AND blocker.status = 'open'
         ORDER BY d.taskId",
        [],
        |row| row.get(0),
    )
}

/// Whether `task_id` is blocked now.
pub fn is_blocked(connection: &Connection, task_id: &str) -> Result<bool, CoreError> {
    if !has_table(connection)? {
        return Ok(false);
    }
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM task_dependencies d
           JOIN tasks ON tasks.id = d.taskId
           JOIN tasks blocker ON blocker.id = d.blockedByTaskId
           WHERE d.taskId = ?1 AND tasks.status = 'open' AND blocker.status = 'open')",
        [task_id],
        |row| row.get(0),
    )?)
}

#[cfg(test)]
mod tests;
