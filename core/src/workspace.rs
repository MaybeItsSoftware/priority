//! The handle a client holds on its workspace database through UniFFI.
//!
//! One connection, opened the way every client opens the file: a five-second
//! wait for another writer and foreign keys on. It sits beside the client's
//! own connection (GRDB on Apple, androidx's driver on Android) on the same
//! SQLite library, so the two cannot disturb each other's locks. As behaviour
//! moves into the core, it moves onto this type.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use rusqlite::Connection;

use crate::CoreError;
use crate::journal::{self, HistoryTarget, UndoStep};
use crate::lists::{self, CreatedItem, DeletedList};
use crate::tasks::{self, DeletedTask, NewTask};

/// An open workspace database.
#[derive(uniffi::Object)]
pub struct CoreWorkspace {
    connection: Mutex<Connection>,
}

#[uniffi::export]
impl CoreWorkspace {
    /// Opens the database at `path`, which must already be migrated
    /// ([`crate::schema::migrate_workspace`]).
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA foreign_keys = ON")?;
        Ok(Arc::new(Self {
            connection: Mutex::new(connection),
        }))
    }

    /// Reverses the most recent step; returns its label, or nothing when there
    /// was nothing to undo.
    pub fn undo(&self) -> Result<Option<String>, CoreError> {
        journal::undo(&mut self.lock())
    }

    /// Puts back the most recently undone step.
    pub fn redo(&self) -> Result<Option<String>, CoreError> {
        journal::redo(&mut self.lock())
    }

    /// What undo would take back, phrased for a menu item.
    pub fn undoable_label(&self) -> Result<Option<String>, CoreError> {
        journal::undoable_label(&self.lock())
    }

    /// What redo would put back.
    pub fn redoable_label(&self) -> Result<Option<String>, CoreError> {
        journal::redoable_label(&self.lock())
    }

    /// The journal's named steps, newest first.
    pub fn undo_history(&self, limit: u32) -> Result<Vec<UndoStep>, CoreError> {
        journal::history(&self.lock(), limit)
    }

    /// The task and list the next undo (`for_undo`) or redo affects.
    pub fn history_target(&self, for_undo: bool) -> Result<HistoryTarget, CoreError> {
        journal::history_target(&self.lock(), for_undo)
    }

    /// Creates a task as one "New Task" step and returns its id.
    pub fn create_task(&self, task: NewTask, now_ms: i64) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "New Task", |tx| {
            tasks::create_task(tx, &task, now_ms)
        })
    }

    /// Moves a task and its subtree as one "Move Task" step.
    pub fn move_task(
        &self,
        id: String,
        list_id: String,
        parent_task_id: Option<String>,
        to_visible_root: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move Task", |tx| {
            tasks::move_task(
                tx,
                &id,
                &list_id,
                parent_task_id.as_deref(),
                to_visible_root,
                now_ms,
            )
        })
    }

    /// Moves a task among its siblings as one "Reorder Task" step.
    pub fn move_task_within_siblings(
        &self,
        id: String,
        offset: i32,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Task", |tx| {
            tasks::move_task_within_siblings(tx, &id, offset, now_ms)
        })
    }

    /// Moves a task to the top of its siblings as one "Reorder Task" step.
    pub fn move_task_to_start(&self, id: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Task", |tx| {
            tasks::move_task_to_start(tx, &id, now_ms)
        })
    }

    /// Drops a task before a sibling, and into a board column, as one
    /// "Reorder Task" step.
    pub fn move_task_before(
        &self,
        id: String,
        target_id: String,
        kanban_column: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Task", |tx| {
            tasks::move_task_before(tx, &id, &target_id, kanban_column.as_deref(), now_ms)
        })
    }

    /// Indents a task under the sibling above as one "Indent Task" step.
    pub fn indent_task(&self, id: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Indent Task", |tx| {
            tasks::indent_task(tx, &id, now_ms)
        })
    }

    /// Outdents a task to follow its parent as one "Outdent Task" step.
    pub fn outdent_task(&self, id: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Outdent Task", |tx| {
            tasks::outdent_task(tx, &id, now_ms)
        })
    }

    /// Puts tasks in a board column as one "Move Task" step.
    pub fn set_kanban_column(
        &self,
        task_ids: Vec<String>,
        column: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move Task", |tx| {
            tasks::set_kanban_column(tx, &task_ids, column.as_deref(), now_ms)
        })
    }

    /// Places a task on the priority matrix as one "Move Task" step.
    pub fn set_matrix_position(
        &self,
        id: String,
        urgency: Option<i64>,
        importance: Option<i64>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move Task", |tx| {
            tasks::set_matrix_position(tx, &id, urgency, importance, now_ms)
        })
    }

    /// Deletes a task and its subtree as one "Delete Task" step.
    pub fn delete_task(&self, id: String) -> Result<DeletedTask, CoreError> {
        journal::journalled(&mut self.lock(), "Delete Task", |tx| {
            tasks::delete_task(tx, &id)
        })
    }

    /// Deletes a list and its tasks as one "Delete List" step.
    pub fn delete_list(&self, id: String) -> Result<DeletedList, CoreError> {
        journal::journalled(&mut self.lock(), "Delete List", |tx| {
            lists::delete_list(tx, &id)
        })
    }

    /// Creates a folder as one "New Folder" step.
    pub fn create_folder(
        &self,
        workspace_id: String,
        name: String,
        parent_folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<CreatedItem, CoreError> {
        journal::journalled(&mut self.lock(), "New Folder", |tx| {
            lists::create_folder(
                tx,
                &workspace_id,
                &name,
                parent_folder_id.as_deref(),
                now_ms,
            )
        })
    }

    /// Creates a list as one "New List" step.
    pub fn create_list(
        &self,
        workspace_id: String,
        name: String,
        folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<CreatedItem, CoreError> {
        journal::journalled(&mut self.lock(), "New List", |tx| {
            lists::create_list(tx, &workspace_id, &name, folder_id.as_deref(), now_ms)
        })
    }

    /// Moves a folder into another (or to the top) as one "Move Folder" step.
    pub fn move_folder(
        &self,
        id: String,
        parent_folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move Folder", |tx| {
            lists::move_folder(tx, &id, parent_folder_id.as_deref(), now_ms)
        })
    }

    /// Moves a list into a folder (or to the top) as one "Move List" step.
    pub fn move_list(
        &self,
        id: String,
        folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move List", |tx| {
            lists::move_list(tx, &id, folder_id.as_deref(), now_ms)
        })
    }

    /// Moves a list among its siblings as one "Reorder List" step.
    pub fn move_list_within_folder(
        &self,
        id: String,
        offset: i32,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder List", |tx| {
            lists::move_list_within_folder(tx, &id, offset, now_ms)
        })
    }

    /// Moves a folder among its siblings as one "Reorder Folder" step.
    pub fn move_folder_within_siblings(
        &self,
        id: String,
        offset: i32,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Folder", |tx| {
            lists::move_folder_within_siblings(tx, &id, offset, now_ms)
        })
    }

    /// Drops a list before another, in a folder, as one "Reorder List" step.
    pub fn place_list(
        &self,
        id: String,
        before_id: Option<String>,
        folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder List", |tx| {
            lists::place_list(tx, &id, before_id.as_deref(), folder_id.as_deref(), now_ms)
        })
    }

    /// Drops a folder before another, in a parent, as one "Reorder Folder" step.
    pub fn place_folder(
        &self,
        id: String,
        before_id: Option<String>,
        parent_folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Folder", |tx| {
            lists::place_folder(
                tx,
                &id,
                before_id.as_deref(),
                parent_folder_id.as_deref(),
                now_ms,
            )
        })
    }

    /// Renames a folder as one "Rename Folder" step.
    pub fn rename_folder(&self, id: String, name: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Rename Folder", |tx| {
            lists::rename_folder(tx, &id, &name, now_ms)
        })
    }

    /// Renames a list as one "Rename List" step.
    pub fn rename_list(&self, id: String, name: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Rename List", |tx| {
            lists::rename_list(tx, &id, &name, now_ms)
        })
    }

    /// Sets a list's name and colour as one "Edit List" step.
    pub fn update_list(
        &self,
        id: String,
        name: String,
        colour_hex: Option<String>,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Edit List", |tx| {
            lists::update_list(tx, &id, &name, colour_hex.as_deref(), now_ms)
        })
    }

    /// Archives or restores a list as one "Archive List" step.
    pub fn set_list_archived(
        &self,
        id: String,
        archived: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Archive List", |tx| {
            lists::set_list_archived(tx, &id, archived, now_ms)
        })
    }

    /// Deletes a folder as one "Delete Folder" step; its lists move to the top.
    pub fn delete_folder(&self, id: String) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Delete Folder", |tx| {
            lists::delete_folder(tx, &id)
        })
    }
}

impl CoreWorkspace {
    /// A poisoned lock only means another call panicked mid-way; SQLite rolled
    /// its transaction back, so the connection is still sound to use.
    fn lock(&self) -> MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
