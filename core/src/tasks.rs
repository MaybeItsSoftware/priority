//! Writes to tasks.
//!
//! Step four of docs/rust-core-migration.md moves the task writes here one at
//! a time. Each function takes the caller's transaction, so the CLI can run
//! it inside its own journalled step under its "MCP: " label, and
//! [`crate::workspace::CoreWorkspace`] runs it as the apps' step. Each one
//! names the Swift `WorkspaceStore` method and the Kotlin
//! `WorkspaceRepository` method it replaced.

use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::time::stored;

/// A task to create: everything any client can set when it adds one.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct NewTask {
    pub list_id: String,
    pub title: String,
    pub parent_task_id: Option<String>,
    /// `"task"`, or `"list"` for a nested list.
    pub kind: String,
    pub notes: String,
    pub kanban_column: Option<String>,
    pub start_at_ms: Option<i64>,
    pub due_at_ms: Option<i64>,
    pub estimate_seconds: Option<i64>,
    pub tags: Vec<String>,
    /// 1 to 4; anything else is no priority.
    pub priority: Option<i64>,
    /// Who it waits on; puts it in the waiting column.
    pub waiting_on: Option<String>,
    pub external_links: Vec<String>,
    /// First among its siblings rather than last.
    pub at_top: bool,
    /// A sibling to go beside: below it, or above with `above`.
    pub adjacent_task_id: Option<String>,
    pub above: bool,
}

/// The board column a task waiting on someone goes in.
pub const WAITING_COLUMN: &str = "waiting-on";
/// The longest waiting-on tag kept: it is a chip, not a note.
const MAXIMUM_WAITING_TAG: usize = 40;

/// Creates a task and returns its id. Everything the add field read off the
/// title (tags, priority, estimate, waiting) goes in the same undo step, so
/// undoing a typed task never leaves its estimate behind as a step of its
/// own. Replaces `WorkspaceStore.createTask`, its Kotlin copy and the CLI's
/// `add_task`.
pub fn create_task(
    transaction: &Transaction,
    new: &NewTask,
    now_ms: i64,
) -> Result<String, CoreError> {
    let title = crate::time::non_empty_name(&new.title)?;
    let waiting_on = new
        .waiting_on
        .as_deref()
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .map(|w| w.chars().take(MAXIMUM_WAITING_TAG).collect::<String>());
    // Waiting on someone puts it in that column, as `set_waiting` does.
    let kanban_column = if waiting_on.is_some() {
        Some(WAITING_COLUMN.to_string())
    } else {
        new.kanban_column.clone()
    };
    let tags = normalized_strings(&new.tags);
    let priority = new.priority.filter(|p| (1..=4).contains(p));
    let estimate = new.estimate_seconds.filter(|e| *e > 0);

    let list_exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM task_lists WHERE id = ?1)",
        [&new.list_id],
        |row| row.get(0),
    )?;
    if !list_exists {
        return Err(CoreError::MissingList {
            id: new.list_id.clone(),
        });
    }
    let parent = new.parent_task_id.as_deref();
    if let Some(parent) = parent {
        let parent_list: Option<String> = transaction
            .query_row("SELECT listId FROM tasks WHERE id = ?1", [parent], |row| {
                row.get(0)
            })
            .optional()?;
        // A parent that is gone, or in another list, is a place the task
        // cannot go, as Swift reported it.
        if parent_list.as_deref() != Some(new.list_id.as_str()) {
            return Err(CoreError::InvalidTaskMove);
        }
    }
    let sort_order = next_task_order(transaction, &new.list_id, parent)?;
    let id = crate::lists::new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt,
                            estimateSeconds, createdAt, updatedAt, sourceSystem, sourceId, itemKind,
                            isPromoted, archivedAt, completedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, 'open', ?6, ?7, ?8, ?9, ?9, NULL, NULL, ?10, NULL, NULL, NULL)",
        params![
            id,
            new.list_id,
            parent,
            title,
            new.notes,
            sort_order,
            new.due_at_ms.map(stored),
            estimate,
            now,
            if new.kind == "list" { "list" } else { "task" },
        ],
    )?;
    let has_metadata = kanban_column.is_some()
        || new.start_at_ms.is_some()
        || !tags.is_empty()
        || priority.is_some()
        || waiting_on.is_some()
        || !new.external_links.is_empty();
    if has_metadata {
        transaction.execute(
            "INSERT INTO task_metadata(taskId, priority, startAt, tagsJSON, externalLinksJSON,
                                       kanbanColumn, waitingOn, updatedAt)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                id,
                priority,
                new.start_at_ms.map(stored),
                crate::time::swift_json_strings(&tags),
                crate::time::swift_json_strings(&new.external_links),
                kanban_column,
                waiting_on,
                now,
            ],
        )?;
    }
    if new.at_top || new.adjacent_task_id.is_some() {
        let mut siblings = task_siblings(transaction, &new.list_id, parent)?;
        siblings.retain(|s| *s != id);
        let insertion = match new.adjacent_task_id.as_deref() {
            Some(adjacent) => {
                let index = siblings
                    .iter()
                    .position(|s| s == adjacent)
                    .ok_or(CoreError::InvalidTaskMove)?;
                index + usize::from(!new.above)
            }
            None => 0,
        };
        siblings.insert(insertion, id.clone());
        persist_task_order(transaction, &siblings, now_ms)?;
    }
    Ok(id)
}

