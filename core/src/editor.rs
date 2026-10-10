//! The task editor's writes: saving the editor, editing a task, its details,
//! its schedule, and copying its planning to its subtasks.
//!
//! A task's editable state is one [`EditorSnapshot`]. Saving compares the
//! snapshot the editor opened with the one in the database, so a change made
//! meanwhile (by the CLI, a phone, another window) is refused rather than
//! overwritten. Replaces `WorkspaceStore+Editing.swift`, the planning half of
//! `WorkspaceStore+Conditions.swift`, and Kotlin's `Planning.kt`.

use std::collections::BTreeSet;

use chrono::{Duration, NaiveDate};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::dailies;
use crate::periodic;
pub use crate::planning::Planning;
use crate::tasks::normalized_strings;
use crate::time::{decode_strings, non_empty_name, parse_stored, stored, swift_json_strings};

/// The parts of a task's metadata the editor shows.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct EditorMetadata {
    /// 1 to 4; anything else is no priority.
    pub priority: Option<i64>,
    pub tags: Vec<String>,
    pub recurrence_rule: Option<String>,
    pub external_links: Vec<String>,
}

/// Everything the task editor edits, as it stands. `TaskEditorSnapshot`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorSnapshot {
    pub workspace_id: String,
    pub task_id: String,
    pub title: String,
    pub notes: String,
    pub due_at_ms: Option<i64>,
    pub estimate_seconds: Option<i64>,
    pub metadata: EditorMetadata,
    /// Whether the task is tracked as an active daily.
    pub daily_progress: bool,
    pub planning: Option<Planning>,
}

/// A task's workspace, title, notes, stored due time and estimate.
type TaskFields = (String, String, String, Option<String>, Option<i64>);

/// Reads a task's editable state. `WorkspaceStore.taskEditorSnapshot`.
pub fn snapshot(
    transaction: &rusqlite::Connection,
    task_id: &str,
) -> Result<EditorSnapshot, CoreError> {
    let task: Option<TaskFields> = transaction
        .query_row(
            "SELECT l.workspaceId, t.title, t.notes, t.dueAt, t.estimateSeconds
             FROM tasks t JOIN task_lists l ON l.id = t.listId WHERE t.id = ?1",
            [task_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()?;
    let Some((workspace_id, title, notes, due_at, estimate_seconds)) = task else {
        return Err(CoreError::MissingTask {
            id: task_id.to_string(),
        });
    };
    let metadata = stored_metadata(transaction, task_id)?;
    let daily_progress: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM dailies WHERE taskId = ?1 AND archivedAt IS NULL)",
        [task_id],
        |row| row.get(0),
    )?;
    Ok(EditorSnapshot {
        workspace_id,
        task_id: task_id.to_string(),
        title,
        notes,
        due_at_ms: due_at
            .as_deref()
            .and_then(parse_stored)
            .map(|at| at.timestamp_millis()),
        estimate_seconds,
        metadata: metadata
            .as_ref()
            .map(|m| m.editor.clone())
            .unwrap_or_default(),
        daily_progress,
        planning: match &metadata {
            Some(stored) => stored.planning()?,
            None => None,
        },
    })
}

struct StoredMetadata {
    editor: EditorMetadata,
    start_at: Option<String>,
    planning_json: Option<String>,
}

impl StoredMetadata {
    /// `WorkspaceStore.planning(_:)`: the JSON, with the start from its own
    /// column, normalised.
    fn planning(&self) -> Result<Option<Planning>, CoreError> {
        let mut planning = match &self.planning_json {
            Some(json) => Planning::from_json(json)?,
            None => Planning::default(),
        };
        planning.start_at_ms = self
            .start_at
            .as_deref()
            .and_then(parse_stored)
            .map(|at| at.timestamp_millis());
        Ok(planning.normalized())
    }
}

