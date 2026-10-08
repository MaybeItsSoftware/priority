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
use crate::tasks::{self, DeletedTask};

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

    /// Deletes a task and its subtree as one "Delete Task" step.
    pub fn delete_task(&self, id: String) -> Result<DeletedTask, CoreError> {
        journal::journalled(&mut self.lock(), "Delete Task", |tx| {
            tasks::delete_task(tx, &id)
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