/// Tags trimmed, blanks dropped and repeats (ignoring case) kept once, in
/// the order given: `WorkspaceStore.normalizedStrings`.
pub fn normalized_strings(values: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    values
        .iter()
        .map(|v| v.trim())
        .filter(|v| !v.is_empty() && seen.insert(v.to_lowercase()))
        .map(str::to_string)
        .collect()
}

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

/// Moves a task, with its subtree, under `parent_task_id` in `list_id` (or to
/// the top of that list), after the tasks already there. With
/// `to_visible_root` the parent is the list's visible root, the wrapper a
/// list made from an imported project shows the children of. A move into
/// the task itself or below it is refused, as is a parent from another list.
/// Replaces `WorkspaceStore.moveTask`, its Kotlin copy, and the move half of
/// the CLI's `move_task`.
pub fn move_task(
    transaction: &Transaction,
    id: &str,
    list_id: &str,
    parent_task_id: Option<&str>,
    to_visible_root: bool,
    now_ms: i64,
) -> Result<(), CoreError> {
    let (current_list, current_parent) = task_place(transaction, id)?;
    let list_exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM task_lists WHERE id = ?1)",
        [list_id],
        |row| row.get(0),
    )?;
    if !list_exists {
        return Err(CoreError::MissingList {
            id: list_id.to_string(),
        });
    }
    let parent = if to_visible_root {
        visible_root_parent(transaction, list_id)?
    } else {
        parent_task_id.map(str::to_string)
    };
    let descendants = descendant_ids(transaction, id)?;
    if let Some(parent) = parent.as_deref() {
        if parent == id || descendants.iter().any(|d| d == parent) {
            return Err(CoreError::InvalidTaskMove);
        }
        let parent_list: Option<String> = transaction
            .query_row("SELECT listId FROM tasks WHERE id = ?1", [parent], |row| {
                row.get(0)
            })
            .optional()?;
        if parent_list.as_deref() != Some(list_id) {
            return Err(CoreError::InvalidTaskMove);
        }
    }
    if current_list == list_id && current_parent == parent {
        return Ok(());
    }
    let now = stored(now_ms);
    if current_list != list_id {
        // One statement over the subtree, sorted, so the journal records the
        // same rows in the same order whichever client asked.
        let mut ids = descendants;
        ids.push(id.to_string());
        ids.sort_unstable();
        let placeholders = (0..ids.len())
            .map(|index| format!("?{}", index + 3))
            .collect::<Vec<_>>()
            .join(", ");
        let mut values: Vec<&dyn rusqlite::ToSql> = vec![&list_id, &now];
        values.extend(ids.iter().map(|id| id as &dyn rusqlite::ToSql));
        transaction.execute(
            &format!("UPDATE tasks SET listId = ?1, updatedAt = ?2 WHERE id IN ({placeholders})"),
            values.as_slice(),
        )?;
    }
    let sort_order = next_task_order(transaction, list_id, parent.as_deref())?;
    transaction.execute(
        "UPDATE tasks SET parentTaskId = ?1, sortOrder = ?2, updatedAt = ?3 WHERE id = ?4",
        params![parent, sort_order, now, id],
    )?;
    Ok(())
}