fn stored_metadata(
    connection: &rusqlite::Connection,
    task_id: &str,
) -> Result<Option<StoredMetadata>, CoreError> {
    Ok(connection
        .query_row(
            "SELECT priority, tagsJSON, recurrenceRule, externalLinksJSON, startAt, planningJSON
             FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| {
                Ok(StoredMetadata {
                    editor: EditorMetadata {
                        priority: row.get(0)?,
                        tags: decode_strings(&row.get::<_, String>(1)?),
                        recurrence_rule: row.get(2)?,
                        external_links: decode_strings(&row.get::<_, String>(3)?),
                    },
                    start_at: row.get(4)?,
                    planning_json: row.get(5)?,
                })
            },
        )
        .optional()?)
}

/// Saves the editor as one step, refusing if the task has changed since
/// `baseline` was read. Returns the task as saved.
/// `WorkspaceStore.saveTaskEditor`.
pub fn save_editor(
    transaction: &Transaction,
    edit: &EditorSnapshot,
    baseline: &EditorSnapshot,
    now_ms: i64,
    zone: &str,
) -> Result<EditorSnapshot, CoreError> {
    let current = snapshot(transaction, &edit.task_id)?;
    if &current != baseline {
        return Err(CoreError::EditorConflict);
    }
    update_planning(
        transaction,
        edit,
        current.planning.as_ref(),
        current.due_at_ms,
        now_ms,
        zone,
    )?;
    update_task_record(transaction, edit, now_ms)?;
    update_editor_metadata(transaction, &edit.task_id, &edit.metadata, now_ms)?;
    set_daily_attachment(
        transaction,
        &edit.task_id,
        edit.daily_progress,
        edit.estimate_seconds,
        now_ms,
    )?;
    snapshot(transaction, &edit.task_id)
}

/// Sets a task's title, notes, due time and estimate. A due time replaces a
/// due date in its planning. `WorkspaceStore.updateTask`.
#[allow(clippy::too_many_arguments)]
pub fn update_task(
    transaction: &Transaction,
    id: &str,
    title: &str,
    notes: &str,
    due_at_ms: Option<i64>,
    estimate_seconds: Option<i64>,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    let title = non_empty_name(title)?;
    let previous = snapshot(transaction, id)?;
    let mut edit = previous.clone();
    edit.title = title;
    edit.notes = notes.to_string();
    edit.due_at_ms = due_at_ms;
    edit.estimate_seconds = estimate_seconds;
    if due_at_ms.is_some() {
        edit.planning = edit.planning.and_then(|mut planning| {
            planning.due_date = None;
            planning.normalized()
        });
    }
    update_planning(
        transaction,
        &edit,
        previous.planning.as_ref(),
        previous.due_at_ms,
        now_ms,
        zone,
    )?;
    update_task_record(transaction, &edit, now_ms)
}

/// Sets a task's priority, tags, links and repeat rule.
/// `WorkspaceStore.updateTaskEditorMetadata`.
pub fn update_editor_metadata(
    transaction: &Transaction,
    task_id: &str,
    metadata: &EditorMetadata,
    now_ms: i64,
) -> Result<(), CoreError> {
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)",
        [task_id],
        |row| row.get(0),
    )?;
    if !exists {
        return Err(CoreError::MissingTask {
            id: task_id.to_string(),
        });
    }
    let tags = normalized_strings(&metadata.tags);
    let links = normalized_strings(&metadata.external_links);
    let recurrence = metadata
        .recurrence_rule
        .as_deref()
        .map(str::trim)
        .filter(|rule| !rule.is_empty())
        .map(str::to_string);
    let priority = metadata
        .priority
        .filter(|priority| (1..=4).contains(priority));
    // A task with no metadata row compares as one with nothing set, so
    // saving nothing onto it writes nothing, as Swift's did.
    let current = stored_metadata(transaction, task_id)?
        .map(|stored| stored.editor)
        .unwrap_or_default();
    if current.priority == priority
        && current.tags == tags
        && current.recurrence_rule == recurrence
        && current.external_links == links
    {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO task_metadata (taskId, priority, tagsJSON, recurrenceRule, externalLinksJSON, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(taskId) DO UPDATE SET
           priority = excluded.priority, tagsJSON = excluded.tagsJSON,
           recurrenceRule = excluded.recurrenceRule, externalLinksJSON = excluded.externalLinksJSON,
           updatedAt = excluded.updatedAt",
        params![
            task_id,
            priority,
            swift_json_strings(&tags),
            recurrence,
            swift_json_strings(&links),
            stored(now_ms)
        ],
    )?;
    Ok(())
}

