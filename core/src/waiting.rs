//! Waiting on someone: a task filed in the `waiting-on` column with who it
//! waits on and when to chase them, and the follow-up task made when that
//! time comes. Replaces `WorkspaceStore+Waiting.swift`'s writes and
//! `WaitingFollowUp`'s policy in TaktCore, and their Kotlin ports.
//!
//! A follow-up can repeat every N days (`v32_follow_up_repeat`). Completing
//! the follow-up, while its source is still open and waiting, moves the
//! source's follow-up time N days on from whichever is later, the completion
//! or the time it was for, keeping the time of day; the next one is then made
//! by [`make_due_follow_ups`] like any other. One never completed makes no
//! more, so they cannot pile up. The source counts the follow-ups of this
//! spell of waiting, and the second on are numbered: "Follow up #2 with Sam:
//! Contract signed".

use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;

use crate::CoreError;
use crate::time::{parse_stored, stored};

/// The fewest days a follow-up can repeat after.
pub const MINIMUM_EVERY_DAYS: u32 = 1;
/// The most days a follow-up can repeat after: a year.
pub const MAXIMUM_EVERY_DAYS: u32 = 365;

/// The column a waiting task sits in.
pub const WAITING_COLUMN: &str = "waiting-on";
/// The column a follow-up is made in.
pub const FOLLOW_UP_COLUMN: &str = "today";
const MAXIMUM_TAG: usize = 40;

/// Who a task waits on, trimmed and clipped to 40 characters, or nothing.
/// Characters as Swift counts them, grapheme clusters, so a flag or a family
/// emoji is kept whole or dropped whole rather than split.
pub fn normalized_tag(text: Option<&str>) -> Option<String> {
    let trimmed = text?.trim();
    (!trimmed.is_empty()).then(|| trimmed.graphemes(true).take(MAXIMUM_TAG).collect())
}

/// A task as the follow-up rule reads it. `WaitingTaskState`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WaitingState {
    pub task_id: String,
    pub title: String,
    pub is_open: bool,
    /// The board column it is filed in. Only `waiting-on` is waiting.
    pub column: Option<String>,
    pub waiting_on: Option<String>,
    pub follow_up_at_ms: Option<i64>,
    /// The follow-up already made for it, if any.
    pub made_follow_up_task_id: Option<String>,
    /// How many follow-ups this spell of waiting has already made.
    pub follow_up_count: u32,
}

/// The follow-up to make: "Follow up with Sam: Contract signed", due at the
/// follow-up time. `WaitingFollowUpPlan`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FollowUpPlan {
    pub task_id: String,
    pub source_task_id: String,
    pub title: String,
    pub due_at_ms: i64,
    /// Which follow-up of the spell it is, from 1.
    pub number: u32,
}

/// The follow-up to make for `task` at `now_ms`, if one is due: the task is
/// open, still in `waiting-on`, its follow-up time has come, and the
/// follow-up for that time has not been made. Setting a new time makes a new
/// one, since the id follows the time. `WaitingFollowUp.dueFollowUp`.
pub fn due_follow_up(task: &WaitingState, now_ms: i64) -> Option<FollowUpPlan> {
    if !task.is_open || task.column.as_deref() != Some(WAITING_COLUMN) {
        return None;
    }
    let at_ms = task.follow_up_at_ms.filter(|at| *at <= now_ms)?;
    let id = follow_up_task_id(&task.task_id, at_ms);
    if task.made_follow_up_task_id.as_deref() == Some(id.as_str()) {
        return None;
    }
    let number = task.follow_up_count.saturating_add(1);
    Some(FollowUpPlan {
        title: follow_up_title(&task.title, task.waiting_on.as_deref(), number),
        task_id: id,
        source_task_id: task.task_id.clone(),
        due_at_ms: at_ms,
        number,
    })
}

/// "Follow up with Sam: Contract signed", or "Follow up: ..." when nobody is
/// named. The first follow-up of a spell is unnumbered; the second on say
/// which they are: "Follow up #2 with Sam: Contract signed".
pub fn follow_up_title(title: &str, waiting_on: Option<&str>, number: u32) -> String {
    let source = title.trim();
    let follow_up = if number > 1 {
        format!("Follow up #{number}")
    } else {
        "Follow up".to_string()
    };
    match normalized_tag(waiting_on) {
        Some(tag) => format!("{follow_up} with {tag}: {source}"),
        None => format!("{follow_up}: {source}"),
    }
}