/// Puts a task at `index` (from zero, clamped to the end) among its
/// siblings. A position it already holds changes nothing. The CLI's
/// `move_task` with a `position`.
pub fn place_task_at(
    transaction: &Transaction,
    id: &str,
    index: u32,
    now_ms: i64,
) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let before = task_siblings(transaction, &list_id, parent.as_deref())?;
    let mut siblings: Vec<String> = before.iter().filter(|s| *s != id).cloned().collect();
    let index = (index as usize).min(siblings.len());
    siblings.insert(index, id.to_string());
    if siblings != before {
        persist_task_order(transaction, &siblings, now_ms)?;
    }
    Ok(())
}

/// Moves a task `offset` places among its siblings, stopping at either end.
/// Replaces `WorkspaceStore.moveTaskWithinSiblings` and its Kotlin copy.
pub fn move_task_within_siblings(
    transaction: &Transaction,
    id: &str,
    offset: i32,
    now_ms: i64,
) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let mut siblings = task_siblings(transaction, &list_id, parent.as_deref())?;
    let Some(index) = siblings.iter().position(|s| s == id) else {
        return Ok(());
    };
    let last = siblings.len() as i64 - 1;
    let target = (index as i64 + i64::from(offset)).clamp(0, last) as usize;
    if target == index {
        return Ok(());
    }
    let moved = siblings.remove(index);
    siblings.insert(target, moved);
    persist_task_order(transaction, &siblings, now_ms)
}

/// Moves a task to the top of its siblings. Replaces
/// `WorkspaceStore.moveTaskToStart` and its Kotlin copy.
pub fn move_task_to_start(
    transaction: &Transaction,
    id: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let mut siblings = task_siblings(transaction, &list_id, parent.as_deref())?;
    match siblings.iter().position(|s| s == id) {
        Some(index) if index > 0 => {
            let moved = siblings.remove(index);
            siblings.insert(0, moved);
            persist_task_order(transaction, &siblings, now_ms)
        }
        _ => Ok(()),
    }
}

/// Puts a task directly before a sibling, as a drag does, and on a board
/// drops it into `kanban_column` too. Both must share a list and a parent.
/// Replaces `WorkspaceStore.moveTaskBefore` and its Kotlin copy.
pub fn move_task_before(
    transaction: &Transaction,
    id: &str,
    target_id: &str,
    kanban_column: Option<&str>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let target = task_place(transaction, target_id)?;
    if target != (list_id.clone(), parent.clone()) {
        return Err(CoreError::InvalidTaskMove);
    }
    if id == target_id {
        return Ok(());
    }
    let mut siblings = task_siblings(transaction, &list_id, parent.as_deref())?;
    let Some(index) = siblings.iter().position(|s| s == id) else {
        return Ok(());
    };
    let moved = siblings.remove(index);
    let Some(target_index) = siblings.iter().position(|s| s == target_id) else {
        return Ok(());
    };
    siblings.insert(target_index, moved);
    persist_task_order(transaction, &siblings, now_ms)?;
    if let Some(column) = kanban_column {
        transaction.execute(
            "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
             VALUES (?1, '[]', '[]', ?2, ?3)
             ON CONFLICT(taskId) DO UPDATE SET kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt",
            params![id, column, stored(now_ms)],
        )?;
    }
    Ok(())
}

