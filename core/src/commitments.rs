//! Commitments: committing to work on a task periodically.
//!
//! A commitment is not a concept of its own. It is a habit (a daily with a
//! column to land in, a source and an end; see `habits.rs`) whose task is a
//! *subtask* of the task it advances, rather than a task in the Habits list
//! beside it. That is the whole link: the daily's `sourceTaskId` is the
//! subtask's parent. So every client that reads dailies and habits already
//! shows a commitment in Dailies and Today on its days, and nothing new is
//! stored.
//!
//! What the link adds is an end. A habit made from a task ends with it only
//! if it was told to; a commitment always does, whatever end date it also
//! has, because it is part of the task. Completing the parent archives the
//! daily and the cascade closes the subtask (`tasks::set_status`), and the
//! habit pass ends one whose parent was closed some other way.
//!
//! What happens to a missed appearance is the commitment's choice. By
//! default it vanishes, as it always has: a daily rhythm drops a missed day
//! at the day's end, and a weekly one (or one day a week) is carried until
//! the next one replaces it. A commitment can instead stack its missed
//! appearances (`dailies.stacksMissedFrom`, the day it started stacking):
//! its card stays in Today while any scheduled day since then is not done,
//! and each completion pays off the oldest (`dailies::log_contribution`),
//! so every missed one takes a completion of its own.
//!
//! A commitment's subtask is only there when there is something to do.
//! Completing it (Space, a checkbox, the agent's `task_complete`) ticks the
//! day's appearance rather than closing it (`tick_instead_of_completing`,
//! from `tasks::set_status`), and once nothing is due today — today's is
//! ticked, or today is not one of its days and nothing is carried or owed —
//! it is *resting* ([`resting_task_ids`]): the outline, every board and the
//! filter lists leave it out, and next-up already passes over a met or
//! unscheduled daily. It comes back on its own on its next day, or at once
//! if the tick is undone, since resting is read from the schedule and the
//! ticks rather than stored. While it rests it is still in Dailies (ticked,
//! on its days) and in its parent's Repeat summary.
//!
//! The schedule is written in the recurrence syntax a repeating task uses
//! ("daily", "weekdays", "every friday", "every 2 weeks"), plus a list of
//! days ("mon, wed, fri"), and stored as the daily's weekday mask and
//! interval, which every client already reads.

use std::collections::HashSet;

use rusqlite::{OptionalExtension, Transaction};

use crate::CoreError;
use crate::habits::{self, HabitDraft};
use crate::periodic::{self, Cadence};
use crate::tasks::{self, NewTask};
use crate::time::{non_empty_name, parse_stored, stored};

/// The column a commitment's appearance lands in.
pub const COMMITMENT_PLACEMENT: &str = "today";

/// A schedule as a daily stores it: weekdays (1 = Sunday) and an interval.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommitmentSchedule {
    /// 1 = Sunday through 7 = Saturday. All seven is every day.
    pub weekdays: Vec<u32>,
    /// Every this many days from the day it was made; overrides `weekdays`.
    pub interval_days: Option<i64>,
}

impl CommitmentSchedule {
    fn every_day() -> Self {
        CommitmentSchedule {
            weekdays: (1..=7).collect(),
            interval_days: None,
        }
    }

    /// Whether a missed appearance is carried to the next day. A daily rhythm
    /// drops a missed day, as a habit does by default; a weekly one, or one
    /// day a week, is carried until it is done, so missing Friday does not
    /// cost the whole week.
    pub fn carries_missed_days(&self) -> bool {
        match self.interval_days {
            Some(days) => days >= 7,
            None => self.weekdays.len() == 1,
        }
    }
}

