//! Writes to lists and folders.
//!
//! Like [`crate::tasks`], each takes the caller's transaction and names the
//! Swift and Kotlin methods it replaced.

use rusqlite::{OptionalExtension, Transaction};

use crate::CoreError;
use crate::time::{non_empty_name, stored};

/// A folder or list [`create_folder`] or [`create_list`] made: what a client
/// needs to build its own model of it, beside what it already passed in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedItem {
    pub id: String,
    /// The name as stored, trimmed.
    pub name: String,
    /// Its place among its siblings: after the last of them.
    pub sort_order: i64,
}

/// Creates a folder at the end of its siblings, inside `parent_folder_id`
/// or at the top. Replaces `WorkspaceStore.createFolder`,
/// `WorkspaceRepository.createFolder` and the CLI's `create_folder`.
pub fn create_folder(
    transaction: &Transaction,
    workspace_id: &str,
    name: &str,
    parent_folder_id: Option<&str>,
    now_ms: i64,
) -> Result<CreatedItem, CoreError> {
    let name = non_empty_name(name)?;
    if let Some(parent) = parent_folder_id {
        require_folder_in(transaction, parent, workspace_id)?;
    }
    let sort_order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM list_folders
         WHERE workspaceId = ?1 AND parentFolderId IS ?2",
        rusqlite::params![workspace_id, parent_folder_id],
        |row| row.get(0),
    )?;
    let id = new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO list_folders (id, workspaceId, parentFolderId, name, sortOrder, createdAt, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
        rusqlite::params![id, workspace_id, parent_folder_id, name, sort_order, now],
    )?;
    Ok(CreatedItem {
        id,
        name,
        sort_order,
    })
}

/// Creates a list at the end of its siblings, in `folder_id` or at the top.
/// Replaces `WorkspaceStore.createList`, `WorkspaceRepository.createList` and
/// the CLI's `create_list`.
pub fn create_list(
    transaction: &Transaction,
    workspace_id: &str,
    name: &str,
    folder_id: Option<&str>,
    now_ms: i64,
) -> Result<CreatedItem, CoreError> {
    let name = non_empty_name(name)?;
    if let Some(folder) = folder_id {
        require_folder_in(transaction, folder, workspace_id)?;
    }
    let sort_order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists
         WHERE workspaceId = ?1 AND folderId IS ?2",
        rusqlite::params![workspace_id, folder_id],
        |row| row.get(0),
    )?;
    let id = new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived,
                                 createdAt, updatedAt, systemRole, visibleRootTaskId, completedAt)
         VALUES (?1, ?2, ?3, ?4, NULL, ?5, 0, ?6, ?6, NULL, NULL, NULL)",
        rusqlite::params![id, workspace_id, folder_id, name, sort_order, now],
    )?;
    Ok(CreatedItem {
        id,
        name,
        sort_order,
    })
}

/// A folder that exists and belongs to `workspace_id`; anything else is a
/// missing folder, as both clients reported it.
fn require_folder_in(
    transaction: &Transaction,
    folder_id: &str,
    workspace_id: &str,
) -> Result<(), CoreError> {
    let owner: Option<String> = transaction
        .query_row(
            "SELECT workspaceId FROM list_folders WHERE id = ?1",
            [folder_id],
            |row| row.get(0),
        )
        .optional()?;
    match owner {
        Some(owner) if owner == workspace_id => Ok(()),
        _ => Err(CoreError::MissingFolder {
            id: folder_id.to_string(),
        }),
    }
}

/// An identifier as GRDB's `UUID().uuidString` writes one: uppercase.
pub(crate) fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

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
