//! Writes to dailies: the tasks a user commits to on certain days, and the
//! contributions logged against each day.

use chrono::DateTime;
use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::lists::new_id;
use crate::time::stored;

/// A set of weekdays (1 = Sunday through 7 = Saturday, as Foundation counts
/// them) as the bit mask `dailies.activeWeekdaysMask` holds.
/// `WorkspaceDaily.mask(forWeekdays:)`.
pub fn weekday_mask(weekdays: &[u32]) -> i64 {
    weekdays
        .iter()
        .filter(|day| (1..=7).contains(*day))
        .fold(0, |mask, day| mask | (1 << (day - 1)))
}

/// The day a moment falls on in `zone`, as contributions are keyed:
/// `yyyy-MM-dd`. `DailyContribution.dayKey(for:calendar:)`.
pub fn day_key(now_ms: i64, zone: &str) -> String {
    let instant = DateTime::from_timestamp_millis(now_ms).unwrap_or_default();
    instant
        .with_timezone(&crate::periodic::zone(zone))
        .format("%Y-%m-%d")
        .to_string()
}

/// Makes a task a daily and returns the daily's id. A task that already has
/// one gets it back, restored if archived and given `target_seconds` if one
/// is passed. Replaces `WorkspaceStore.makeDaily` and its Kotlin copy.
pub fn make_daily(
    transaction: &Transaction,
    task_id: &str,
    weekdays: &[u32],
    interval_days: Option<i64>,
    target_seconds: Option<i64>,
    now_ms: i64,
) -> Result<String, CoreError> {
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
    let now = stored(now_ms);
    let existing: Option<(String, Option<String>, Option<i64>)> = transaction
        .query_row(
            "SELECT id, archivedAt, targetSeconds FROM dailies WHERE taskId = ?1",
            [task_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    if let Some((id, archived_at, current_target)) = existing {
        let target = target_seconds.or(current_target);
        if archived_at.is_some() || current_target != target {
            transaction.execute(
                "UPDATE dailies SET archivedAt = NULL, targetSeconds = ?1, updatedAt = ?2 WHERE id = ?3",
                params![target, now, id],
            )?;
        }
        return Ok(id);
    }
    let sort_order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dailies",
        [],
        |row| row.get(0),
    )?;
    let id = new_id();
    transaction.execute(
        "INSERT INTO dailies (id, taskId, activeWeekdaysMask, intervalDays, intervalAnchor, targetSeconds,
                              sortOrder, archivedAt, createdAt, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8, ?8)",
        params![
            id,
            task_id,
            weekday_mask(weekdays),
            interval_days,
            interval_days.map(|_| now.clone()),
            target_seconds,
            sort_order,
            now
        ],
    )?;
    Ok(id)
}

/// Archives a task's daily rather than deleting it, so the contributions
/// already logged keep a parent. Nothing to archive is not an error.
/// Replaces `WorkspaceStore.archiveDaily` and its Kotlin copy.
pub fn archive_daily(
    transaction: &Transaction,
    task_id: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    transaction.execute(
        "UPDATE dailies SET archivedAt = ?1, updatedAt = ?1
         WHERE id = (SELECT id FROM dailies WHERE taskId = ?2 AND archivedAt IS NULL LIMIT 1)",
        params![stored(now_ms), task_id],
    )?;
    Ok(())
}

/// What [`update_daily`] changes. Each field left `None` keeps what is there;
/// the `set_` flags let a caller clear the interval or the target.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct DailyEdit {
    /// Ignored when empty.
    pub weekdays: Option<Vec<u32>>,
    pub set_interval: bool,
    /// Clamped to 1 to 366 days.
    pub interval_days: Option<i64>,
    pub set_target: bool,
    pub target_seconds: Option<i64>,
}

/// A daily's weekday mask, interval, interval anchor and target, as stored.
type DailySchedule = (i64, Option<i64>, Option<String>, Option<i64>);

/// Edits a daily's days, interval and target. A daily that is gone is left
/// alone. Replaces `WorkspaceStore.updateDaily` and its Kotlin copy.
pub fn update_daily(
    transaction: &Transaction,
    id: &str,
    edit: &DailyEdit,
    now_ms: i64,
) -> Result<(), CoreError> {
    let current: Option<DailySchedule> = transaction
        .query_row(
            "SELECT activeWeekdaysMask, intervalDays, intervalAnchor, targetSeconds FROM dailies WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((mut mask, mut interval, mut anchor, mut target)) = current else {
        return Ok(());
    };
    let now = stored(now_ms);
    if let Some(weekdays) = edit.weekdays.as_ref().filter(|days| !days.is_empty()) {
        mask = weekday_mask(weekdays);
    }
    if edit.set_interval {
        interval = edit.interval_days.map(|days| days.clamp(1, 366));
        anchor = match interval {
            Some(_) => anchor.or_else(|| Some(now.clone())),
            None => None,
        };
    }
    if edit.set_target {
        target = edit.target_seconds;
    }
    transaction.execute(
        "UPDATE dailies SET activeWeekdaysMask = ?1, intervalDays = ?2, intervalAnchor = ?3,
                            targetSeconds = ?4, updatedAt = ?5
         WHERE id = ?6",
        params![mask, interval, anchor, target, now, id],
    )?;
    Ok(())
}

/// Records progress on a daily for the day `now` falls on in `zone`, adding
/// to whatever is already logged that day. `complete` marks the day's
/// commitment met; a part-finished focus block passes `false`. Returns the
/// contribution's id. Replaces `WorkspaceStore.logContribution` and its
/// Kotlin copy.
pub fn log_contribution(
    transaction: &Transaction,
    daily_id: &str,
    seconds: i64,
    complete: bool,
    now_ms: i64,
    zone: &str,
) -> Result<String, CoreError> {
    let task_id: String = transaction
        .query_row(
            "SELECT taskId FROM dailies WHERE id = ?1",
            [daily_id],
            |row| row.get(0),
        )
        .optional()?
        .ok_or_else(|| CoreError::MissingDaily {
            id: daily_id.to_string(),
        })?;
    let key = day_key(now_ms, zone);
    let now = stored(now_ms);
    let seconds = seconds.max(0);
    let existing: Option<String> = transaction
        .query_row(
            "SELECT id FROM daily_contributions WHERE dailyId = ?1 AND dayKey = ?2",
            params![daily_id, key],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(id) = existing {
        transaction.execute(
            "UPDATE daily_contributions
             SET secondsLogged = secondsLogged + ?1,
                 completedAt = CASE WHEN ?2 THEN COALESCE(completedAt, ?3) ELSE completedAt END
             WHERE id = ?4",
            params![seconds, complete, now, id],
        )?;
        return Ok(id);
    }
    let id = new_id();
    transaction.execute(
        "INSERT INTO daily_contributions (id, dailyId, taskId, dayKey, secondsLogged, completedAt, createdAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![id, daily_id, task_id, key, seconds, complete.then(|| now.clone()), now],
    )?;
    Ok(id)
}

/// Un-ticks the day `day_ms` falls on in `zone`, keeping the time logged.
/// Replaces `WorkspaceStore.clearContribution` and its Kotlin copy.
pub fn clear_contribution(
    transaction: &Transaction,
    daily_id: &str,
    day_ms: i64,
    zone: &str,
) -> Result<(), CoreError> {
    transaction.execute(
        "UPDATE daily_contributions SET completedAt = NULL WHERE dailyId = ?1 AND dayKey = ?2",
        params![daily_id, day_key(day_ms, zone)],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests;