/// Moves a task's start, or clears it. `WorkspaceStore.scheduleTask`.
pub fn schedule_task(
    transaction: &Transaction,
    id: &str,
    start_at_ms: Option<i64>,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    let previous = snapshot(transaction, id)?;
    let mut edit = previous.clone();
    let mut planning = edit.planning.clone().unwrap_or_default();
    planning.start_at_ms = start_at_ms;
    edit.planning = planning.normalized();
    update_planning(
        transaction,
        &edit,
        previous.planning.as_ref(),
        previous.due_at_ms,
        now_ms,
        zone,
    )
}

/// Copies a task's requirements, start and block rules (not its due date,
/// which stays each subtask's own) onto every task below it.
/// `WorkspaceStore.applyPlanningToDescendants`.
pub fn apply_planning_to_descendants(
    transaction: &Transaction,
    task_id: &str,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    let parent = snapshot(transaction, task_id)?;
    let mut descendants = crate::tasks::descendant_ids(transaction, task_id)?;
    descendants.sort();
    for id in descendants {
        let mut saved = snapshot(transaction, &id)?;
        let own_due_date = saved.planning.as_ref().and_then(|p| p.due_date.clone());
        saved.planning = parent.planning.clone().map(|mut planning| {
            planning.due_date = own_due_date;
            planning
        });
        update_planning(transaction, &saved, None, None, now_ms, zone)?;
    }
    Ok(())
}

/// Checks and stores a task's planning. `WorkspaceStore.updatePlanning`.
///
/// A due date must be a real calendar date. A start must come before the
/// deadline (the end of the due date in `zone`, or the due time), checked
/// only when the schedule changed. A minimum block is at least a minute, a
/// one-sitting task needs an estimate at least that long, and every required
/// condition must exist in the task's workspace and not be archived unless it
/// was already required.
fn update_planning(
    transaction: &Transaction,
    edit: &EditorSnapshot,
    previous: Option<&Planning>,
    previous_due_at_ms: Option<i64>,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    let planning = edit.planning.clone().unwrap_or_default();
    let zone = periodic::zone(zone);
    let deadline_ms = match &planning.due_date {
        Some(date) => {
            let midnight = calendar_date(date).ok_or(CoreError::InvalidDate)?;
            Some(periodic::resolve(zone, midnight + Duration::days(1)).timestamp_millis())
        }
        None => edit.due_at_ms,
    };
    let changed_schedule = planning.start_at_ms != previous.and_then(|p| p.start_at_ms)
        || planning.due_date != previous.and_then(|p| p.due_date.clone())
        || edit.due_at_ms != previous_due_at_ms;
    if changed_schedule
        && let (Some(start), Some(deadline)) = (planning.start_at_ms, deadline_ms)
        && start >= deadline
    {
        return Err(CoreError::InvalidSchedule);
    }
    if planning
        .minimum_block_seconds
        .is_some_and(|minimum| minimum < 60)
    {
        return Err(CoreError::InvalidMinimum);
    }
    if planning.requires_single_sitting == Some(true) {
        let floor = planning.minimum_block_seconds.unwrap_or(60);
        if !edit
            .estimate_seconds
            .is_some_and(|estimate| estimate > 0 && estimate >= floor)
        {
            return Err(CoreError::EstimateRequired);
        }
    }
    let groups = planning.requirement_groups.clone().unwrap_or_default();
    let distinct: BTreeSet<Vec<String>> = groups
        .iter()
        .map(|group| {
            let mut sorted = group.clone();
            sorted.sort();
            sorted
        })
        .collect();
    if distinct.len() != groups.len() {
        return Err(CoreError::InvalidCondition);
    }
    let previously_required: Vec<&String> = previous
        .and_then(|p| p.requirement_groups.as_ref())
        .map(|groups| groups.iter().flatten().collect())
        .unwrap_or_default();
    for group in &groups {
        let unique: BTreeSet<&String> = group.iter().collect();
        if group.is_empty() || unique.len() != group.len() {
            return Err(CoreError::InvalidCondition);
        }
        for id in group {
            let condition: Option<(String, bool)> = transaction
                .query_row(
                    "SELECT workspaceId, isArchived FROM task_conditions WHERE id = ?1",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let usable = condition.is_some_and(|(workspace, archived)| {
                workspace == edit.workspace_id && (!archived || previously_required.contains(&id))
            });
            if !usable {
                return Err(CoreError::InvalidCondition);
            }
        }
    }
    let current = stored_metadata(transaction, &edit.task_id)?;
    let current_planning = match &current {
        Some(stored) => stored.planning()?,
        None => None,
    };
    if current_planning == edit.planning {
        return Ok(());
    }
    let mut kept = planning.clone();
    kept.start_at_ms = None;
    let json = kept.normalized().map(|p| p.to_json());
    let start = planning.start_at_ms.map(stored);
    transaction.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, startAt, planningJSON, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3, ?4)
         ON CONFLICT(taskId) DO UPDATE SET
           startAt = excluded.startAt, planningJSON = excluded.planningJSON, updatedAt = excluded.updatedAt",
        params![edit.task_id, start, json, stored(now_ms)],
    )?;
    Ok(())
}

