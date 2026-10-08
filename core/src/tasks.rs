//! Writes to tasks.
//!
//! Step four of docs/rust-core-migration.md moves the task writes here one at
//! a time. Each function takes the caller's transaction, so the CLI can run
//! it inside its own journalled step under its "MCP: " label, and
//! [`crate::workspace::CoreWorkspace`] runs it as the apps' step. Each one
//! names the Swift `WorkspaceStore` method and the Kotlin
//! `WorkspaceRepository` method it replaced.

use rusqlite::{OptionalExtension, Transaction};

use crate::CoreError;

/// What [`delete_task`] removed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeletedTask {
    pub id: String,
    pub title: String,
    /// How many tasks below it went with it.
    pub subtasks_deleted: u32,
}

/// Deletes a task and, through the foreign keys, everything below it: its
/// subtasks, their metadata, and whatever hangs off them. One undo step
/// brings the whole subtree back. Replaces `WorkspaceStore.deleteTask` and
/// `WorkspaceRepository.deleteTask`.
pub fn delete_task(transaction: &Transaction, id: &str) -> Result<DeletedTask, CoreError> {
    let title: String = transaction
        .query_row("SELECT title FROM tasks WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .optional()?
        .ok_or_else(|| CoreError::MissingTask { id: id.to_string() })?;
    let subtasks_deleted: u32 = transaction.query_row(
        "WITH RECURSIVE subtree(id) AS (
           SELECT id FROM tasks WHERE parentTaskId = ?1
           UNION ALL
           SELECT tasks.id FROM tasks JOIN subtree ON tasks.parentTaskId = subtree.id
         )
         SELECT COUNT(*) FROM subtree",
        [id],
        |row| row.get(0),
    )?;
    transaction.execute("DELETE FROM tasks WHERE id = ?1", [id])?;
    Ok(DeletedTask {
        id: id.to_string(),
        title,
        subtasks_deleted,
    })
}

#[cfg(test)]
mod tests;