/// What a waiting card adds after its follow-up time: which follow-up that
/// time is, from the second on, and how often it repeats — `#3 · every 3d`,
/// `every day`, `#2`. Nothing for a first follow-up that happens once.
///
/// The number is the follow-up at `follow_up_at_ms`: the latest one made
/// when that time's has been made, the next one when it has not.
pub fn chase_label(
    source_task_id: &str,
    follow_up_at_ms: i64,
    made_follow_up_task_id: Option<&str>,
    follow_up_count: u32,
    every_days: Option<u32>,
) -> Option<String> {
    let made =
        made_follow_up_task_id == Some(follow_up_task_id(source_task_id, follow_up_at_ms).as_str());
    let number = if made {
        follow_up_count.max(1)
    } else {
        follow_up_count.saturating_add(1)
    };
    let mut parts = Vec::new();
    if number > 1 {
        parts.push(format!("#{number}"));
    }
    match every_days {
        Some(1) => parts.push("every day".to_string()),
        Some(days) => parts.push(format!("every {days}d")),
        None => {}
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// A repeat kept to 1 to 365 days, or an error naming the range.
fn checked_every_days(every_days: Option<u32>) -> Result<Option<u32>, CoreError> {
    match every_days {
        Some(days) if !(MINIMUM_EVERY_DAYS..=MAXIMUM_EVERY_DAYS).contains(&days) => {
            Err(CoreError::InvalidFollowUpRepeat { days })
        }
        other => Ok(other),
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

/// Sets what a task waits on, when to chase it and how often to chase again,
/// and files it in Waiting on if it is not there. `None` clears any of them;
/// a repeat needs a follow-up time and is dropped without one. A follow-up
/// time is kept to the whole minute, and one already passed makes its
/// follow-up in the same step.
///
/// Naming someone other than the task waited on, or clearing both who and
/// when, starts a new spell of waiting: the count of follow-ups goes back to
/// nought. Naming someone where nobody was named keeps it. Replaces
/// `WorkspaceStore.setWaiting`.
pub fn set_waiting(
    transaction: &Transaction,
    task_id: &str,
    waiting_on: Option<&str>,
    follow_up_at_ms: Option<i64>,
    every_days: Option<u32>,
    now_ms: i64,
) -> Result<(), CoreError> {
    let every_days = checked_every_days(every_days)?;
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
    let every_days = every_days.filter(|_| follow_up.is_some());
    let (column, previous_tag, count): (Option<String>, Option<String>, u32) = transaction
        .query_row(
            "SELECT kanbanColumn, waitingOn, waitingFollowUpCount FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?
        .unwrap_or((None, None, 0));
    let someone_else = previous_tag.is_some() && normalized_tag(previous_tag.as_deref()) != tag;
    let cleared = tag.is_none() && follow_up.is_none();
    let count = if someone_else || cleared { 0 } else { count };
    // Leaving Today drops the place in the day, as planning for today does.
    let clears_rank = column.as_deref() == Some("today");
    transaction.execute(
        "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, waitingOn, waitingFollowUpAt,
                                    waitingFollowUpEveryDays, waitingFollowUpCount, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3, ?4, ?7, ?8, ?5)
         ON CONFLICT(taskId) DO UPDATE SET
           kanbanColumn = excluded.kanbanColumn,
           focusRank = CASE WHEN ?6 THEN NULL ELSE focusRank END,
           waitingOn = excluded.waitingOn, waitingFollowUpAt = excluded.waitingFollowUpAt,
           waitingFollowUpEveryDays = excluded.waitingFollowUpEveryDays,
           waitingFollowUpCount = excluded.waitingFollowUpCount,
           updatedAt = excluded.updatedAt",
        params![
            task_id,
            WAITING_COLUMN,
            tag,
            follow_up.map(stored),
            stored(now_ms),
            clears_rank,
            every_days,
            count
        ],
    )?;
    make_due_follow_ups(transaction, Some(task_id), now_ms)?;
    Ok(())
}

/// The waiting tasks whose follow-up is due and not yet made, each with the
/// id its follow-up takes. `WaitingFollowUp.dueFollowUp`.
fn due_follow_ups(
    connection: &rusqlite::Connection,
    task_id: Option<&str>,
    now_ms: i64,
) -> Result<Vec<(WaitingRow, String, i64)>, CoreError> {
    let mut statement = connection.prepare(
        "SELECT t.id, t.title, t.listId, t.parentTaskId, m.waitingOn, m.waitingFollowUpAt, m.waitingFollowUpTaskId,
                m.waitingFollowUpCount
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
                count: row.get(7)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let mut due = Vec::new();
    for row in waiting {
        let Some(follow_up_at) = row.follow_up_at.as_deref().and_then(parse_stored) else {
            continue;
        };
        let state = WaitingState {
            task_id: row.id.clone(),
            title: String::new(),
            is_open: true,
            column: Some(WAITING_COLUMN.to_string()),
            waiting_on: None,
            follow_up_at_ms: Some(follow_up_at.timestamp_millis()),
            made_follow_up_task_id: row.made.clone(),
            follow_up_count: row.count,
        };
        if let Some(plan) = due_follow_up(&state, now_ms) {
            due.push((row, plan.task_id, plan.due_at_ms));
        }
    }
    Ok(due)
}

/// Whether any follow-up is due, so a caller can skip the write when not.
pub fn any_due(connection: &rusqlite::Connection, now_ms: i64) -> Result<bool, CoreError> {
    Ok(!due_follow_ups(connection, None, now_ms)?.is_empty())
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
    let now = stored(now_ms);
    let mut made_any = false;
    for (row, id, at_ms) in due_follow_ups(transaction, task_id, now_ms)? {
        let number = row.count.saturating_add(1);
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
                    follow_up_title(&row.title, row.waiting_on.as_deref(), number),
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
            "UPDATE task_metadata SET waitingFollowUpTaskId = ?1, waitingFollowUpCount = ?4, updatedAt = ?2
             WHERE taskId = ?3",
            params![id, now, row.id, number],
        )?;
        made_any = true;
    }
    Ok(made_any)
}

/// When `follow_up_id`, just completed at `completed_ms`, is the follow-up of
/// a task still open, still waiting and set to repeat, moves that task's
/// follow-up time on: `every` days after the local day of whichever is
/// later, the completion or the time it was for, at the time of day it had.
/// Returns whether it did.
///
/// Only the follow-up for the source's current time counts: completing an
/// older one, or one whose source has since been given a new time by hand,
/// leaves the source alone. Called from `tasks::set_status` inside the
/// completion's own step, so one undo takes back both.
pub(crate) fn schedule_next_follow_up(
    transaction: &Transaction,
    follow_up_id: &str,
    completed_ms: i64,
    zone: chrono_tz::Tz,
) -> Result<bool, CoreError> {
    let source: Option<(String, Option<String>, Option<u32>)> = transaction
        .query_row(
            "SELECT s.id, sm.waitingFollowUpAt, sm.waitingFollowUpEveryDays
             FROM task_metadata f
             JOIN tasks s ON s.id = f.followUpOfTaskId
             JOIN task_metadata sm ON sm.taskId = s.id
             WHERE f.taskId = ?1 AND s.status = 'open' AND sm.kanbanColumn = ?2",
            params![follow_up_id, WAITING_COLUMN],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let Some((source_id, Some(at), Some(every))) = source else {
        return Ok(false);
    };
    let Some(at) = parse_stored(&at) else {
        return Ok(false);
    };
    let at_ms = at.timestamp_millis();
    if follow_up_task_id(&source_id, at_ms) != follow_up_id {
        return Ok(false);
    }
    let next_ms = next_follow_up_ms(at_ms, completed_ms, every, zone);
    transaction.execute(
        "UPDATE task_metadata SET waitingFollowUpAt = ?1, updatedAt = ?2 WHERE taskId = ?3",
        params![stored(next_ms), stored(completed_ms), source_id],
    )?;
    Ok(true)
}

/// `every` days after the local day of the later of `at_ms` and
/// `completed_ms`, at `at_ms`'s local time of day, to the minute. A time the
/// clocks skip that day is taken an hour later.
pub fn next_follow_up_ms(at_ms: i64, completed_ms: i64, every: u32, zone: chrono_tz::Tz) -> i64 {
    use chrono::{Days, TimeZone};
    let local = |ms: i64| {
        zone.timestamp_millis_opt(ms)
            .single()
            .expect("a timestamp is one instant")
    };
    let time = local(at_ms).time();
    let day = local(at_ms.max(completed_ms)).date_naive();
    let next_day = day
        .checked_add_days(Days::new(u64::from(every)))
        .unwrap_or(day);
    let naive = next_day.and_time(time);
    let resolved = zone
        .from_local_datetime(&naive)
        .earliest()
        .or_else(|| {
            zone.from_local_datetime(&(naive + chrono::Duration::hours(1)))
                .earliest()
        })
        .map(|moment| moment.timestamp_millis())
        .unwrap_or(at_ms.max(completed_ms) + i64::from(every) * 86_400_000);
    resolved.div_euclid(60_000) * 60_000
}

struct WaitingRow {
    id: String,
    title: String,
    list_id: String,
    parent: Option<String>,
    waiting_on: Option<String>,
    follow_up_at: Option<String>,
    made: Option<String>,
    count: u32,
}

#[cfg(test)]
mod tests;
