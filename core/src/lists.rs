//! Writes to lists and folders.
//!
//! Like [`crate::tasks`], each takes the caller's transaction and names the
//! Swift and Kotlin methods it replaced.

use rusqlite::{OptionalExtension, Transaction};

use crate::CoreError;
use crate::time::{non_empty_name, stored};

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

/// Renames a folder. A name that is already the folder's changes nothing,
/// so it records no step and leaves redo alone. Replaces
/// `WorkspaceStore.updateFolder` and `WorkspaceRepository.updateFolder`.
pub fn rename_folder(
    transaction: &Transaction,
    id: &str,
    name: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let name = non_empty_name(name)?;
    let current: String = transaction
        .query_row("SELECT name FROM list_folders WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .optional()?
        .ok_or_else(|| CoreError::MissingFolder { id: id.to_string() })?;
    if current != name {
        transaction.execute(
            "UPDATE list_folders SET name = ?1, updatedAt = ?2 WHERE id = ?3",
            rusqlite::params![name, stored(now_ms), id],
        )?;
    }
    Ok(())
}

/// Renames a list and touches nothing else, so undo offers "Rename List".
/// Replaces `WorkspaceStore.renameList` and `WorkspaceRepository.renameList`.
pub fn rename_list(
    transaction: &Transaction,
    id: &str,
    name: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let name = non_empty_name(name)?;
    let (current, _) = list_name_and_colour(transaction, id)?;
    if current != name {
        transaction.execute(
            "UPDATE task_lists SET name = ?1, updatedAt = ?2 WHERE id = ?3",
            rusqlite::params![name, stored(now_ms), id],
        )?;
    }
    Ok(())
}

/// Sets a list's name and colour together, as the list settings sheet saves
/// them. A blank colour clears it. Replaces `WorkspaceStore.updateList` and
/// `WorkspaceRepository.updateList`.
pub fn update_list(
    transaction: &Transaction,
    id: &str,
    name: &str,
    colour_hex: Option<&str>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let name = non_empty_name(name)?;
    let colour = colour_hex.map(str::trim).filter(|c| !c.is_empty());
    let (current_name, current_colour) = list_name_and_colour(transaction, id)?;
    if current_name != name || current_colour.as_deref() != colour {
        transaction.execute(
            "UPDATE task_lists SET name = ?1, colorHex = ?2, updatedAt = ?3 WHERE id = ?4",
            rusqlite::params![name, colour, stored(now_ms), id],
        )?;
    }
    Ok(())
}

/// Archives or restores a list. The Inbox cannot be archived: the app puts
/// things there by itself, so it has to stay somewhere the user can see.
/// Replaces `WorkspaceStore.setListArchived` and
/// `WorkspaceRepository.setListArchived`.
pub fn set_list_archived(
    transaction: &Transaction,
    id: &str,
    archived: bool,
    now_ms: i64,
) -> Result<(), CoreError> {
    let system_role: Option<String> = transaction
        .query_row(
            "SELECT systemRole FROM task_lists WHERE id = ?1",
            [id],
            |row| row.get(0),
        )
        .optional()?
        .ok_or_else(|| CoreError::MissingList { id: id.to_string() })?;
    if archived && system_role.is_some() {
        return Err(CoreError::SystemListIsPermanent);
    }
    transaction.execute(
        "UPDATE task_lists SET isArchived = ?1, updatedAt = ?2 WHERE id = ?3",
        rusqlite::params![archived, stored(now_ms), id],
    )?;
    Ok(())
}

fn list_name_and_colour(
    transaction: &Transaction,
    id: &str,
) -> Result<(String, Option<String>), CoreError> {
    transaction
        .query_row(
            "SELECT name, colorHex FROM task_lists WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| CoreError::MissingList { id: id.to_string() })
}

#[cfg(test)]
mod tests;
