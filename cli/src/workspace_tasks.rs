//! The app's local task tree — folders, lists and tasks — read and written.
//!
//! The app's workspace database is its source of truth, and the Checkvist tools
//! only reach the Checkvist edge of it. These are the tools that edit the tree
//! the app actually shows. They are a second writer to a database that
//! `WorkspaceStore` (Swift, GRDB) owns, which is safe only because each one
//! copies what the matching `WorkspaceStore` method does, row for row. The
//! method a write copies is named in its doc comment. Change the Swift one and
//! this one has to follow.
//!
//! What a second writer has to get right:
//!
//! - **Undo.** Every write runs inside [`Workspace::journalled`], which brackets
//!   it with the Rust core's `journal::begin` and `journal::finish`
//!   (core/src/journal.rs). The core arms `undo_control` with a fresh group and
//!   a label, the database's own `change_log` triggers record the rows, and it
//!   disarms again inside the same transaction. The app's Undo menu then offers
//!   the step as "Undo MCP: New Task", and the app undoes it through the same
//!   core code. A write that changes something clears the redo stack, and the
//!   journal is trimmed to the core's depth.
//! - **Concurrency.** `BEGIN IMMEDIATE` takes the write lock up front, and a
//!   busy timeout waits out the app's own writes rather than failing on them.
//!   The app waits out ours the same way. Foreign keys are switched on, as
//!   `WorkspaceStore` does for every connection: a delete that does not
//!   cascade leaves orphaned subtasks behind.
//! - **Being seen.** The app polls `PRAGMA data_version` on its writer
//!   connection, which moves only when another connection commits, and
//!   reloads. See `WorkspaceViewModel+ExternalWrites.swift`.
//! - **Row shape.** Uppercase UUIDs, GRDB's `YYYY-MM-DD HH:MM:SS.SSS` UTC
//!   timestamps, `COALESCE(MAX(sortOrder), -1) + 1` for appends, dense
//!   re-numbering for reorders, `task_metadata` rows created lazily with
//!   `'[]'` defaults. `tasks_fts` is maintained by the schema's own triggers.
//!
//! What stays out: anything that is policy rather than rows. Completing a
//! repeating task has to schedule its next occurrence from a `PeriodicSchedule`
//! that only `TaktCore` can parse, so that is refused here rather than
//! done half-way.

use crate::error::{Result, ToolError};
use crate::workspace::{Workspace, local_string, map_query_error, stored_string};
use chrono::Utc;
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Row, Transaction, TransactionBehavior, params,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

/// The newest migration whose schema these writes are written against. An
/// older database is missing columns they name; a newer one is fine, because
/// `WorkspaceStore` only ever adds nullable columns.
const REQUIRED_MIGRATION: &str = "v16_task_completion_time";

/// What the app's Undo menu shows ahead of the action, so that a step an
/// assistant took is recognisable as one before it is taken back.
const LABEL_PREFIX: &str = "MCP: ";

/// Long enough to outlast any write the app makes, short enough that a stuck
/// lock is reported rather than waited on for ever.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

const TASK_COLUMNS: &str = "t.id, t.listId, t.parentTaskId, t.title, t.notes, t.status, \
     t.sortOrder, t.dueAt, t.estimateSeconds, t.itemKind, t.isPromoted, t.archivedAt, \
     t.completedAt, m.kanbanColumn, m.externalLinksJSON, m.recurrenceRule, \
     m.taskId IS NOT NULL";

/// What `v20_waiting_follow_ups` adds to a task row, and what stands in for
/// it on a database the app has not yet migrated.
const WAITING_COLUMNS: &str = "m.waitingOn, m.waitingFollowUpAt, m.followUpOfTaskId";
const NO_WAITING_COLUMNS: &str = "NULL, NULL, NULL";
const WAITING_MIGRATION: &str = "v20_waiting_follow_ups";

/// The board column a waiting task is filed in (`WaitingFollowUp`).
const WAITING_COLUMN: &str = "waiting-on";

/// One task row with the metadata the tools show beside it.
struct TaskRow {
    id: String,
    list_id: String,
    parent_task_id: Option<String>,
    title: String,
    notes: String,
    status: String,
    sort_order: i64,
    due_at: Option<String>,
    estimate_seconds: Option<i64>,
    item_kind: Option<String>,
    is_promoted: Option<bool>,
    archived_at: Option<String>,
    completed_at: Option<String>,
    kanban_column: Option<String>,
    links_json: Option<String>,
    recurrence_rule: Option<String>,
    has_metadata: bool,
    waiting_on: Option<String>,
    follow_up_at: Option<String>,
    follow_up_of: Option<String>,
}

impl TaskRow {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(TaskRow {
            id: row.get(0)?,
            list_id: row.get(1)?,
            parent_task_id: row.get(2)?,
            title: row.get(3)?,
            notes: row.get(4)?,
            status: row.get(5)?,
            sort_order: row.get(6)?,
            due_at: row.get(7)?,
            estimate_seconds: row.get(8)?,
            item_kind: row.get(9)?,
            is_promoted: row.get(10)?,
            archived_at: row.get(11)?,
            completed_at: row.get(12)?,
            kanban_column: row.get(13)?,
            links_json: row.get(14)?,
            recurrence_rule: row.get(15)?,
            has_metadata: row.get(16)?,
            waiting_on: row.get(17)?,
            follow_up_at: row.get(18)?,
            follow_up_of: row.get(19)?,
        })
    }

    fn links(&self) -> Vec<String> {
        decode_links(self.links_json.as_deref())
    }

    fn is_list(&self) -> bool {
        self.item_kind.as_deref() == Some("list")
    }

    fn to_json(&self) -> Value {
        let mut value = json!({
            "id": self.id,
            "list_id": self.list_id,
            "parent_task_id": self.parent_task_id,
            "title": self.title,
            "notes": self.notes,
            "status": self.status,
            // Nil is a pre-existing ordinary task; the app reads it as one.
            "kind": self.item_kind.as_deref().unwrap_or("task"),
            "sort_order": self.sort_order,
            "kanban_column": self.kanban_column,
            "external_links": self.links(),
        });
        let object = value.as_object_mut().expect("object literal");
        // Only what is set, so a tree of a hundred tasks is not a hundred
        // copies of the same six nulls.
        for (key, field) in [
            ("due_at", &self.due_at),
            ("archived_at", &self.archived_at),
            ("completed_at", &self.completed_at),
        ] {
            if field.is_some() {
                object.insert(key.into(), json!(local_string(field)));
            }
        }
        if let Some(seconds) = self.estimate_seconds {
            object.insert("estimate_seconds".into(), json!(seconds));
        }
        if self.is_promoted == Some(true) {
            object.insert("is_promoted".into(), json!(true));
        }
        if let Some(tag) = &self.waiting_on {
            object.insert("waiting_on".into(), json!(tag));
        }
        if self.follow_up_at.is_some() {
            object.insert(
                "follow_up_at".into(),
                json!(local_string(&self.follow_up_at)),
            );
        }
        if let Some(source) = &self.follow_up_of {
            object.insert("follow_up_of".into(), json!(source));
        }
        if let Some(rule) = self
            .recurrence_rule
            .as_deref()
            .filter(|rule| !rule.is_empty())
        {
            object.insert("recurrence_rule".into(), json!(rule));
        }
        value
    }
}