/// Reads a schedule written in the recurrence syntax, or as a list of days.
/// `None` for anything else.
pub fn schedule(rule: &str) -> Option<CommitmentSchedule> {
    let text = rule.trim().to_lowercase();
    if let Some(cadence) = Cadence::parse(&text) {
        return Some(match cadence {
            Cadence::Days(1) => CommitmentSchedule::every_day(),
            Cadence::Days(count) => CommitmentSchedule {
                weekdays: (1..=7).collect(),
                interval_days: Some(i64::from(count).min(366)),
            },
            Cadence::Weeks(count) => CommitmentSchedule {
                weekdays: (1..=7).collect(),
                interval_days: Some((7 * i64::from(count)).min(366)),
            },
            Cadence::Weekdays => CommitmentSchedule {
                weekdays: vec![2, 3, 4, 5, 6],
                interval_days: None,
            },
            Cadence::Weekday(day) => CommitmentSchedule {
                weekdays: vec![day.number_from_sunday()],
                interval_days: None,
            },
        });
    }
    // "mon, wed, fri", "every tue and thu".
    let list = text.strip_prefix("every ").unwrap_or(&text);
    let mut weekdays: Vec<u32> = Vec::new();
    for word in list
        .split(|c: char| c == ',' || c.is_whitespace())
        .filter(|word| !word.is_empty() && *word != "and" && *word != "&")
    {
        let day = periodic::weekday(word)?.number_from_sunday();
        if !weekdays.contains(&day) {
            weekdays.push(day);
        }
    }
    if weekdays.is_empty() {
        return None;
    }
    weekdays.sort_unstable();
    Some(CommitmentSchedule {
        weekdays,
        interval_days: None,
    })
}

/// The schedule written back in the syntax [`schedule`] reads, so a form can
/// show it and save it again unchanged.
pub fn rule_text(schedule: &CommitmentSchedule) -> String {
    if let Some(days) = schedule.interval_days.filter(|days| *days > 1) {
        return match days {
            7 => "weekly".to_string(),
            days if days % 7 == 0 => format!("every {} weeks", days / 7),
            days => format!("every {days} days"),
        };
    }
    let mut weekdays: Vec<u32> = schedule
        .weekdays
        .iter()
        .copied()
        .filter(|day| (1..=7).contains(day))
        .collect();
    weekdays.sort_unstable();
    weekdays.dedup();
    match weekdays.as_slice() {
        [] | [1, 2, 3, 4, 5, 6, 7] => "daily".to_string(),
        [2, 3, 4, 5, 6] => "weekdays".to_string(),
        [day] => format!("every {}", weekday_name(*day)),
        days => {
            // Monday first, as a week is read.
            let mut ordered = days.to_vec();
            ordered.sort_by_key(|day| (day + 5) % 7);
            ordered
                .iter()
                .map(|day| &weekday_name(*day)[..3])
                .collect::<Vec<_>>()
                .join(", ")
        }
    }
}

fn weekday_name(day: u32) -> &'static str {
    match day {
        1 => "sunday",
        2 => "monday",
        3 => "tuesday",
        4 => "wednesday",
        5 => "thursday",
        6 => "friday",
        _ => "saturday",
    }
}

/// The name a new commitment is offered: "Work on <task>".
pub fn default_title(task_title: &str) -> String {
    let title = task_title.trim();
    if title.is_empty() {
        "Work on it".to_string()
    } else {
        format!("Work on {title}")
    }
}

/// What the commitment form saves.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommitmentDraft {
    pub title: String,
    /// In the syntax [`schedule`] reads.
    pub rule: String,
    /// The day it stops appearing, from its start; `None` runs until the
    /// task is done.
    pub expires_at_ms: Option<i64>,
    /// Whether a missed appearance stays owed until done, rather than
    /// vanishing when the next one comes (or, for a daily rhythm, at the end
    /// of its day).
    pub stacks_missed: bool,
}

/// One live commitment.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Commitment {
    pub daily_id: String,
    /// The subtask that carries it.
    pub task_id: String,
    /// The task it advances.
    pub parent_task_id: String,
    pub title: String,
    /// Its schedule, as [`rule_text`] writes it.
    pub rule: String,
    pub schedule: CommitmentSchedule,
    /// The start of the day it stops appearing, if it has one.
    pub expires_at_ms: Option<i64>,
    /// Whether its missed appearances stack rather than vanish.
    pub stacks_missed: bool,
}

