//! Waiting on someone: a task filed in the `waiting-on` column with who it
//! waits on and when to chase them, and the follow-up task made when that
//! time comes. Replaces `WorkspaceStore+Waiting.swift`'s writes and
//! `WaitingFollowUp`'s policy in TaktCore, and their Kotlin ports.

use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};

use crate::CoreError;
use crate::time::{parse_stored, stored};

/// The column a waiting task sits in.
pub const WAITING_COLUMN: &str = "waiting-on";
/// The column a follow-up is made in.
pub const FOLLOW_UP_COLUMN: &str = "today";
const MAXIMUM_TAG: usize = 40;

/// Who a task waits on, trimmed and clipped to 40 characters, or nothing.
pub fn normalized_tag(text: Option<&str>) -> Option<String> {
    let trimmed = text?.trim();
    (!trimmed.is_empty()).then(|| trimmed.chars().take(MAXIMUM_TAG).collect())
}

/// "Follow up with Sam: Contract signed", or "Follow up: ..." when nobody is
/// named.
pub fn follow_up_title(title: &str, waiting_on: Option<&str>) -> String {
    let source = title.trim();
    match normalized_tag(waiting_on) {
        Some(tag) => format!("Follow up with {tag}: {source}"),
        None => format!("Follow up: {source}"),
    }
}

/// The follow-up's id: a UUID-shaped string from SHA-256 of
/// `takt.follow-up:<source>:<epoch seconds>`, uppercased, with the version 5
/// and RFC 4122 variant bits set. Every device derives the same id, so two
/// that make the same follow-up make one row.
pub fn follow_up_task_id(source_task_id: &str, follow_up_at_ms: i64) -> String {
    let seconds = follow_up_at_ms.div_euclid(1000);
    let digest = Sha256::digest(format!("takt.follow-up:{source_task_id}:{seconds}").as_bytes());
    let mut bytes: [u8; 16] = digest[..16]
        .try_into()
        .expect("a digest is longer than 16 bytes");
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Sets what a task waits on and when to chase it, and files it in Waiting
/// on if it is not there. `None` clears either. A follow-up time is kept to
/// the whole minute, and one already passed makes its follow-up in the same
/// step. Replaces `WorkspaceStore.setWaiting`.
pub fn set_waiting(
    transaction: &Transaction,
    task_id: &str,
    waiting_on: Option<&str>,
    follow_up_at_ms: Option<i64>,
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
    let tag = normalized_tag(waiting_on);
    let follow_up = follow_up_at_ms.map(|ms| ms.div_euclid(60_000) * 60_000);
    let column: Option<String> = transaction
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    // Leaving Today drops the place in the day, as planning for today does.
    let clears_rank = column.as_deref() == Some("today");
    transaction.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, waitingOn, waitingFollowUpAt, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3, ?4, ?5)
         ON CONFLICT(taskId) DO UPDATE SET
           kanbanColumn = excluded.kanbanColumn,
           focusRank = CASE WHEN ?6 THEN NULL ELSE focusRank END,
           waitingOn = excluded.waitingOn, waitingFollowUpAt = excluded.waitingFollowUpAt,
           updatedAt = excluded.updatedAt",
        params![
            task_id,
            WAITING_COLUMN,
            tag,
            follow_up.map(stored),
            stored(now_ms),
            clears_rank
        ],
    )?;
    make_due_follow_ups(transaction, Some(task_id), now_ms)?;
    Ok(())
}

/// Makes every follow-up that has come due, for one task or all of them, and
/// returns whether it made any. Not an undo step when run on its own: nobody
/// asked for it, and undoing it would only have the next pass make it again.
/// `WorkspaceStore.reconcileWaitingFollowUps` and `makeFollowUp`.
pub fn make_due_follow_ups(
    transaction: &Transaction,
    task_id: Option<&str>,
    now_ms: i64,
) -> Result<bool, CoreError> {
    let mut statement = transaction.prepare(
        "SELECT t.id, t.title, t.listId, t.parentTaskId, m.waitingOn, m.waitingFollowUpAt, m.waitingFollowUpTaskId
         FROM task_metadata m JOIN tasks t ON t.id = m.taskId
         WHERE m.waitingFollowUpAt IS NOT NULL AND m.kanbanColumn = ?1 AND t.status = 'open'
           AND (?2 IS NULL OR t.id = ?2)",
    )?;
    let waiting: Vec<WaitingRow> = statement
        .query_map(params![WAITING_COLUMN, task_id], |row| {
            Ok(WaitingRow {
                id: row.get(0)?,
                title: row.get(1)?,
                list_id: row.get(2)?,
                parent: row.get(3)?,
                waiting_on: row.get(4)?,
                follow_up_at: row.get(5)?,
                made: row.get(6)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let now = stored(now_ms);
    let mut made_any = false;
    for row in waiting {
        let Some(follow_up_at) = row.follow_up_at.as_deref().and_then(parse_stored) else {
            continue;
        };
        let at_ms = follow_up_at.timestamp_millis();
        if at_ms > now_ms {
            continue;
        }
        let id = follow_up_task_id(&row.id, at_ms);
        if row.made.as_deref() == Some(id.as_str()) {
            continue;
        }
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)",
            [&id],
            |r| r.get(0),
        )?;
        // A row with this id already there was made by another device and
        // brought by sync; keep it and only record it as made.
        if !exists {
            let order: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2",
                params![row.list_id, row.parent],
                |r| r.get(0),
            )?;
            transaction.execute(
                "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
                                    sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
                 VALUES (?1, ?2, ?3, ?4, '', 'open', ?5, ?6, NULL, NULL, NULL, 'task', 0, NULL, NULL, ?7, ?7)",
                params![
                    id,
                    row.list_id,
                    row.parent,
                    follow_up_title(&row.title, row.waiting_on.as_deref()),
                    order,
                    stored(at_ms),
                    now
                ],
            )?;
            transaction.execute(
                "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, followUpOfTaskId, updatedAt)
                 VALUES (?1, '[]', '[]', ?2, ?3, ?4)
                 ON CONFLICT(taskId) DO UPDATE SET
                   kanbanColumn = excluded.kanbanColumn, followUpOfTaskId = excluded.followUpOfTaskId,
                   updatedAt = excluded.updatedAt",
                params![id, FOLLOW_UP_COLUMN, row.id, now],
            )?;
        }
        transaction.execute(
            "UPDATE task_metadata SET waitingFollowUpTaskId = ?1, updatedAt = ?2 WHERE taskId = ?3",
            params![id, now, row.id],
        )?;
        made_any = true;
    }
    Ok(made_any)
}

struct WaitingRow {
    id: String,
    title: String,
    list_id: String,
    parent: Option<String>,
    waiting_on: Option<String>,
    follow_up_at: Option<String>,
    made: Option<String>,
}

#[cfg(test)]
mod tests;
