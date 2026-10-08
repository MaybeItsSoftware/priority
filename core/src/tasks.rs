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

fn descendant_ids(transaction: &Transaction, id: &str) -> Result<Vec<String>, CoreError> {
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

#[cfg(test)]
mod tests;