/// Commits to `task_id` periodically, or rewrites its commitment on
/// `commitment_task_id`, and returns the subtask's id.
///
/// A new commitment is a subtask, last among the task's children, with a
/// habit on it whose source is the task. It lands in Today straight away if
/// it is due today.
pub fn save_commitment(
    transaction: &Transaction,
    task_id: &str,
    draft: &CommitmentDraft,
    commitment_task_id: Option<&str>,
    now_ms: i64,
    zone: &str,
) -> Result<String, CoreError> {
    let title = non_empty_name(&draft.title)?;
    let Some(schedule) = schedule(&draft.rule) else {
        return Err(CoreError::InvalidRecurrence {
            rule: draft.rule.trim().to_string(),
        });
    };
    let list_id: String = transaction
        .query_row("SELECT listId FROM tasks WHERE id = ?1", [task_id], |row| {
            row.get(0)
        })
        .optional()?
        .ok_or_else(|| CoreError::MissingTask {
            id: task_id.to_string(),
        })?;
    let subtask_id = match commitment_task_id {
        Some(id) => {
            if commitment(transaction, id)?.is_none_or(|c| c.parent_task_id != task_id) {
                return Err(CoreError::MissingTask { id: id.to_string() });
            }
            id.to_string()
        }
        None => tasks::create_task(
            transaction,
            &NewTask {
                list_id,
                title: title.clone(),
                parent_task_id: Some(task_id.to_string()),
                kind: "task".to_string(),
                notes: String::new(),
                kanban_column: None,
                start_at_ms: None,
                due_at_ms: None,
                estimate_seconds: None,
                tags: Vec::new(),
                priority: None,
                waiting_on: None,
                external_links: Vec::new(),
                at_top: false,
                adjacent_task_id: None,
                above: false,
            },
            now_ms,
        )?,
    };
    let estimate: Option<i64> = transaction.query_row(
        "SELECT estimateSeconds FROM tasks WHERE id = ?1",
        [&subtask_id],
        |row| row.get(0),
    )?;
    let habit = HabitDraft {
        title,
        weekdays: schedule.weekdays.clone(),
        interval_days: schedule.interval_days,
        drops_at_day_end: !schedule.carries_missed_days(),
        estimate_seconds: estimate,
        expiry_rule: if draft.expires_at_ms.is_some() {
            "date"
        } else {
            "never"
        }
        .to_string(),
        expires_at_ms: draft.expires_at_ms,
        placement: COMMITMENT_PLACEMENT.to_string(),
        source_task_id: Some(task_id.to_string()),
    };
    let daily_id = habits::save_habit(transaction, &habit, Some(&subtask_id), now_ms, zone)?;
    set_stacks_missed(transaction, &daily_id, draft.stacks_missed, now_ms, zone)?;
    Ok(subtask_id)
}

/// Turns stacking on from today, or off. Turning it on again keeps the day it
/// started, so an edit that leaves it on does not forgive what is owed; it
/// never reaches back before that day, so switching it on does not bill for
/// every day missed before.
fn set_stacks_missed(
    transaction: &Transaction,
    daily_id: &str,
    stacks: bool,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    let current: Option<String> = transaction.query_row(
        "SELECT stacksMissedFrom FROM dailies WHERE id = ?1",
        [daily_id],
        |row| row.get(0),
    )?;
    let tz = periodic::zone(zone);
    let target = match (stacks, current) {
        (false, None) => return Ok(()),
        (true, Some(_)) => return Ok(()),
        (false, Some(_)) => None,
        (true, None) => Some(stored(habits::start_of_day_ms(
            habits::local_day(now_ms, tz),
            tz,
        ))),
    };
    transaction.execute(
        "UPDATE dailies SET stacksMissedFrom = ?1, updatedAt = ?2 WHERE id = ?3",
        rusqlite::params![target, stored(now_ms), daily_id],
    )?;
    habits::reconcile_habit(transaction, daily_id, now_ms, tz)?;
    Ok(())
}