struct ListRow {
    id: String,
    workspace_id: String,
    folder_id: Option<String>,
    name: String,
    color_hex: Option<String>,
    sort_order: i64,
    is_archived: bool,
    system_role: Option<String>,
    visible_root_task_id: Option<String>,
    completed_at: Option<String>,
}

const LIST_COLUMNS: &str = "id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, \
     systemRole, visibleRootTaskId, completedAt";

impl ListRow {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(ListRow {
            id: row.get(0)?,
            workspace_id: row.get(1)?,
            folder_id: row.get(2)?,
            name: row.get(3)?,
            color_hex: row.get(4)?,
            sort_order: row.get(5)?,
            is_archived: row.get(6)?,
            system_role: row.get(7)?,
            visible_root_task_id: row.get(8)?,
            completed_at: row.get(9)?,
        })
    }

    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "folder_id": self.folder_id,
            "sort_order": self.sort_order,
            "is_archived": self.is_archived,
            "system_role": self.system_role,
            "visible_root_task_id": self.visible_root_task_id,
            "completed_at": local_string(&self.completed_at),
        })
    }
}

/// What a write changes about a task. `None` leaves the field alone.
#[derive(Default)]
pub struct TaskEdit {
    pub title: Option<String>,
    pub notes: Option<String>,
    pub external_links: Option<Vec<String>>,
    pub status: Option<String>,
    /// `Some(None)` clears the column, which sends the card back to the
    /// board's first column.
    pub kanban_column: Option<Option<String>>,
    /// "task" or "list": `setItemKind`, which makes a task a nested list in
    /// place, or back.
    pub kind: Option<String>,
    /// Pin a nested list to the sidebar: `setNestedListPromoted`.
    pub pinned: Option<bool>,
    /// Who or what it waits on. `Some(None)` clears it. Either this or
    /// `follow_up_at` files the task in Waiting on, as `setWaiting` does.
    pub waiting_on: Option<Option<String>>,
    /// When to chase it, as typed: `2026-10-08 14:00`, local time, or RFC 3339.
    /// `Some(None)` clears it. The app makes the follow-up task when it is due.
    pub follow_up_at: Option<Option<String>>,
}

impl TaskEdit {
    fn is_empty(&self) -> bool {
        self.changes() == 0
    }

    fn changes(&self) -> usize {
        [
            self.title.is_some() || self.notes.is_some(),
            self.external_links.is_some(),
            self.status.is_some(),
            self.kanban_column.is_some(),
            self.kind.is_some(),
            self.pinned.is_some(),
            self.waiting_on.is_some() || self.follow_up_at.is_some(),
        ]
        .iter()
        .filter(|set| **set)
        .count()
    }

    /// The label the app gives the same edit when it is only one edit, and
    /// "Edit Task" for a combination the app has no single action for.
    fn label(&self) -> &'static str {
        if self.changes() > 1 {
            return "Edit Task";
        }
        if self.status.is_some() {
            return "Change Status";
        }
        if self.kanban_column.is_some() {
            return "Move Task";
        }
        if self.waiting_on.is_some() || self.follow_up_at.is_some() {
            return "Waiting On";
        }
        match (self.kind.as_deref(), self.pinned) {
            (Some("list"), _) => "Convert to List",
            (Some(_), _) => "Convert to Task",
            (_, Some(true)) => "Promote List",
            (_, Some(false)) => "Unpin List",
            _ => "Edit Task",
        }
    }
}

pub struct NewTask {
    pub list_id: String,
    pub title: String,
    pub parent_task_id: Option<String>,
    pub notes: String,
    pub external_links: Vec<String>,
    pub kanban_column: Option<String>,
    pub kind: String,
    pub at_top: bool,
}

impl Workspace {
    // -- reading -------------------------------------------------------------

    /// Folders, lists and nested lists: everything the sidebar shows, flat,
    /// with the ids that connect them.
    pub fn tree(&self, include_archived: bool) -> Result<Value> {
        let connection = self.open()?;
        let workspace = workspace_row(&connection)?;

        let folders = collect(
            &connection,
            "SELECT id, name, parentFolderId, sortOrder FROM list_folders \
             WHERE workspaceId = ?1 ORDER BY sortOrder, createdAt, id",
            [&workspace.0],
            |row| {
                Ok(json!({
                    "id": row.get::<_, String>(0)?,
                    "name": row.get::<_, String>(1)?,
                    "parent_folder_id": row.get::<_, Option<String>>(2)?,
                    "sort_order": row.get::<_, i64>(3)?,
                }))
            },
        )?;

        let archived = if include_archived {
            ""
        } else {
            "AND isArchived = 0"
        };
        let lists = collect(
            &connection,
            &format!(
                "SELECT {LIST_COLUMNS}, \
                 (SELECT COUNT(*) FROM tasks t WHERE t.listId = task_lists.id AND t.status = 'open') \
                 FROM task_lists WHERE workspaceId = ?1 {archived} \
                 ORDER BY sortOrder, createdAt, id"
            ),
            [&workspace.0],
            |row| {
                let mut list = ListRow::from_row(row)?.to_json();
                list["open_task_count"] = json!(row.get::<_, i64>(10)?);
                Ok(list)
            },
        )?;

        // A nested list is a task with `itemKind = 'list'`, other than a
        // list's own visible root, which the sidebar shows as the list itself.
        let nested = collect(
            &connection,
            &format!(
                "SELECT t.id, t.title, t.listId, t.parentTaskId, t.status, t.isPromoted, \
                 t.archivedAt FROM tasks t JOIN task_lists l ON l.id = t.listId \
                 WHERE l.workspaceId = ?1 AND t.itemKind = 'list' \
                 AND t.id IS NOT l.visibleRootTaskId {archived} \
                 ORDER BY t.listId, t.sortOrder, t.createdAt, t.id",
                archived = if include_archived {
                    ""
                } else {
                    "AND l.isArchived = 0 AND t.archivedAt IS NULL"
                }
            ),
            [&workspace.0],
            |row| {
                Ok(json!({
                    "id": row.get::<_, String>(0)?,
                    "title": row.get::<_, String>(1)?,
                    "list_id": row.get::<_, String>(2)?,
                    "parent_task_id": row.get::<_, Option<String>>(3)?,
                    "status": row.get::<_, String>(4)?,
                    "is_promoted": row.get::<_, Option<bool>>(5)?.unwrap_or(false),
                    "archived_at": local_string(&row.get::<_, Option<String>>(6)?),
                }))
            },
        )?;

        Ok(json!({
            "workspace_id": workspace.0,
            "workspace": workspace.1,
            "folders": folders,
            "lists": lists,
            "nested_lists": nested,
        }))
    }