/// `WorkspaceStore.updateTaskRecord`: the task row's own fields, written
/// only when one of them changed.
fn update_task_record(
    transaction: &Transaction,
    edit: &EditorSnapshot,
    now_ms: i64,
) -> Result<(), CoreError> {
    let current: Option<(String, String, Option<String>, Option<i64>)> = transaction
        .query_row(
            "SELECT title, notes, dueAt, estimateSeconds FROM tasks WHERE id = ?1",
            [&edit.task_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((title, notes, due_at, estimate)) = current else {
        return Err(CoreError::MissingTask {
            id: edit.task_id.clone(),
        });
    };
    let due_ms = due_at
        .as_deref()
        .and_then(parse_stored)
        .map(|at| at.timestamp_millis());
    if title == edit.title
        && notes == edit.notes
        && due_ms == edit.due_at_ms
        && estimate == edit.estimate_seconds
    {
        return Ok(());
    }
    transaction.execute(
        "UPDATE tasks SET title = ?1, notes = ?2, dueAt = ?3, estimateSeconds = ?4, updatedAt = ?5 WHERE id = ?6",
        params![
            edit.title,
            edit.notes,
            edit.due_at_ms.map(stored),
            edit.estimate_seconds,
            stored(now_ms),
            edit.task_id
        ],
    )?;
    Ok(())
}

/// Tracks or stops tracking a task as a daily, only when that changes.
/// `WorkspaceStore.setDailyAttachment`.
fn set_daily_attachment(
    transaction: &Transaction,
    task_id: &str,
    enabled: bool,
    estimate_seconds: Option<i64>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let active: Option<bool> = transaction
        .query_row(
            "SELECT archivedAt IS NULL FROM dailies WHERE taskId = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?;
    if active.unwrap_or(false) == enabled {
        return Ok(());
    }
    if enabled {
        dailies::make_daily(
            transaction,
            task_id,
            &[1, 2, 3, 4, 5, 6, 7],
            None,
            estimate_seconds,
            now_ms,
        )?;
    } else {
        dailies::archive_daily(transaction, task_id, now_ms)?;
    }
    Ok(())
}

/// The start of a `yyyy-MM-dd` date, as a wall-clock time; `None`
/// for anything that is not exactly such a date. `TaskCalendarDate.date`.
fn calendar_date(text: &str) -> Option<chrono::NaiveDateTime> {
    let pieces: Vec<i64> = text
        .split('-')
        .map(|piece| piece.parse().ok())
        .collect::<Option<_>>()?;
    let [year, month, day] = pieces.as_slice() else {
        return None;
    };
    let date = NaiveDate::from_ymd_opt(
        i32::try_from(*year).ok()?,
        u32::try_from(*month).ok()?,
        u32::try_from(*day).ok()?,
    )?;
    // The round trip refuses "2026-3-8" and the like, as Swift's did.
    if date.format("%Y-%m-%d").to_string() != text {
        return None;
    }
    date.and_hms_opt(0, 0, 0)
}

#[cfg(test)]
mod tests;
