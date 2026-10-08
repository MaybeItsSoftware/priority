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
use crate::conditions;
use crate::conversions::{self, BoardColumn};
use crate::dailies::{self, DailyEdit};
use crate::editor::{self, EditorMetadata, EditorSnapshot};
use crate::journal::{self, HistoryTarget, UndoStep};
use crate::lists::{self, CreatedItem, DeletedList};
use crate::tasks::{self, DeletedTask, NewTask};
use crate::today;

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

    /// Creates a condition as one "New Condition" step; returns its id.
    pub fn create_condition(
        &self,
        workspace_id: String,
        name: String,
        is_location: bool,
        now_ms: i64,
    ) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "New Condition", |tx| {
            conditions::create_condition(tx, &workspace_id, &name, is_location, now_ms)
        })
    }

    /// Saves a condition as one "Edit Condition" step.
    pub fn save_condition(
        &self,
        id: String,
        name: String,
        is_location: bool,
        is_archived: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Edit Condition", |tx| {
            conditions::save_condition(tx, &id, &name, is_location, is_archived, now_ms)
        })
    }

    /// Makes a task a standalone list in a folder (or at the top); returns the list's id.
    pub fn move_task_to_folder(
        &self,
        id: String,
        folder_id: Option<String>,
        now_ms: i64,
    ) -> Result<String, CoreError> {
        let label = if folder_id.is_none() {
            "Move Item to Top Level"
        } else {
            "Move Item to Folder"
        };
        journal::journalled(&mut self.lock(), label, |tx| {
            conversions::move_task_to_folder(tx, &id, folder_id.as_deref(), now_ms)
        })
    }

    /// Turns a standalone list into a task in the Inbox; returns the task's id.
    pub fn convert_list_to_task(&self, id: String, now_ms: i64) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "Convert List to Task", |tx| {
            conversions::convert_list_to_task(tx, &id, now_ms)
        })
    }

    /// Nests a standalone list inside another list; returns its task's id.
    pub fn nest_list(
        &self,
        id: String,
        into_list_id: String,
        parent_task_id: Option<String>,
        now_ms: i64,
    ) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "Move List into List", |tx| {
            conversions::nest_list(tx, &id, &into_list_id, parent_task_id.as_deref(), now_ms)
        })
    }

    /// Makes an item a task or a nested list.
    pub fn set_item_kind(&self, id: String, kind: String, now_ms: i64) -> Result<(), CoreError> {
        let label = if kind == "list" {
            "Convert to List"
        } else {
            "Convert to Task"
        };
        journal::journalled(&mut self.lock(), label, |tx| {
            conversions::set_item_kind(tx, &id, &kind, now_ms)
        })
    }

    /// Pins a nested list to the sidebar, or unpins it.
    pub fn set_nested_list_promoted(
        &self,
        id: String,
        promoted: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        let label = if promoted {
            "Promote List"
        } else {
            "Unpin List"
        };
        journal::journalled(&mut self.lock(), label, |tx| {
            conversions::set_nested_list_promoted(tx, &id, promoted, now_ms)
        })
    }

    /// Archives or restores a nested list.
    pub fn set_nested_list_archived(
        &self,
        id: String,
        archived: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        let label = if archived {
            "Archive Nested List"
        } else {
            "Restore Nested List"
        };
        journal::journalled(&mut self.lock(), label, |tx| {
            conversions::set_nested_list_archived(tx, &id, archived, now_ms)
        })
    }

    /// Completes or reopens a standalone list.
    pub fn set_list_completed(
        &self,
        id: String,
        completed: bool,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        let label = if completed {
            "Complete List"
        } else {
            "Reopen List"
        };
        journal::journalled(&mut self.lock(), label, |tx| {
            conversions::set_list_completed(tx, &id, completed, now_ms)
        })
    }

    /// Saves a board's columns, moving cards out of a removed one, as one step.
    pub fn set_board_columns(
        &self,
        key: String,
        columns: Vec<BoardColumn>,
        moving_task_ids: Vec<String>,
        to_column: Option<String>,
        label: String,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), &label, |tx| {
            conversions::set_board_columns(
                tx,
                &key,
                &columns,
                &moving_task_ids,
                to_column.as_deref(),
                now_ms,
            )
        })
    }

    /// A task's editable state, as the editor opens it.
    pub fn editor_snapshot(&self, task_id: String) -> Result<EditorSnapshot, CoreError> {
        editor::snapshot(&self.lock(), &task_id)
    }

    /// Saves the task editor as one "Edit Task" step, refusing if the task
    /// changed since `baseline`. Returns the task as saved.
    pub fn save_editor(
        &self,
        edit: EditorSnapshot,
        baseline: EditorSnapshot,
        now_ms: i64,
        zone: String,
    ) -> Result<EditorSnapshot, CoreError> {
        journal::journalled(&mut self.lock(), "Edit Task", |tx| {
            editor::save_editor(tx, &edit, &baseline, now_ms, &zone)
        })
    }

    /// Sets a task's title, notes, due time and estimate as one "Edit Task" step.
    #[allow(clippy::too_many_arguments)]
    pub fn update_task(
        &self,
        id: String,
        title: String,
        notes: String,
        due_at_ms: Option<i64>,
        estimate_seconds: Option<i64>,
        now_ms: i64,
        zone: String,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Edit Task", |tx| {
            editor::update_task(
                tx,
                &id,
                &title,
                &notes,
                due_at_ms,
                estimate_seconds,
                now_ms,
                &zone,
            )
        })
    }

    /// Sets a task's priority, tags, links and repeat as one "Edit Task Details" step.
    pub fn update_editor_metadata(
        &self,
        task_id: String,
        metadata: EditorMetadata,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Edit Task Details", |tx| {
            editor::update_editor_metadata(tx, &task_id, &metadata, now_ms)
        })
    }

    /// Moves a task's start as one "Schedule Task" step.
    pub fn schedule_task(
        &self,
        id: String,
        start_at_ms: Option<i64>,
        now_ms: i64,
        zone: String,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Schedule Task", |tx| {
            editor::schedule_task(tx, &id, start_at_ms, now_ms, &zone)
        })
    }

    /// Copies a task's planning onto its subtasks as one step.
    pub fn apply_planning_to_descendants(
        &self,
        task_id: String,
        now_ms: i64,
        zone: String,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Apply Planning to Subtasks", |tx| {
            editor::apply_planning_to_descendants(tx, &task_id, now_ms, &zone)
        })
    }

    /// Opens, completes or cancels a task as one "Change Status" step,
    /// writing a repeating task's next occurrence in `zone` (an IANA name).
    pub fn set_status(
        &self,
        task_id: String,
        status: String,
        now_ms: i64,
        zone: String,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Change Status", |tx| {
            tasks::set_status(tx, &task_id, &status, now_ms, &zone)
        })
    }

    /// Makes a task a daily as one "Make Daily" step; returns the daily's id.
    pub fn make_daily(
        &self,
        task_id: String,
        weekdays: Vec<u32>,
        interval_days: Option<i64>,
        target_seconds: Option<i64>,
        now_ms: i64,
    ) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "Make Daily", |tx| {
            dailies::make_daily(
                tx,
                &task_id,
                &weekdays,
                interval_days,
                target_seconds,
                now_ms,
            )
        })
    }

    /// Archives a task's daily as one "Archive Daily" step.
    pub fn archive_daily(&self, task_id: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Archive Daily", |tx| {
            dailies::archive_daily(tx, &task_id, now_ms)
        })
    }

    /// Edits a daily as one "Edit Daily" step.
    pub fn update_daily(&self, id: String, edit: DailyEdit, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Edit Daily", |tx| {
            dailies::update_daily(tx, &id, &edit, now_ms)
        })
    }

    /// Logs progress on a daily as one "Log Daily" step; returns the
    /// contribution's id.
    pub fn log_contribution(
        &self,
        daily_id: String,
        seconds: i64,
        complete: bool,
        now_ms: i64,
        zone: String,
    ) -> Result<String, CoreError> {
        journal::journalled(&mut self.lock(), "Log Daily", |tx| {
            dailies::log_contribution(tx, &daily_id, seconds, complete, now_ms, &zone)
        })
    }

    /// Un-ticks a day of a daily as one "Clear Daily" step.
    pub fn clear_contribution(
        &self,
        daily_id: String,
        day_ms: i64,
        zone: String,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Clear Daily", |tx| {
            dailies::clear_contribution(tx, &daily_id, day_ms, &zone)
        })
    }

    /// Ranks tasks in Today's focus order as one "Reorder Today" step.
    pub fn arrange_day(&self, ordered_task_ids: Vec<String>, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Reorder Today", |tx| {
            today::arrange_day(tx, &ordered_task_ids, now_ms)
        })
    }

    /// Pins a task in the focus order as one "Pin Task" step.
    pub fn pin_task(&self, task_id: String, index: i64, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Pin Task", |tx| {
            today::pin_task(tx, &task_id, index, now_ms)
        })
    }

    /// Releases a task to the ranking as one "Unpin Task" step.
    pub fn unpin_task(&self, task_id: String, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Unpin Task", |tx| {
            today::unpin_task(tx, &task_id, now_ms)
        })
    }

    /// Clears the focus order as one "Clear Focus Order" step.
    pub fn clear_focus_order(&self, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Clear Focus Order", |tx| {
            today::clear_focus_order(tx, now_ms)
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