    /// One list's tasks as a tree, children nested under their parents.
    pub fn tasks(
        &self,
        list_id: &str,
        parent_task_id: Option<&str>,
        include_closed: bool,
    ) -> Result<Value> {
        let connection = self.open()?;
        let list = list_row(&connection, list_id)?;
        let rows = task_rows(&connection, "t.listId = ?1", [list_id])?;
        if let Some(parent) = parent_task_id
            && !rows.iter().any(|row| row.id == parent)
        {
            return Err(ToolError::new(format!(
                "No task {parent} in list {list_id}."
            )));
        }

        let mut children: HashMap<Option<&str>, Vec<&TaskRow>> = HashMap::new();
        for row in &rows {
            children
                .entry(row.parent_task_id.as_deref())
                .or_default()
                .push(row);
        }
        let mut visited = HashSet::new();
        let mut shown = 0;
        let tree = build_tree(
            parent_task_id,
            &children,
            include_closed,
            &mut visited,
            &mut shown,
        );

        Ok(json!({
            "list": list.to_json(),
            "parent_task_id": parent_task_id,
            "task_count": shown,
            "tasks": tree,
        }))
    }

    /// The list a task belongs to, so a caller adding a subtask need only
    /// name its parent.
    pub fn list_of_task(&self, task_id: &str) -> Result<String> {
        Ok(task_row(&self.open()?, task_id)?.list_id)
    }

    // -- writing -------------------------------------------------------------

    /// `WorkspaceStore.createTask`, with the notes, links and column the
    /// editor would otherwise add in a second step folded into the one undo
    /// group.
    pub fn add_task(&self, new: NewTask) -> Result<Value> {
        let title = non_empty(&new.title, "title")?;
        let column = normalized_column(new.kanban_column.as_deref());
        let links = normalized_links(&new.external_links);
        if !matches!(new.kind.as_str(), "task" | "list") {
            return Err(ToolError::new("kind must be 'task' or 'list'."));
        }
        let label = if new.kind == "list" {
            "New Nested List"
        } else {
            "New Task"
        };
        self.journalled(label, |tx, now| {
            list_row(tx, &new.list_id)?;
            if let Some(parent) = new.parent_task_id.as_deref() {
                let parent = task_row(tx, parent)?;
                if parent.list_id != new.list_id {
                    return Err(ToolError::new(format!(
                        "Task {} is in list {}, not {}. Pass the parent's own list, or omit list_id.",
                        parent.id, parent.list_id, new.list_id
                    )));
                }
            }
            let parent = new.parent_task_id.as_deref();
            let order = next_task_order(tx, &new.list_id, parent)?;
            let id = new_id();
            tx.execute(
                "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, \
                 dueAt, estimateSeconds, createdAt, updatedAt, sourceSystem, sourceId, itemKind, \
                 isPromoted, archivedAt, completedAt) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 'open', ?6, NULL, NULL, ?7, ?7, NULL, NULL, ?8, \
                 NULL, NULL, NULL)",
                params![id, new.list_id, parent, title, new.notes, order, now, new.kind],
            )
            .map_err(map_write_error)?;
            if !links.is_empty() || column.is_some() {
                tx.execute(
                    "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, \
                     updatedAt) VALUES (?1, '[]', ?2, ?3, ?4)",
                    params![id, encode_links(&links), column, now],
                )
                .map_err(map_write_error)?;
            }
            if new.at_top {
                let mut siblings = sibling_ids(tx, &new.list_id, parent)?;
                siblings.retain(|sibling| sibling != &id);
                siblings.insert(0, id.clone());
                persist_task_order(tx, &siblings, now)?;
            }
            Ok(task_row(tx, &id)?.to_json())
        })
    }

