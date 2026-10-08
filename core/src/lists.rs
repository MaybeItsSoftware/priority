//! Writes to lists and folders.
//!
//! Like [`crate::tasks`], each takes the caller's transaction and names the
//! Swift and Kotlin methods it replaced.

use rusqlite::{OptionalExtension, Transaction};

use crate::CoreError;

/// What [`delete_list`] removed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeletedList {
    pub id: String,
    pub name: String,
    /// How many tasks went with it.
    pub tasks_deleted: u32,
}

/// Deletes a list and, through the foreign keys, every task in it. The Inbox
/// is permanent: quick capture lands there. Replaces
/// `WorkspaceStore.deleteList` and `WorkspaceRepository.deleteList`.
pub fn delete_list(transaction: &Transaction, id: &str) -> Result<DeletedList, CoreError> {
    let (name, system_role): (String, Option<String>) = transaction
        .query_row(
            "SELECT name, systemRole FROM task_lists WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| CoreError::MissingList { id: id.to_string() })?;
    if system_role.is_some() {
        return Err(CoreError::SystemListIsPermanent);
    }
    let tasks_deleted: u32 = transaction.query_row(
        "SELECT COUNT(*) FROM tasks WHERE listId = ?1",
        [id],
        |row| row.get(0),
    )?;
    transaction.execute("DELETE FROM task_lists WHERE id = ?1", [id])?;
    Ok(DeletedList {
        id: id.to_string(),
        name,
        tasks_deleted,
    })
}

/// Deletes a folder. Its lists are kept: the schema's SET NULL moves them to
/// the top of the sidebar. Folders inside it cascade with it. Replaces
/// `WorkspaceStore.deleteFolder` and `WorkspaceRepository.deleteFolder`.
pub fn delete_folder(transaction: &Transaction, id: &str) -> Result<(), CoreError> {
    let deleted = transaction.execute("DELETE FROM list_folders WHERE id = ?1", [id])?;
    if deleted == 0 {
        return Err(CoreError::MissingFolder { id: id.to_string() });
    }
    Ok(())
}

#[cfg(test)]
mod tests;