/// How many of a commitment's missed appearances are still owed on the day
/// `now_ms` falls on: scheduled days before today that are not done, counted
/// only while it stacks. Zero for one that vanishes, or that is no
/// commitment.
pub fn missed(
    connection: &rusqlite::Connection,
    commitment_task_id: &str,
    now_ms: i64,
    zone: &str,
) -> Result<u32, CoreError> {
    let Some(commitment) = commitment(connection, commitment_task_id)? else {
        return Ok(0);
    };
    if !commitment.stacks_missed {
        return Ok(0);
    }
    let tz = periodic::zone(zone);
    let today = habits::local_day(now_ms, tz);
    let owed = habits::owed(connection, &commitment.daily_id, now_ms, tz)?;
    Ok(u32::try_from(owed.iter().filter(|day| **day < today).count()).unwrap_or(u32::MAX))
}

/// The commitment subtasks resting on the local day `now_ms` falls on, with
/// everything beneath them: those with nothing due today (see the module
/// notes). The outline, the boards and the filter lists leave these out.
pub fn resting_task_ids(
    connection: &rusqlite::Connection,
    now_ms: i64,
    zone: &str,
) -> Result<HashSet<String>, CoreError> {
    let tz = periodic::zone(zone);
    let mut resting = HashSet::new();
    for commitment in all_commitments(connection)? {
        if habits::rests(connection, &commitment.daily_id, now_ms, tz)? {
            resting.insert(commitment.task_id);
        }
    }
    // Anything filed beneath one rests with it, rather than losing its parent.
    let mut statement =
        connection.prepare_cached("SELECT id FROM tasks WHERE parentTaskId = ?1")?;
    let mut frontier: Vec<String> = resting.iter().cloned().collect();
    while let Some(id) = frontier.pop() {
        for child in statement.query_map([&id], |row| row.get::<_, String>(0))? {
            let child = child?;
            if resting.insert(child.clone()) {
                frontier.push(child);
            }
        }
    }
    Ok(resting)
}

/// [`resting_task_ids`] as of this moment in the device's time zone, for the
/// reads that are not handed a clock: a list's rows, its outline, and the
/// combined boards.
pub fn resting_task_ids_now(
    connection: &rusqlite::Connection,
) -> Result<HashSet<String>, CoreError> {
    if !habits::any_live(connection)? {
        return Ok(HashSet::new());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| {
            i64::try_from(since.as_millis()).unwrap_or(i64::MAX)
        });
    let zone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".to_string());
    resting_task_ids(connection, now_ms, &zone)
}

/// Ticks today's appearance of the commitment `task_id` carries, in place of
/// completing it, and says whether it did. Completing a commitment's subtask
/// (Space, a checkbox, the agent) is doing it for the day: the subtask stays
/// open and rests until its next day. Only completing its parent, or
/// stopping it, ends it.
pub(crate) fn tick_instead_of_completing(
    transaction: &Transaction,
    task_id: &str,
    now_ms: i64,
    zone: &str,
) -> Result<bool, CoreError> {
    let Some(commitment) = commitment(transaction, task_id)? else {
        return Ok(false);
    };
    crate::dailies::log_contribution(transaction, &commitment.daily_id, 0, true, now_ms, zone)?;
    habits::reconcile_habit(
        transaction,
        &commitment.daily_id,
        now_ms,
        periodic::zone(zone),
    )?;
    Ok(true)
}

/// Stops a commitment: its daily is archived, keeping what was logged, its
/// card leaves Today, and the subtask is closed as done. Nothing to stop is
/// not an error.
pub fn stop_commitment(
    transaction: &Transaction,
    commitment_task_id: &str,
    now_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    if commitment(transaction, commitment_task_id)?.is_none() {
        return Ok(());
    }
    end_commitment(transaction, commitment_task_id, now_ms)?;
    tasks::set_status(transaction, commitment_task_id, "completed", now_ms, zone)
}