    /// The editor's save (`updateTaskRecord`, `updateEditorMetadata`),
    /// `setStatus` and `setKanbanColumn`, as one undo step. Only fields that
    /// actually change are written, so a no-op call leaves no undo step.
    pub fn update_task(&self, task_id: &str, edit: TaskEdit) -> Result<Value> {
        if edit.is_empty() {
            return Err(ToolError::new(
                "No updates provided. Pass title, notes, external_links, status, kanban_column, \
                 kind, pinned, waiting_on and/or follow_up_at.",
            ));
        }
        let title = edit
            .title
            .as_deref()
            .map(|title| non_empty(title, "title"))
            .transpose()?;
        if let Some(status) = edit.status.as_deref()
            && !matches!(status, "open" | "completed" | "cancelled")
        {
            return Err(ToolError::new(
                "status must be 'open', 'completed' or 'cancelled'.",
            ));
        }
        if let Some(kind) = edit.kind.as_deref()
            && !matches!(kind, "task" | "list")
        {
            return Err(ToolError::new("kind must be 'task' or 'list'."));
        }
        let follow_up_at = match edit.follow_up_at.as_ref() {
            Some(Some(text)) if !text.trim().is_empty() => Some(Some(parse_follow_up(text)?)),
            Some(_) => Some(None),
            None => None,
        };
        let label = edit.label();

        self.journalled(label, |tx, now| {
            let task = task_row(tx, task_id)?;

            let new_title = title.clone().unwrap_or_else(|| task.title.clone());
            let new_notes = edit.notes.clone().unwrap_or_else(|| task.notes.clone());
            if new_title != task.title || new_notes != task.notes {
                tx.execute(
                    "UPDATE tasks SET title = ?1, notes = ?2, updatedAt = ?3 WHERE id = ?4",
                    params![new_title, new_notes, now, task.id],
                )
                .map_err(map_write_error)?;
            }

            if let Some(status) = edit.status.as_deref()
                && status != task.status
            {
                // `setStatus`: stamp only a task that is newly closed, and
                // clear the stamp on reopening.
                let was_open = task.completed_at.is_none();
                let recurs = task
                    .recurrence_rule
                    .as_deref()
                    .is_some_and(|rule| !rule.trim().is_empty());
                if status != "open" && was_open && recurs && !task.is_list() {
                    return Err(ToolError::new(format!(
                        "\"{}\" repeats ({}). Complete it in Takt, which schedules the next \
                         occurrence; completing it here would end the series.",
                        task.title,
                        task.recurrence_rule.as_deref().unwrap_or_default()
                    )));
                }
                let completed_at = if status == "open" {
                    None
                } else {
                    Some(task.completed_at.clone().unwrap_or_else(|| now.to_string()))
                };
                tx.execute(
                    "UPDATE tasks SET status = ?1, completedAt = ?2, updatedAt = ?3 WHERE id = ?4",
                    params![status, completed_at, now, task.id],
                )
                .map_err(map_write_error)?;
                if status != "open" && was_open {
                    expire_habits(tx, &task.id, now)?;
                }
            }

            if let Some(links) = edit.external_links.as_ref() {
                let links = normalized_links(links);
                if links != task.links() {
                    if task.has_metadata {
                        tx.execute(
                            "UPDATE task_metadata SET externalLinksJSON = ?1, updatedAt = ?2 \
                             WHERE taskId = ?3",
                            params![encode_links(&links), now, task.id],
                        )
                    } else {
                        tx.execute(
                            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, \
                             updatedAt) VALUES (?1, '[]', ?2, ?3)",
                            params![task.id, encode_links(&links), now],
                        )
                    }
                    .map_err(map_write_error)?;
                }
            }

            if let Some(column) = edit.kanban_column.as_ref() {
                let column = normalized_column(column.as_deref());
                if column != task.kanban_column {
                    upsert_kanban_column(tx, &task.id, column.as_deref(), now)?;
                }
            }

            if edit.waiting_on.is_some() || follow_up_at.is_some() {
                set_waiting(
                    tx,
                    &task.id,
                    edit.waiting_on
                        .as_ref()
                        .map(|tag| normalized_tag(tag.as_deref())),
                    follow_up_at.clone(),
                    now,
                )?;
            }

            // Kind before pinning, so "make this a nested list and pin it" is
            // one call rather than two.
            let mut is_list = task.is_list();
            if let Some(kind) = edit.kind.as_deref()
                && kind != task.item_kind.as_deref().unwrap_or("task")
            {
                // `setItemKind`'s guards: a transport wrapper is already
                // represented by its list, and the timer's task stays put.
                if exists(
                    tx,
                    "SELECT EXISTS(SELECT 1 FROM task_lists WHERE visibleRootTaskId = ?1)",
                    &task.id,
                )? {
                    return Err(ToolError::new(format!(
                        "\"{}\" is the visible root of a list, and already is that list.",
                        task.title
                    )));
                }
                if exists(
                    tx,
                    "SELECT EXISTS(SELECT 1 FROM focus_sessions \
                     WHERE activeTaskId = ?1 AND phase <> 'finished')",
                    &task.id,
                )? {
                    return Err(ToolError::new(format!(
                        "\"{}\" is the focus timer's current task. Finish the block first.",
                        task.title
                    )));
                }
                let sql = if kind == "task" {
                    "UPDATE tasks SET itemKind = 'task', isPromoted = NULL, archivedAt = NULL, \
                     updatedAt = ?1 WHERE id = ?2"
                } else {
                    "UPDATE tasks SET itemKind = 'list', updatedAt = ?1 WHERE id = ?2"
                };
                tx.execute(sql, params![now, task.id])
                    .map_err(map_write_error)?;
                is_list = kind == "list";
            }

            if let Some(pinned) = edit.pinned {
                if !is_list {
                    return Err(ToolError::new(format!(
                        "\"{}\" is a task, not a nested list. Pass kind \"list\" to make it one.",
                        task.title
                    )));
                }
                // Re-read, since a kind change above can have cleared it.
                let current: Option<bool> = tx
                    .query_row(
                        "SELECT isPromoted FROM tasks WHERE id = ?1",
                        [&task.id],
                        |row| row.get(0),
                    )
                    .map_err(map_query_error)?;
                if (current == Some(true)) != pinned {
                    tx.execute(
                        "UPDATE tasks SET isPromoted = ?1, updatedAt = ?2 WHERE id = ?3",
                        params![pinned, now, task.id],
                    )
                    .map_err(map_write_error)?;
                }
            }

            Ok(task_row(tx, &task.id)?.to_json())
        })
    }

    /// Reparent and/or reorder. `moveTask` for the reparent, including its
    /// "a list means that list's visible root" rule, then the dense
    /// re-numbering `moveTaskWithinSiblings` does for the position.
    pub fn move_task(
        &self,
        task_id: &str,
        parent_task_id: Option<&str>,
        list_id: Option<&str>,
        position: Option<i64>,
    ) -> Result<Value> {
        if parent_task_id.is_none() && list_id.is_none() && position.is_none() {
            return Err(ToolError::new(
                "Nothing to do. Pass parent_task_id, list_id and/or position.",
            ));
        }
        if position.is_some_and(|position| position < 1) {
            return Err(ToolError::new("position must be 1 or greater."));
        }
        let label = if parent_task_id.is_none() && list_id.is_none() {
            "Reorder Task"
        } else {
            "Move Task"
        };

        self.journalled(label, |tx, now| {
            let task = task_row(tx, task_id)?;
            let (destination_list, destination_parent) = match (parent_task_id, list_id) {
                (Some(parent), list) => {
                    let parent = task_row(tx, parent)?;
                    if let Some(list) = list
                        && list != parent.list_id
                    {
                        return Err(ToolError::new(format!(
                            "Task {} is in list {}, not {list}.",
                            parent.id, parent.list_id
                        )));
                    }
                    (parent.list_id, Some(parent.id))
                }
                (None, Some(list)) => {
                    list_row(tx, list)?;
                    (list.to_string(), visible_root_parent(tx, list)?)
                }
                (None, None) => (task.list_id.clone(), task.parent_task_id.clone()),
            };

            let descendants = descendant_ids(tx, &task.id)?;
            if let Some(parent) = destination_parent.as_deref()
                && (parent == task.id || descendants.contains(parent))
            {
                return Err(ToolError::new(
                    "A task cannot be moved into itself or one of its subtasks.",
                ));
            }

            if destination_list != task.list_id || destination_parent != task.parent_task_id {
                if destination_list != task.list_id {
                    // One statement over the subtree, as `WorkspaceStore.moveTask`
                    // writes it. The change_log triggers are per row either
                    // way, so the undo step records the same rows; sorting
                    // the ids gives them the same order too.
                    let mut ids: Vec<&str> = descendants.iter().map(String::as_str).collect();
                    ids.push(&task.id);
                    ids.sort_unstable();
                    let placeholders = (0..ids.len())
                        .map(|index| format!("?{}", index + 3))
                        .collect::<Vec<_>>()
                        .join(", ");
                    let mut values: Vec<&dyn rusqlite::ToSql> = vec![&destination_list, &now];
                    values.extend(ids.iter().map(|id| id as &dyn rusqlite::ToSql));
                    tx.execute(
                        &format!(
                            "UPDATE tasks SET listId = ?1, updatedAt = ?2 WHERE id IN ({placeholders})"
                        ),
                        values.as_slice(),
                    )
                    .map_err(map_write_error)?;
                }
                let order = next_task_order(tx, &destination_list, destination_parent.as_deref())?;
                tx.execute(
                    "UPDATE tasks SET parentTaskId = ?1, sortOrder = ?2, updatedAt = ?3 \
                     WHERE id = ?4",
                    params![destination_parent, order, now, task.id],
                )
                .map_err(map_write_error)?;
            }

            if let Some(position) = position {
                let mut siblings =
                    sibling_ids(tx, &destination_list, destination_parent.as_deref())?;
                let before = siblings.clone();
                siblings.retain(|sibling| sibling != &task.id);
                let index = usize::try_from(position - 1)
                    .unwrap_or(0)
                    .min(siblings.len());
                siblings.insert(index, task.id.clone());
                if siblings != before {
                    persist_task_order(tx, &siblings, now)?;
                }
            }

            Ok(task_row(tx, &task.id)?.to_json())
        })
    }

    /// `WorkspaceStore.moveTaskToFolder`: the task becomes a standalone list of
    /// its own, named after it, in `folder_id` or at the top level. The task
    /// record survives as the new list's visible root, so its subtasks become
    /// the list's contents with their identities and hierarchy intact. One
    /// undo step, as in the app.
    pub fn task_to_list(&self, task_id: &str, folder_id: Option<&str>) -> Result<Value> {
        let label = if folder_id.is_some() {
            "Move Item to Folder"
        } else {
            "Move Item to Top Level"
        };
        self.journalled(label, |tx, now| {
            let task = task_row(tx, task_id)?;
            let source = list_row(tx, &task.list_id)?;
            if let Some(folder) = folder_id {
                folder_in_workspace(tx, folder, &source.workspace_id)?;
            }
            // Do not extract a transport wrapper and leave a broken source list.
            if source.visible_root_task_id.as_deref() == Some(task.id.as_str()) {
                return Err(ToolError::new(format!(
                    "\"{}\" is the visible root of list \"{}\" — it already is that list. \
                     Move the list with workspace_list_move instead.",
                    task.title, source.name
                )));
            }

            let list_id = new_id();
            let order = next_list_order(tx, &source.workspace_id, folder_id)?;
            let archived = task.is_list() && task.archived_at.is_some();
            let completed_at = (task.is_list() && task.status != "open").then_some(now);
            tx.execute(
                "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, \
                 isArchived, createdAt, updatedAt, systemRole, visibleRootTaskId, completedAt) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, NULL, ?9, ?10)",
                params![
                    list_id,
                    source.workspace_id,
                    folder_id,
                    task.title,
                    source.color_hex,
                    order,
                    archived,
                    now,
                    task.id,
                    completed_at
                ],
            )
            .map_err(map_write_error)?;

            let mut ids: Vec<String> = descendant_ids(tx, &task.id)?.into_iter().collect();
            ids.push(task.id.clone());
            ids.sort();
            for id in &ids {
                tx.execute(
                    "UPDATE tasks SET listId = ?1, updatedAt = ?2 WHERE id = ?3",
                    params![list_id, now, id],
                )
                .map_err(map_write_error)?;
            }
            // Computed at the same point as the Swift, where the task has the
            // new list but still its old parent.
            let order = next_task_order(tx, &list_id, None)?;
            tx.execute(
                "UPDATE tasks SET parentTaskId = NULL, sortOrder = ?1, itemKind = 'list', \
                 isPromoted = NULL, archivedAt = NULL, status = 'open', updatedAt = ?2 \
                 WHERE id = ?3",
                params![order, now, task.id],
            )
            .map_err(map_write_error)?;

            Ok(json!({
                "list": list_row(tx, &list_id)?.to_json(),
                "root_task": task_row(tx, &task.id)?.to_json(),
                "moved_task_count": ids.len(),
            }))
        })
    }

    /// `WorkspaceStore.deleteTask`. The subtree goes with it, by the schema's
    /// cascade, and all of it comes back on undo.
    pub fn delete_task(&self, task_id: &str) -> Result<Value> {
        self.journalled("Delete Task", |tx, _now| {
            // The write is the Rust core's, shared with the apps.
            let deleted = takt_core::tasks::delete_task(tx, task_id).map_err(map_core_error)?;
            Ok(json!({
                "deleted": deleted.id,
                "title": deleted.title,
                "subtasks_deleted": deleted.subtasks_deleted,
            }))
        })
    }

    /// `WorkspaceStore.createFolder`.
    pub fn create_folder(&self, name: &str, parent_folder_id: Option<&str>) -> Result<Value> {
        let name = non_empty(name, "name")?;
        self.journalled("New Folder", |tx, _now| {
            let workspace = workspace_row(tx)?.0;
            // The write is the Rust core's, shared with the apps.
            let created = takt_core::lists::create_folder(
                tx,
                &workspace,
                &name,
                parent_folder_id,
                Utc::now().timestamp_millis(),
            )
            .map_err(map_core_error)?;
            Ok(json!({
                "id": created.id,
                "name": created.name,
                "parent_folder_id": parent_folder_id,
                "sort_order": created.sort_order,
            }))
        })
    }

    /// `WorkspaceStore.createList`.
    pub fn create_list(&self, name: &str, folder_id: Option<&str>) -> Result<Value> {
        let name = non_empty(name, "name")?;
        self.journalled("New List", |tx, _now| {
            let workspace = workspace_row(tx)?.0;
            // The write is the Rust core's, shared with the apps.
            let created = takt_core::lists::create_list(
                tx,
                &workspace,
                &name,
                folder_id,
                Utc::now().timestamp_millis(),
            )
            .map_err(map_core_error)?;
            Ok(list_row(tx, &created.id)?.to_json())
        })
    }

    /// `WorkspaceStore.moveList`: into a folder, or to the top level with
    /// `None`. Appended at the end of its new siblings.
    pub fn move_list(&self, list_id: &str, folder_id: Option<&str>) -> Result<Value> {
        self.journalled("Move List", |tx, now| {
            let list = list_row(tx, list_id)?;
            if let Some(folder) = folder_id {
                folder_in_workspace(tx, folder, &list.workspace_id)?;
            }
            if list.folder_id.as_deref() != folder_id {
                let order = next_list_order(tx, &list.workspace_id, folder_id)?;
                tx.execute(
                    "UPDATE task_lists SET folderId = ?1, sortOrder = ?2, updatedAt = ?3 \
                     WHERE id = ?4",
                    params![folder_id, order, now, list.id],
                )
                .map_err(map_write_error)?;
            }
            Ok(list_row(tx, &list.id)?.to_json())
        })
    }

    /// `WorkspaceStore.deleteList`. Its tasks go with it, by the schema's
    /// cascade, and all of it comes back on undo. The Inbox is refused.
    pub fn delete_list(&self, list_id: &str) -> Result<Value> {
        self.journalled("Delete List", |tx, _now| {
            // The write is the Rust core's, shared with the apps.
            let deleted = takt_core::lists::delete_list(tx, list_id).map_err(map_core_error)?;
            Ok(json!({
                "deleted": deleted.id,
                "name": deleted.name,
                "tasks_deleted": deleted.tasks_deleted,
            }))
        })
    }

    // -- the journal ---------------------------------------------------------

    /// Runs one write as one undoable step: `journalledWrite` in
    /// `WorkspaceStore+Undo.swift`, statement for statement.
    ///
    /// A failure anywhere inside drops the transaction, which rolls back the
    /// rows, the journal entries and the armed `undo_control` together, so a
    /// refused write leaves nothing behind — not even a disarmed flag.
    fn journalled<T>(
        &self,
        label: &str,
        work: impl FnOnce(&Transaction, &str) -> Result<T>,
    ) -> Result<T> {
        let mut connection = self.open_for_writing()?;
        let tx = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(map_write_error)?;
        let now = stored_string(Utc::now());
        // The journal's bookkeeping is the Rust core's (core/src/journal.rs),
        // the same code the app's undo replays these steps with.
        let group = takt_core::journal::begin(&tx, &format!("{LABEL_PREFIX}{label}"))
            .map_err(map_core_error)?;
        let result = work(&tx, &now)?;
        takt_core::journal::finish(&tx, &group).map_err(map_core_error)?;
        tx.commit().map_err(map_write_error)?;
        Ok(result)
    }

    fn open_for_writing(&self) -> Result<Connection> {
        if !self.database_path.exists() {
            return Err(ToolError::new(format!(
                "No workspace database at {}. Open Takt once, or set database_path.",
                self.database_path.display()
            )));
        }
        // No CREATE flag: a missing database is reported above, never made.
        let connection = Connection::open_with_flags(
            &self.database_path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_URI,
        )
        .map_err(|error| {
            ToolError::new(format!(
                "Could not open {} for writing: {error}",
                self.database_path.display()
            ))
        })?;
        connection
            .busy_timeout(BUSY_TIMEOUT)
            .map_err(map_write_error)?;
        connection
            .execute_batch("PRAGMA foreign_keys = ON")
            .map_err(map_write_error)?;
        // An error here (no `grdb_migrations` table at all) is the same
        // answer as a missing row: this is not a database the app has made.
        let migrated = has_migration(&connection, REQUIRED_MIGRATION).unwrap_or(false);
        if !migrated {
            return Err(ToolError::new(format!(
                "The workspace at {} predates the schema this build of takt writes \
                 ({REQUIRED_MIGRATION}). Open an up-to-date Takt once to migrate it.",
                self.database_path.display()
            )));
        }
        Ok(connection)
    }
}