/// Makes a task the last child of the sibling above it, and closes the gap
/// it leaves. The first sibling has nothing to go under. Replaces
/// `WorkspaceStore.indentTask` and its Kotlin copy.
pub fn indent_task(transaction: &Transaction, id: &str, now_ms: i64) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let siblings = task_siblings(transaction, &list_id, parent.as_deref())?;
    let Some(index) = siblings.iter().position(|s| s == id).filter(|&i| i > 0) else {
        return Ok(());
    };
    let new_parent = siblings[index - 1].clone();
    let sort_order = next_task_order(transaction, &list_id, Some(&new_parent))?;
    transaction.execute(
        "UPDATE tasks SET parentTaskId = ?1, sortOrder = ?2, updatedAt = ?3 WHERE id = ?4",
        params![new_parent, sort_order, stored(now_ms), id],
    )?;
    let rest: Vec<String> = siblings.into_iter().filter(|s| s != id).collect();
    persist_task_order(transaction, &rest, now_ms)
}

/// Makes a task the sibling just after its parent. A top-level task stays.
/// Its old siblings keep their numbers, as before. Replaces
/// `WorkspaceStore.outdentTask` and its Kotlin copy.
pub fn outdent_task(transaction: &Transaction, id: &str, now_ms: i64) -> Result<(), CoreError> {
    let (list_id, parent) = task_place(transaction, id)?;
    let Some(parent_id) = parent else {
        return Ok(());
    };
    let grandparent: Option<Option<String>> = transaction
        .query_row(
            "SELECT parentTaskId FROM tasks WHERE id = ?1",
            [&parent_id],
            |row| row.get(0),
        )
        .optional()?;
    let Some(grandparent) = grandparent else {
        return Ok(());
    };
    let mut siblings = task_siblings(transaction, &list_id, grandparent.as_deref())?;
    let parent_index = siblings
        .iter()
        .position(|s| *s == parent_id)
        .unwrap_or(siblings.len().saturating_sub(1));
    let at = (parent_index + 1).min(siblings.len());
    siblings.insert(at, id.to_string());
    // The task's new parent is written in the same row update as its new
    // place, so the step journals one change for it, as Swift's did.
    let now = stored(now_ms);
    for (index, sibling) in siblings.iter().enumerate() {
        if sibling == id {
            transaction.execute(
                "UPDATE tasks SET parentTaskId = ?1, sortOrder = ?2, updatedAt = ?3 WHERE id = ?4",
                params![grandparent, index as i64, now, id],
            )?;
        } else {
            transaction.execute(
                "UPDATE tasks SET sortOrder = ?1, updatedAt = ?2 WHERE id = ?3",
                params![index as i64, now, sibling],
            )?;
        }
    }
    Ok(())
}

/// Puts tasks in a board column (`None`, or blank, clears it), as one step
/// however many there are. Every id must be a task, or nothing is written.
/// Ids are written once each, in the order given. Replaces both
/// `WorkspaceStore.setKanbanColumn` overloads and their Kotlin copies.
pub fn set_kanban_column(
    transaction: &Transaction,
    task_ids: &[String],
    column: Option<&str>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let mut ids: Vec<&str> = Vec::with_capacity(task_ids.len());
    for id in task_ids {
        if !ids.contains(&id.as_str()) {
            ids.push(id);
        }
    }
    for id in &ids {
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)",
            [id],
            |row| row.get(0),
        )?;
        if !exists {
            return Err(CoreError::MissingTask { id: id.to_string() });
        }
    }
    let value = column.map(str::trim).filter(|c| !c.is_empty());
    let now = stored(now_ms);
    let mut statement = transaction.prepare(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3)
         ON CONFLICT(taskId) DO UPDATE SET kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt",
    )?;
    for id in ids {
        statement.execute(params![id, value, now])?;
    }
    Ok(())
}