/// Archives the daily `commitment_task_id` carries and takes its card out of
/// Today, so it is a commitment no longer and closing it closes it.
pub(crate) fn end_commitment(
    transaction: &Transaction,
    commitment_task_id: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    crate::dailies::archive_daily(transaction, commitment_task_id, now_ms)?;
    if habits::kanban_column(transaction, commitment_task_id)?.as_deref()
        == Some(COMMITMENT_PLACEMENT)
    {
        habits::write_column(transaction, commitment_task_id, None, now_ms)?;
    }
    Ok(())
}

const COMMITMENT_COLUMNS: &str =
    "d.id, t.id, t.parentTaskId, t.title, d.activeWeekdaysMask, d.intervalDays,
     d.expiryRule, d.expiresAt, d.stacksMissedFrom IS NOT NULL";

/// The live commitments on `task_id`, in the order of its subtasks.
pub fn commitments(
    connection: &rusqlite::Connection,
    task_id: &str,
) -> Result<Vec<Commitment>, CoreError> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COMMITMENT_COLUMNS} FROM dailies d JOIN tasks t ON t.id = d.taskId
         WHERE t.parentTaskId = ?1 AND d.sourceTaskId = ?1 AND d.archivedAt IS NULL AND t.status = 'open'
         ORDER BY t.sortOrder, t.id"
    ))?;
    Ok(statement
        .query_map([task_id], commitment_row)?
        .collect::<Result<_, _>>()?)
}

/// Every live commitment in the workspace, grouped by the task each
/// advances and in the order of its subtasks.
pub fn all_commitments(connection: &rusqlite::Connection) -> Result<Vec<Commitment>, CoreError> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COMMITMENT_COLUMNS} FROM dailies d JOIN tasks t ON t.id = d.taskId
         WHERE d.sourceTaskId = t.parentTaskId AND d.archivedAt IS NULL AND t.status = 'open'
         ORDER BY t.parentTaskId, t.sortOrder, t.id"
    ))?;
    Ok(statement
        .query_map([], commitment_row)?
        .collect::<Result<_, _>>()?)
}

/// The live commitment `task_id` carries, if it is one.
pub fn commitment(
    connection: &rusqlite::Connection,
    task_id: &str,
) -> Result<Option<Commitment>, CoreError> {
    Ok(connection
        .query_row(
            &format!(
                "SELECT {COMMITMENT_COLUMNS} FROM dailies d JOIN tasks t ON t.id = d.taskId
                 WHERE t.id = ?1 AND d.sourceTaskId = t.parentTaskId AND d.archivedAt IS NULL
                   AND t.status = 'open'"
            ),
            [task_id],
            commitment_row,
        )
        .optional()?)
}

fn commitment_row(row: &rusqlite::Row) -> rusqlite::Result<Commitment> {
    let mask: i64 = row.get(4)?;
    let schedule = CommitmentSchedule {
        weekdays: (1..=7).filter(|day| mask & (1 << (day - 1)) != 0).collect(),
        interval_days: row.get(5)?,
    };
    let expiry_rule: Option<String> = row.get(6)?;
    let expires_at: Option<String> = row.get(7)?;
    Ok(Commitment {
        daily_id: row.get(0)?,
        task_id: row.get(1)?,
        parent_task_id: row.get(2)?,
        title: row.get(3)?,
        rule: rule_text(&schedule),
        schedule,
        expires_at_ms: (expiry_rule.as_deref() == Some("date"))
            .then(|| expires_at.as_deref().and_then(parse_stored))
            .flatten()
            .map(|at| at.timestamp_millis()),
        stacks_missed: row.get(8)?,
    })
}

#[cfg(test)]
mod tests;