// -- row helpers --------------------------------------------------------------

fn build_tree(
    parent: Option<&str>,
    children: &HashMap<Option<&str>, Vec<&TaskRow>>,
    include_closed: bool,
    visited: &mut HashSet<String>,
    shown: &mut usize,
) -> Vec<Value> {
    let mut nodes = Vec::new();
    for row in children.get(&parent).map(Vec::as_slice).unwrap_or_default() {
        // A closed task hides its subtree, as the app's "hide completed" does.
        if (!include_closed && row.status != "open") || !visited.insert(row.id.clone()) {
            continue;
        }
        *shown += 1;
        let mut node = row.to_json();
        let nested = build_tree(Some(&row.id), children, include_closed, visited, shown);
        if !nested.is_empty() {
            node["children"] = json!(nested);
        }
        nodes.push(node);
    }
    nodes
}

fn exists(connection: &Connection, sql: &str, id: &str) -> Result<bool> {
    connection
        .query_row(sql, [id], |row| row.get(0))
        .map_err(map_query_error)
}

fn collect<P: rusqlite::Params>(
    connection: &Connection,
    sql: &str,
    params: P,
    map: impl FnMut(&Row) -> rusqlite::Result<Value>,
) -> Result<Vec<Value>> {
    let mut statement = connection.prepare(sql).map_err(map_query_error)?;
    let rows = statement
        .query_map(params, map)
        .map_err(map_query_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(map_query_error)?;
    Ok(rows)
}

fn task_rows<P: rusqlite::Params>(
    connection: &Connection,
    filter: &str,
    params: P,
) -> Result<Vec<TaskRow>> {
    let waiting = if has_migration(connection, WAITING_MIGRATION)? {
        WAITING_COLUMNS
    } else {
        NO_WAITING_COLUMNS
    };
    let mut statement = connection
        .prepare(&format!(
            "SELECT {TASK_COLUMNS}, {waiting} FROM tasks t \
             LEFT JOIN task_metadata m ON m.taskId = t.id \
             WHERE {filter} ORDER BY t.sortOrder, t.createdAt, t.id"
        ))
        .map_err(map_query_error)?;
    let rows = statement
        .query_map(params, TaskRow::from_row)
        .map_err(map_query_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(map_query_error)?;
    Ok(rows)
}

fn task_row(connection: &Connection, id: &str) -> Result<TaskRow> {
    task_rows(connection, "t.id = ?1", [id])?
        .into_iter()
        .next()
        .ok_or_else(|| ToolError::new(format!("No task with id {id}.")))
}

fn list_row(connection: &Connection, id: &str) -> Result<ListRow> {
    connection
        .query_row(
            &format!("SELECT {LIST_COLUMNS} FROM task_lists WHERE id = ?1"),
            [id],
            ListRow::from_row,
        )
        .optional()
        .map_err(map_query_error)?
        .ok_or_else(|| {
            ToolError::new(format!(
                "No list with id {id}. workspace_tree lists the lists and their ids."
            ))
        })
}

/// The workspace there is. The app makes exactly one.
fn workspace_row(connection: &Connection) -> Result<(String, String)> {
    connection
        .query_row(
            "SELECT id, name FROM workspaces ORDER BY createdAt LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(map_query_error)?
        .ok_or_else(|| {
            ToolError::new("The workspace database has no workspace yet. Open Takt once.")
        })
}

fn folder_in_workspace(connection: &Connection, folder_id: &str, workspace_id: &str) -> Result<()> {
    let found: Option<String> = connection
        .query_row(
            "SELECT workspaceId FROM list_folders WHERE id = ?1",
            [folder_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(map_query_error)?;
    match found {
        Some(workspace) if workspace == workspace_id => Ok(()),
        _ => Err(ToolError::new(format!(
            "No folder with id {folder_id}. workspace_tree lists the folders and their ids."
        ))),
    }
}

/// `visibleRootParentTaskID`: the imported wrapper whose children the app
/// shows as the list's top level, while it is still the only root.
fn visible_root_parent(connection: &Connection, list_id: &str) -> Result<Option<String>> {
    let Some(root) = list_row(connection, list_id)?.visible_root_task_id else {
        return Ok(None);
    };
    let roots: Vec<String> = connection
        .prepare("SELECT id FROM tasks WHERE listId = ?1 AND parentTaskId IS NULL")
        .and_then(|mut statement| {
            statement
                .query_map([list_id], |row| row.get(0))?
                .collect::<rusqlite::Result<Vec<_>>>()
        })
        .map_err(map_query_error)?;
    Ok((roots.len() == 1 && roots[0] == root).then_some(root))
}

fn descendant_ids(connection: &Connection, task_id: &str) -> Result<HashSet<String>> {
    let ids = connection
        .prepare(
            "WITH RECURSIVE subtree(id) AS ( \
               SELECT id FROM tasks WHERE parentTaskId = ?1 \
               UNION SELECT t.id FROM tasks t JOIN subtree s ON t.parentTaskId = s.id) \
             SELECT id FROM subtree",
        )
        .and_then(|mut statement| {
            statement
                .query_map([task_id], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<HashSet<_>>>()
        })
        .map_err(map_query_error)?;
    Ok(ids)
}

fn sibling_ids(
    connection: &Connection,
    list_id: &str,
    parent: Option<&str>,
) -> Result<Vec<String>> {
    connection
        .prepare(
            "SELECT id FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2 \
             ORDER BY sortOrder, createdAt, id",
        )
        .and_then(|mut statement| {
            statement
                .query_map(params![list_id, parent], |row| row.get(0))?
                .collect::<rusqlite::Result<Vec<_>>>()
        })
        .map_err(map_query_error)
}

/// `persistTaskOrder`: dense, zero-based, every sibling touched.
fn persist_task_order(tx: &Transaction, ids: &[String], now: &str) -> Result<()> {
    for (index, id) in ids.iter().enumerate() {
        tx.execute(
            "UPDATE tasks SET sortOrder = ?1, updatedAt = ?2 WHERE id = ?3",
            params![index as i64, now, id],
        )
        .map_err(map_write_error)?;
    }
    Ok(())
}

fn next_task_order(connection: &Connection, list_id: &str, parent: Option<&str>) -> Result<i64> {
    connection
        .query_row(
            "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks \
             WHERE listId = ?1 AND parentTaskId IS ?2",
            params![list_id, parent],
            |row| row.get(0),
        )
        .map_err(map_query_error)
}

fn next_list_order(
    connection: &Connection,
    workspace_id: &str,
    folder: Option<&str>,
) -> Result<i64> {
    connection
        .query_row(
            "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists \
             WHERE workspaceId = ?1 AND folderId IS ?2",
            params![workspace_id, folder],
            |row| row.get(0),
        )
        .map_err(map_query_error)
}

/// The SQL `setKanbanColumn` runs.
fn upsert_kanban_column(
    tx: &Transaction,
    task_id: &str,
    column: Option<&str>,
    now: &str,
) -> Result<()> {
    tx.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt) \
         VALUES (?1, '[]', '[]', ?2, ?3) \
         ON CONFLICT(taskId) DO UPDATE SET \
           kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt",
        params![task_id, column, now],
    )
    .map_err(map_write_error)?;
    Ok(())
}

// -- values -------------------------------------------------------------------

/// Whether the app has run `identifier` on this database.
fn has_migration(connection: &Connection, identifier: &str) -> Result<bool> {
    exists(
        connection,
        "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?1)",
        identifier,
    )
}

/// `WorkspaceStore.setWaiting`: the tag and the follow-up time, each only
/// when given, and the task filed in Waiting on — leaving Today drops its
/// place in the day. The follow-up task itself is the app's to make, on its
/// next poll, so that it is made by one engine with one deterministic id.
fn set_waiting(
    tx: &Transaction,
    task_id: &str,
    waiting_on: Option<Option<String>>,
    follow_up_at: Option<Option<String>>,
    now: &str,
) -> Result<()> {
    if !has_migration(tx, WAITING_MIGRATION)? {
        return Err(ToolError::new(
            "This workspace predates Waiting on. Open an up-to-date Takt once to migrate it.",
        ));
    }
    tx.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, updatedAt) \
         VALUES (?1, '[]', '[]', ?2) ON CONFLICT(taskId) DO NOTHING",
        params![task_id, now],
    )
    .map_err(map_write_error)?;
    tx.execute(
        "UPDATE task_metadata SET \
           focusRank = CASE WHEN kanbanColumn = 'today' THEN NULL ELSE focusRank END, \
           kanbanColumn = ?2, updatedAt = ?3 \
         WHERE taskId = ?1 AND kanbanColumn IS NOT ?2",
        params![task_id, WAITING_COLUMN, now],
    )
    .map_err(map_write_error)?;
    if let Some(tag) = waiting_on {
        tx.execute(
            "UPDATE task_metadata SET waitingOn = ?2, updatedAt = ?3 WHERE taskId = ?1",
            params![task_id, tag, now],
        )
        .map_err(map_write_error)?;
    }
    if let Some(at) = follow_up_at {
        tx.execute(
            "UPDATE task_metadata SET waitingFollowUpAt = ?2, updatedAt = ?3 WHERE taskId = ?1",
            params![task_id, at, now],
        )
        .map_err(map_write_error)?;
    }
    Ok(())
}

/// `WaitingFollowUp.normalizedTag`: trimmed, at most 40 characters, and
/// nothing at all when empty.
fn normalized_tag(tag: Option<&str>) -> Option<String> {
    let trimmed = tag?.trim();
    (!trimmed.is_empty()).then(|| trimmed.chars().take(40).collect())
}

/// A follow-up time as stored: UTC, whole minutes. Takes `2026-10-08 14:00`
/// or `2026-10-08T14:00` in local time, or an RFC 3339 instant.
fn parse_follow_up(text: &str) -> Result<String> {
    use chrono::{DateTime, Local, NaiveDateTime, TimeZone, Timelike};
    let text = text.trim();
    let instant = DateTime::parse_from_rfc3339(text)
        .map(|date| date.with_timezone(&Utc))
        .ok()
        .or_else(|| {
            [
                "%Y-%m-%d %H:%M",
                "%Y-%m-%dT%H:%M",
                "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%dT%H:%M:%S",
            ]
            .iter()
            .find_map(|format| NaiveDateTime::parse_from_str(text, format).ok())
            .and_then(|naive| Local.from_local_datetime(&naive).earliest())
            .map(|local| local.with_timezone(&Utc))
        })
        .ok_or_else(|| {
            ToolError::new(format!(
                "follow_up_at must be a date and time such as 2026-10-08 14:00, not \"{text}\"."
            ))
        })?;
    let minute = instant
        .with_second(0)
        .and_then(|date| date.with_nanosecond(0))
        .unwrap_or(instant);
    Ok(stored_string(minute))
}

/// Uppercase, as Foundation's `UUID().uuidString` writes them.
/// `WorkspaceStore.expireHabits`: closing a task ends every habit made from
/// it whose expiry is "when the source is done", and takes each one's card
/// out of the column the habit put it in. A no-op on a database the app has
/// not yet migrated to `v19_habit_options`.
fn expire_habits(tx: &Transaction, source_id: &str, now: &str) -> Result<()> {
    if !has_migration(tx, "v19_habit_options")? {
        return Ok(());
    }
    tx.execute(
        "UPDATE task_metadata SET kanbanColumn = NULL, focusRank = NULL, updatedAt = ?2 \
         WHERE taskId IN (SELECT taskId FROM dailies WHERE sourceTaskId = ?1 \
           AND archivedAt IS NULL AND expiryRule = 'source' \
           AND placementColumn = task_metadata.kanbanColumn)",
        params![source_id, now],
    )
    .map_err(map_write_error)?;
    tx.execute(
        "UPDATE dailies SET archivedAt = ?2, updatedAt = ?2 \
         WHERE sourceTaskId = ?1 AND archivedAt IS NULL AND expiryRule = 'source'",
        params![source_id, now],
    )
    .map_err(map_write_error)?;
    Ok(())
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

/// `WorkspaceStore.nonEmptyName`.
fn non_empty(raw: &str, field: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ToolError::new(format!("{field} must not be empty.")));
    }
    Ok(trimmed.to_string())
}

/// `WorkspaceStore.normalizedStrings`: trimmed, blanks dropped, and the first
/// of any case-insensitive duplicates kept.
fn normalized_links(values: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    values
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty() && seen.insert(value.to_lowercase()))
        .map(str::to_string)
        .collect()
}