/// Places a task on the priority matrix by urgency and importance (either
/// may be unset). Replaces `WorkspaceStore.setMatrixPosition` and its
/// Kotlin copy.
pub fn set_matrix_position(
    transaction: &Transaction,
    id: &str,
    urgency: Option<i64>,
    importance: Option<i64>,
    now_ms: i64,
) -> Result<(), CoreError> {
    task_place(transaction, id)?;
    transaction.execute(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, matrixUrgency, matrixImportance, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3, ?4)
         ON CONFLICT(taskId) DO UPDATE SET
           matrixUrgency = excluded.matrixUrgency,
           matrixImportance = excluded.matrixImportance,
           updatedAt = excluded.updatedAt",
        params![id, urgency, importance, stored(now_ms)],
    )?;
    Ok(())
}

/// The parent a list shows the children of: its visible root, but only while
/// that is still the list's single top-level task.
pub fn visible_root_parent(
    transaction: &Transaction,
    list_id: &str,
) -> Result<Option<String>, CoreError> {
    let root: Option<String> = transaction
        .query_row(
            "SELECT visibleRootTaskId FROM task_lists WHERE id = ?1",
            [list_id],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    let Some(root) = root else {
        return Ok(None);
    };
    let mut statement =
        transaction.prepare("SELECT id FROM tasks WHERE listId = ?1 AND parentTaskId IS NULL")?;
    let roots: Vec<String> = statement
        .query_map([list_id], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    Ok((roots == [root.clone()]).then_some(root))
}

/// A task's list and parent.
fn task_place(transaction: &Transaction, id: &str) -> Result<(String, Option<String>), CoreError> {
    transaction
        .query_row(
            "SELECT listId, parentTaskId FROM tasks WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| CoreError::MissingTask { id: id.to_string() })
}

/// A task's siblings in order. The id breaks a tie in position and creation
/// time, so every client sees the same order.
fn task_siblings(
    transaction: &Transaction,
    list_id: &str,
    parent: Option<&str>,
) -> Result<Vec<String>, CoreError> {
    let mut statement = transaction.prepare(
        "SELECT id FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2 ORDER BY sortOrder, createdAt, id",
    )?;
    let ids = statement
        .query_map(params![list_id, parent], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(ids)
}

fn next_task_order(
    transaction: &Transaction,
    list_id: &str,
    parent: Option<&str>,
) -> Result<i64, CoreError> {
    Ok(transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2",
        params![list_id, parent],
        |row| row.get(0),
    )?)
}

/// Numbers tasks from zero in order and stamps each, as both clients'
/// `persistTaskOrder` did.
fn persist_task_order(
    transaction: &Transaction,
    ids: &[String],
    now_ms: i64,
) -> Result<(), CoreError> {
    let now = stored(now_ms);
    let mut statement =
        transaction.prepare("UPDATE tasks SET sortOrder = ?1, updatedAt = ?2 WHERE id = ?3")?;
    for (index, id) in ids.iter().enumerate() {
        statement.execute(params![index as i64, now, id])?;
    }
    Ok(())
}

pub(crate) fn descendant_ids(
    transaction: &Transaction,
    id: &str,
) -> Result<Vec<String>, CoreError> {
    let mut statement = transaction.prepare(
        "WITH RECURSIVE subtree(id) AS (
           SELECT id FROM tasks WHERE parentTaskId = ?1
           UNION
           SELECT tasks.id FROM tasks JOIN subtree ON tasks.parentTaskId = subtree.id
         )
         SELECT id FROM subtree",
    )?;
    let ids = statement
        .query_map([id], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(ids)
}

/// Opens, completes or cancels a task. Only a task that is newly closed is
/// stamped as completed, so a sync or a repeated command closing it again does
/// not move it into today. Closing one occurrence of a repeating task writes
/// the next one, and ends the habits made from it. A task that is gone is
/// left alone, as both clients did. Replaces `WorkspaceStore.setStatus` and
/// `WorkspaceRepository.setStatus`.
///
/// `zone` is the user's IANA time zone, which the next occurrence's dates
/// are stepped in.
pub fn set_status(
    transaction: &Transaction,
    task_id: &str,
    status: &str,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    if !matches!(status, "open" | "completed" | "cancelled") {
        return Err(CoreError::InvalidStatus {
            status: status.to_string(),
        });
    }
    let completed_at: Option<Option<String>> = transaction
        .query_row(
            "SELECT completedAt FROM tasks WHERE id = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?;
    let Some(completed_at) = completed_at else {
        return Ok(());
    };
    let was_open = completed_at.is_none();
    let now = stored(now_ms);
    let completed_at = if status == "open" {
        None
    } else {
        Some(completed_at.unwrap_or_else(|| now.clone()))
    };
    transaction.execute(
        "UPDATE tasks SET status = ?1, completedAt = ?2, updatedAt = ?3 WHERE id = ?4",
        params![status, completed_at, now, task_id],
    )?;
    if status != "open" && was_open {
        schedule_next_occurrence(transaction, task_id, now_ms, crate::periodic::zone(zone))?;
        expire_habits(transaction, task_id, now_ms)?;
    }
    if status != "open" {
        close_open_descendants(transaction, task_id, status, &now, now_ms)?;
    }
    Ok(())
}

/// Closing a task closes what is still open beneath it, the same way, in the
/// same step, so one undo brings the branch back. Subtasks already closed
/// keep their own status and stamp, and reopening never cascades: a subtask
/// finished before its parent was reopened stays finished. A repeating
/// subtask does not write its next occurrence — its parent is closed, so the
/// occurrence would only be hidden under it — but its habits end, since the
/// task they were made of has.
fn close_open_descendants(
    transaction: &Transaction,
    task_id: &str,
    status: &str,
    now: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    for id in descendant_ids(transaction, task_id)? {
        let closed = transaction.execute(
            "UPDATE tasks SET status = ?1, completedAt = ?2, updatedAt = ?2
             WHERE id = ?3 AND completedAt IS NULL",
            params![status, now, id],
        )?;
        if closed > 0 {
            expire_habits(transaction, &id, now_ms)?;
        }
    }
    Ok(())
}

/// Writes the next occurrence of a repeating task just after it, and returns
/// its id; nothing for a list, a task with no rule this app wrote, or one
/// with no dates to step from. `WorkspaceStore.scheduleNextOccurrence`.
///
/// Steps from the dates the occurrence carried, so "every 3 days" keeps its
/// own rhythm. Everything describing the work carries over; what describes
/// this sitting (its board column, its rung on the ladder) does not.
pub fn schedule_next_occurrence(
    transaction: &Transaction,
    task_id: &str,
    now_ms: i64,
    zone: chrono_tz::Tz,
) -> Result<Option<String>, CoreError> {
    use crate::periodic::Cadence;
    use crate::time::{parse_stored, stored_instant};

    let Some(task) = transaction
        .query_row(
            "SELECT listId, parentTaskId, title, notes, sortOrder, dueAt, estimateSeconds, itemKind, isPromoted
             FROM tasks WHERE id = ?1",
            [task_id],
            |row| {
                Ok(Occurrence {
                    list_id: row.get(0)?,
                    parent: row.get(1)?,
                    title: row.get(2)?,
                    notes: row.get(3)?,
                    sort_order: row.get(4)?,
                    due_at: row.get(5)?,
                    estimate: row.get(6)?,
                    // Older rows predate both columns; the clients read them
                    // as an ordinary, unpromoted task.
                    kind: row.get::<_, Option<String>>(7)?.unwrap_or_else(|| "task".into()),
                    promoted: row.get::<_, Option<bool>>(8)?.unwrap_or(false),
                })
            },
        )
        .optional()?
    else {
        return Ok(None);
    };
    let Occurrence {
        list_id,
        parent,
        title,
        notes,
        sort_order,
        due_at,
        estimate,
        kind,
        promoted,
    } = task;
    if kind == "list" {
        return Ok(None);
    }
    let metadata: Option<(Option<String>, Option<String>)> = transaction
        .query_row(
            "SELECT recurrenceRule, startAt FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((Some(rule), start_at)) = metadata else {
        return Ok(None);
    };
    let Some(cadence) = Cadence::parse(&rule) else {
        return Ok(None);
    };
    let now = chrono::DateTime::from_timestamp_millis(now_ms).unwrap_or_default();
    let rolled = |date: Option<String>| {
        date.as_deref()
            .and_then(parse_stored)
            .and_then(|date| cadence.next_occurrence(date, Some(now), zone))
    };
    let next_due = rolled(due_at);
    let next_start = rolled(start_at).or_else(|| {
        next_due
            .is_none()
            .then(|| cadence.next_occurrence(now, Some(now), zone))
            .flatten()
    });
    if next_start.is_none() && next_due.is_none() {
        return Ok(None);
    }

    let id = crate::lists::new_id();
    let stamp = stored(now_ms);
    transaction.execute(
        "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
                            sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, 'open', ?6, ?7, ?8, NULL, NULL, ?9, ?10, NULL, NULL, ?11, ?11)",
        params![
            id,
            list_id,
            parent,
            title,
            notes,
            sort_order,
            next_due.map(stored_instant),
            estimate,
            kind,
            promoted,
            stamp
        ],
    )?;
    transaction.execute(
        "INSERT INTO task_metadata (taskId, priority, startAt, tagsJSON, recurrenceRule, matrixUrgency,
                                    matrixImportance, kanbanColumn, externalLinksJSON, focusRank, planningJSON, updatedAt)
         SELECT ?1, priority, ?2, tagsJSON, recurrenceRule, matrixUrgency, matrixImportance, NULL,
                externalLinksJSON, NULL, planningJSON, ?3
         FROM task_metadata WHERE taskId = ?4",
        params![id, next_start.map(stored_instant), stamp, task_id],
    )?;

    // The finished occurrence keeps its place; the next one follows it.
    let mut siblings = task_siblings(transaction, &list_id, parent.as_deref())?;
    siblings.retain(|sibling| sibling != &id);
    if let Some(index) = siblings.iter().position(|sibling| sibling == task_id) {
        siblings.insert(index + 1, id.clone());
        persist_task_order(transaction, &siblings, now_ms)?;
    }
    Ok(Some(id))
}

/// The parts of a finished occurrence the next one is made from.
struct Occurrence {
    list_id: String,
    parent: Option<String>,
    title: String,
    notes: String,
    sort_order: i64,
    due_at: Option<String>,
    estimate: Option<i64>,
    kind: String,
    promoted: bool,
}

/// Ends the habits made from a task that is set to end when it is done, and
/// takes them out of the board column they were placed in if they are still
/// there. `WorkspaceStore.expireHabits`.
fn expire_habits(
    transaction: &Transaction,
    source_task_id: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let now = stored(now_ms);
    let mut statement = transaction.prepare(
        "SELECT id, taskId, placementColumn FROM dailies
         WHERE sourceTaskId = ?1 AND archivedAt IS NULL AND expiryRule = 'source'",
    )?;
    let habits: Vec<(String, String, Option<String>)> = statement
        .query_map([source_task_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<_, _>>()?;
    for (habit_id, habit_task_id, placement) in habits {
        transaction.execute(
            "UPDATE dailies SET archivedAt = ?1, updatedAt = ?1 WHERE id = ?2",
            params![now, habit_id],
        )?;
        let Some(placement) = placement else { continue };
        let column: Option<String> = transaction
            .query_row(
                "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
                [&habit_task_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if column.as_deref() == Some(placement.as_str()) {
            transaction.execute(
                "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
                 VALUES (?1, '[]', '[]', NULL, ?2)
                 ON CONFLICT(taskId) DO UPDATE SET
                   kanbanColumn = NULL, focusRank = NULL, updatedAt = excluded.updatedAt",
                params![habit_task_id, now],
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