fn decode_links(json: Option<&str>) -> Vec<String> {
    let values: Vec<String> = json
        .and_then(|json| serde_json::from_str(json).ok())
        .unwrap_or_default();
    normalized_links(&values)
}

fn encode_links(links: &[String]) -> String {
    serde_json::to_string(links).unwrap_or_else(|_| "[]".into())
}

/// `setKanbanColumn`'s trim-to-nil.
fn normalized_column(column: Option<&str>) -> Option<String> {
    column
        .map(str::trim)
        .filter(|column| !column.is_empty())
        .map(str::to_string)
}

fn map_core_error(error: takt_core::CoreError) -> ToolError {
    match error {
        takt_core::CoreError::NoJournal => ToolError::new(
            "The workspace has no undo journal to record into. Open Takt once, then try again.",
        ),
        missing @ takt_core::CoreError::MissingTask { .. } => ToolError::new(missing.to_string()),
        takt_core::CoreError::MissingList { id } => ToolError::new(format!(
            "No list with id {id}. workspace_tree lists the lists and their ids."
        )),
        takt_core::CoreError::MissingFolder { id } => ToolError::new(format!(
            "No folder with id {id}. workspace_tree lists the folders and their ids."
        )),
        permanent @ takt_core::CoreError::SystemListIsPermanent => {
            ToolError::new(permanent.to_string())
        }
        other => ToolError::new(format!("Workspace write failed: {other}")),
    }
}

fn map_write_error(error: rusqlite::Error) -> ToolError {
    let busy = matches!(
        error.sqlite_error_code(),
        Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked)
    );
    if busy {
        return ToolError::new(format!(
            "The workspace stayed locked for {}s — Takt is in the middle of a long write. \
             Nothing was changed; try again.",
            BUSY_TIMEOUT.as_secs()
        ));
    }
    ToolError::new(format!("Workspace write failed: {error}"))
}
