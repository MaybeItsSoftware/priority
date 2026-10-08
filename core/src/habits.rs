//! Habits: dailies made through the habit form, with a board column each
//! appearance lands in, a choice about missed days, and an end. The rule
//! logic replaces `HabitPolicy` in Swift's TaktCore and its Kotlin port; the
//! writes replace `WorkspaceStore+Habits.swift`'s.
//!
//! Days are calendar days in the user's zone. A habit is anchored on the day
//! it was made, so "every 3 days" counts from then and nothing is owed from
//! before it.

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};
use chrono_tz::Tz;
use rusqlite::{OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};

use crate::CoreError;
use crate::dailies;
use crate::periodic;
use crate::time::{non_empty_name, parse_stored, stored};

/// How far back a carried appearance is looked for.
const CARRY_LOOKBACK_DAYS: i64 = 366;
/// The list a new habit goes in.
pub const HABITS_LIST_NAME: &str = "Habits";

/// When a habit stops appearing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Expiry {
    Never,
    /// When the task it was made from is closed or gone.
    WhenSourceCompleted,
    /// From the start of this local day onwards.
    On(NaiveDate),
}

/// Everything that decides whether a habit shows up on a day. `HabitRule`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// Foundation's numbering, 1 = Sunday. Empty means every day.
    pub weekdays: Vec<u32>,
    pub interval_days: Option<i64>,
    pub anchor: NaiveDate,
    /// Off: a missed appearance is carried until done. On: a missed day is a gap.
    pub drops_at_day_end: bool,
    pub expiry: Expiry,
    pub placement: String,
}

/// One day's appearance: the column it lands in, the scheduled day it
/// belongs to, and whether that day has passed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Appearance {
    pub column: String,
    pub due_day: NaiveDate,
    pub is_carried_over: bool,
}

/// Whether `day` is one of the habit's scheduled days; never before its anchor.
pub fn is_scheduled(rule: &Rule, day: NaiveDate) -> bool {
    if day < rule.anchor {
        return false;
    }
    if let Some(interval) = rule.interval_days.filter(|interval| *interval > 1) {
        return (day - rule.anchor).num_days() % interval == 0;
    }
    rule.weekdays.is_empty() || rule.weekdays.contains(&day.weekday().number_from_sunday())
}

/// Whether the habit has stopped for good by `day`.
pub fn is_expired(rule: &Rule, day: NaiveDate, source_completed: bool) -> bool {
    match rule.expiry {
        Expiry::Never => false,
        Expiry::WhenSourceCompleted => source_completed,
        Expiry::On(date) => day >= date,
    }
}

/// The most recent scheduled day on or before `day`, since the anchor.
pub fn last_scheduled_day(rule: &Rule, day: NaiveDate) -> Option<NaiveDate> {
    let mut cursor = day;
    for _ in 0..=CARRY_LOOKBACK_DAYS {
        if cursor < rule.anchor {
            return None;
        }
        if is_scheduled(rule, cursor) {
            return Some(cursor);
        }
        cursor -= Duration::days(1);
    }
    None
}

/// Where the habit stands on `day`; `None` when it should not be showing.
pub fn appearance(
    rule: &Rule,
    day: NaiveDate,
    last_done: Option<NaiveDate>,
    source_completed: bool,
) -> Option<Appearance> {
    if is_expired(rule, day, source_completed) || last_done == Some(day) {
        return None;
    }
    if is_scheduled(rule, day) {
        return Some(Appearance {
            column: rule.placement.clone(),
            due_day: day,
            is_carried_over: false,
        });
    }
    if rule.drops_at_day_end {
        return None;
    }
    let owed = last_scheduled_day(rule, day)?;
    if last_done.is_some_and(|done| done >= owed) {
        return None;
    }
    Some(Appearance {
        column: rule.placement.clone(),
        due_day: owed,
        is_carried_over: true,
    })
}

/// The column a habit's task should be in: `Some(Some(column))` to put it
/// there, `Some(None)` to take it out of the habit's column, `None` to leave
/// it. A card moved elsewhere by hand is the user's.
pub fn reconciled_column(
    current: Option<&str>,
    appearance: Option<&Appearance>,
    placement: &str,
) -> Option<Option<String>> {
    match appearance {
        Some(appearance) => current.is_none().then(|| Some(appearance.column.clone())),
        None => (current == Some(placement)).then_some(None),
    }
}

/// The Habits list's id in a workspace: a UUID-shaped SHA-256 of
/// `takt.habits-list:<workspace id>`, so two devices that each make it make
/// one row. `HabitPolicy.habitsListId`.
pub fn habits_list_id(workspace_id: &str) -> String {
    let digest = Sha256::digest(format!("takt.habits-list:{workspace_id}").as_bytes());
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

/// What the habit form saves. The schedule arrives as the daily stores it
/// (a weekday mask's days and an interval), which each client derives from
/// its own frequency type.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HabitDraft {
    pub title: String,
    pub weekdays: Vec<u32>,
    pub interval_days: Option<i64>,
    pub drops_at_day_end: bool,
    pub estimate_seconds: Option<i64>,
    /// "never", "source" or "date".
    pub expiry_rule: String,
    pub expires_at_ms: Option<i64>,
    /// "today", "this-week" or "waiting-on".
    pub placement: String,
    pub source_task_id: Option<String>,
}

/// Creates a habit, or rewrites the one on `habit_task_id`, and returns its
/// daily's id. A new habit is a task in the Habits list, beside the task it
/// came from rather than under it, so finishing the source is not blocked by
/// a child that recurs forever. It lands in its column at once if it is due
/// today. `WorkspaceStore.saveHabit`.
pub fn save_habit(
    transaction: &Transaction,
    draft: &HabitDraft,
    habit_task_id: Option<&str>,
    now_ms: i64,
    zone: &str,
) -> Result<String, CoreError> {
    let title = non_empty_name(&draft.title)?;
    let zone = periodic::zone(zone);
    let now = stored(now_ms);
    let task_id = match habit_task_id {
        Some(id) => {
            let current: Option<(String, Option<i64>)> = transaction
                .query_row(
                    "SELECT title, estimateSeconds FROM tasks WHERE id = ?1",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((current_title, current_estimate)) = current else {
                return Err(CoreError::MissingTask { id: id.to_string() });
            };
            if current_title != title || current_estimate != draft.estimate_seconds {
                transaction.execute(
                    "UPDATE tasks SET title = ?1, estimateSeconds = ?2, updatedAt = ?3 WHERE id = ?4",
                    params![title, draft.estimate_seconds, now, id],
                )?;
            }
            id.to_string()
        }
        None => {
            let workspace_id: String = transaction
                .query_row("SELECT id FROM workspaces LIMIT 1", [], |row| row.get(0))
                .optional()?
                .ok_or_else(|| CoreError::MissingList {
                    id: HABITS_LIST_NAME.to_string(),
                })?;
            let list_id = habits_list(transaction, &workspace_id, now_ms)?;
            let order: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ?1 AND parentTaskId IS NULL",
                [&list_id],
                |row| row.get(0),
            )?;
            let id = crate::lists::new_id();
            transaction.execute(
                "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
                                    sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
                 VALUES (?1, ?2, NULL, ?3, '', 'open', ?4, NULL, ?5, NULL, NULL, 'task', NULL, NULL, NULL, ?6, ?6)",
                params![id, list_id, title, order, draft.estimate_seconds, now],
            )?;
            id
        }
    };

    let daily_id = dailies::make_daily(
        transaction,
        &task_id,
        &[1, 2, 3, 4, 5, 6, 7],
        None,
        draft.estimate_seconds,
        now_ms,
    )?;
    let (previous_placement, current_interval, current_anchor): (
        Option<String>,
        Option<i64>,
        Option<String>,
    ) = transaction.query_row(
        "SELECT placementColumn, intervalDays, intervalAnchor FROM dailies WHERE id = ?1",
        [&daily_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    let interval = draft.interval_days;
    let anchor = if current_interval != interval || current_anchor.is_none() {
        let from = current_anchor
            .as_deref()
            .and_then(parse_stored)
            .map_or(now_ms, |at| at.timestamp_millis());
        Some(stored(start_of_day_ms(local_day(from, zone), zone)))
    } else {
        current_anchor
    };
    let expires_at = if draft.expiry_rule == "date" {
        draft
            .expires_at_ms
            .map(|at| stored(start_of_day_ms(local_day(at, zone), zone)))
    } else {
        None
    };
    transaction.execute(
        "UPDATE dailies SET activeWeekdaysMask = ?1, intervalAnchor = ?2, intervalDays = ?3, targetSeconds = ?4,
                            sourceTaskId = ?5, placementColumn = ?6, dropsAtDayEnd = ?7, expiryRule = ?8,
                            expiresAt = ?9, updatedAt = ?10
         WHERE id = ?11",
        params![
            dailies::weekday_mask(&draft.weekdays),
            anchor,
            interval,
            draft.estimate_seconds,
            draft.source_task_id,
            draft.placement,
            draft.drops_at_day_end,
            draft.expiry_rule,
            expires_at,
            now,
            daily_id
        ],
    )?;
    // Moving a habit to another column takes its card along.
    if let Some(previous) = previous_placement
        && previous != draft.placement
        && kanban_column(transaction, &task_id)?.as_deref() == Some(previous.as_str())
    {
        write_column(transaction, &task_id, None, now_ms)?;
    }
    reconcile_habit(transaction, &daily_id, now_ms, zone)?;
    Ok(daily_id)
}

/// Applies every placed habit's options for `now`: expired ones are archived,
/// a due appearance is put in its column, and one that is done, dropped at
/// the end of its day or no longer due is taken out. Not an undo step.
/// Returns whether anything changed. `WorkspaceStore.reconcileHabits`.
pub fn reconcile_habits(
    transaction: &Transaction,
    now_ms: i64,
    zone: &str,
) -> Result<bool, CoreError> {
    let zone = periodic::zone(zone);
    let mut statement = transaction.prepare(
        "SELECT id FROM dailies WHERE archivedAt IS NULL AND placementColumn IS NOT NULL",
    )?;
    let ids: Vec<String> = statement
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut changed = false;
    for id in ids {
        changed |= reconcile_habit(transaction, &id, now_ms, zone)?;
    }
    Ok(changed)
}

/// Whether any habit is live, so a caller can skip the write when none is.
pub fn any_live(connection: &rusqlite::Connection) -> Result<bool, CoreError> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM dailies WHERE archivedAt IS NULL AND placementColumn IS NOT NULL)",
        [],
        |row| row.get(0),
    )?)
}

/// Whether a habit is showing on the local day `now_ms` falls on: scheduled,
/// or carried from a missed day it does not drop. `WorkspaceStore.habitShows`.
pub(crate) fn habit_shows(
    connection: &rusqlite::Connection,
    daily_id: &str,
    now_ms: i64,
    zone: Tz,
) -> Result<bool, CoreError> {
    let Some(StoredRule {
        rule,
        source_task_id,
        ..
    }) = stored_rule(connection, daily_id, zone)?
    else {
        return Ok(false);
    };
    let source_completed = source_is_completed(connection, source_task_id.as_deref())?;
    let today = local_day(now_ms, zone);
    if is_expired(&rule, today, source_completed) {
        return Ok(false);
    }
    if is_scheduled(&rule, today) {
        return Ok(true);
    }
    let last_done = last_done_day(connection, daily_id)?;
    Ok(appearance(&rule, today, last_done, source_completed).is_some())
}

fn source_is_completed(
    connection: &rusqlite::Connection,
    source: Option<&str>,
) -> Result<bool, CoreError> {
    Ok(match source {
        None => false,
        Some(source) => connection
            .query_row("SELECT status FROM tasks WHERE id = ?1", [source], |row| {
                row.get::<_, String>(0)
            })
            .optional()?
            .is_none_or(|status| status != "open"),
    })
}

fn last_done_day(
    connection: &rusqlite::Connection,
    daily_id: &str,
) -> Result<Option<NaiveDate>, CoreError> {
    let key: Option<String> = connection.query_row(
        "SELECT MAX(dayKey) FROM daily_contributions WHERE dailyId = ?1 AND completedAt IS NOT NULL",
        [daily_id],
        |row| row.get(0),
    )?;
    Ok(key.and_then(|key| NaiveDate::parse_from_str(&key, "%Y-%m-%d").ok()))
}

/// One habit's pass. `WorkspaceStore.reconcileHabit`.
fn reconcile_habit(
    transaction: &Transaction,
    daily_id: &str,
    now_ms: i64,
    zone: Tz,
) -> Result<bool, CoreError> {
    let Some(stored_rule) = stored_rule(transaction, daily_id, zone)? else {
        return Ok(false);
    };
    let StoredRule {
        task_id,
        rule,
        source_task_id,
    } = stored_rule;
    let open: Option<String> = transaction
        .query_row(
            "SELECT status FROM tasks WHERE id = ?1",
            [&task_id],
            |row| row.get(0),
        )
        .optional()?;
    if open.as_deref() != Some("open") {
        return Ok(false);
    }
    let source_completed = source_is_completed(transaction, source_task_id.as_deref())?;
    let today = local_day(now_ms, zone);
    let current = kanban_column(transaction, &task_id)?;
    if is_expired(&rule, today, source_completed) {
        transaction.execute(
            "UPDATE dailies SET archivedAt = ?1, updatedAt = ?1 WHERE id = ?2",
            params![stored(now_ms), daily_id],
        )?;
        if current.as_deref() == Some(rule.placement.as_str()) {
            write_column(transaction, &task_id, None, now_ms)?;
        }
        return Ok(true);
    }
    let last_done = last_done_day(transaction, daily_id)?;
    let showing = appearance(&rule, today, last_done, source_completed);
    match reconciled_column(current.as_deref(), showing.as_ref(), &rule.placement) {
        Some(target) => {
            write_column(transaction, &task_id, target.as_deref(), now_ms)?;
            Ok(true)
        }
        None => Ok(false),
    }
}

struct StoredRule {
    task_id: String,
    rule: Rule,
    source_task_id: Option<String>,
}

/// A placed, unarchived habit's rule as stored; `None` for anything else.
fn stored_rule(
    transaction: &rusqlite::Connection,
    daily_id: &str,
    zone: Tz,
) -> Result<Option<StoredRule>, CoreError> {
    type Row = (
        String,
        i64,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<bool>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
    );
    let row: Option<Row> = transaction
        .query_row(
            "SELECT taskId, activeWeekdaysMask, intervalDays, intervalAnchor, placementColumn, dropsAtDayEnd,
                    expiryRule, expiresAt, sourceTaskId, createdAt, archivedAt
             FROM dailies WHERE id = ?1",
            [daily_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                ))
            },
        )
        .optional()?;
    let Some((
        task_id,
        mask,
        interval,
        anchor,
        placement,
        drops,
        expiry_rule,
        expires_at,
        source,
        created,
        archived,
    )) = row
    else {
        return Ok(None);
    };
    let Some(placement) =
        placement.filter(|p| matches!(p.as_str(), "today" | "this-week" | "waiting-on"))
    else {
        return Ok(None);
    };
    if archived.is_some() {
        return Ok(None);
    }
    let anchor_ms = anchor
        .as_deref()
        .or(Some(created.as_str()))
        .and_then(parse_stored)
        .map_or(0, |at| at.timestamp_millis());
    let expiry = match expiry_rule.as_deref() {
        Some("source") => Expiry::WhenSourceCompleted,
        Some("date") => expires_at
            .as_deref()
            .and_then(parse_stored)
            .map_or(Expiry::Never, |at| {
                Expiry::On(local_day(at.timestamp_millis(), zone))
            }),
        _ => Expiry::Never,
    };
    let weekdays = (1..=7).filter(|day| mask & (1 << (day - 1)) != 0).collect();
    Ok(Some(StoredRule {
        task_id,
        rule: Rule {
            weekdays,
            interval_days: interval,
            anchor: local_day(anchor_ms, zone),
            drops_at_day_end: drops.unwrap_or(true),
            expiry,
            placement,
        },
        source_task_id: source,
    }))
}

/// The Habits list in a workspace, made if it is not there: found by its
/// derived id, or failing that by name. `WorkspaceStore.habitsList`.
pub(crate) fn habits_list(
    transaction: &Transaction,
    workspace_id: &str,
    now_ms: i64,
) -> Result<String, CoreError> {
    let id = habits_list_id(workspace_id);
    let existing: Option<String> = transaction
        .query_row(
            "SELECT id FROM task_lists WHERE id = ?1
             UNION ALL
             SELECT id FROM task_lists WHERE workspaceId = ?2 AND name = ?3
             LIMIT 1",
            params![id, workspace_id, HABITS_LIST_NAME],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(existing) = existing {
        return Ok(existing);
    }
    let order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?1",
        [workspace_id],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived,
                                 createdAt, updatedAt, systemRole, visibleRootTaskId, completedAt)
         VALUES (?1, ?2, NULL, ?3, NULL, ?4, 0, ?5, ?5, NULL, NULL, NULL)",
        params![id, workspace_id, HABITS_LIST_NAME, order, stored(now_ms)],
    )?;
    Ok(id)
}

fn kanban_column(transaction: &Transaction, task_id: &str) -> Result<Option<String>, CoreError> {
    Ok(transaction
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()?
        .flatten())
}

/// `WorkspaceStore.writeKanbanColumn`: taking a card out of a column also
/// takes it off the day's ladder.
fn write_column(
    transaction: &Transaction,
    task_id: &str,
    column: Option<&str>,
    now_ms: i64,
) -> Result<(), CoreError> {
    transaction.execute(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
         VALUES (?1, '[]', '[]', ?2, ?3)
         ON CONFLICT(taskId) DO UPDATE SET
           kanbanColumn = excluded.kanbanColumn,
           focusRank = CASE WHEN excluded.kanbanColumn IS NULL THEN NULL ELSE focusRank END,
           updatedAt = excluded.updatedAt",
        params![task_id, column, stored(now_ms)],
    )?;
    Ok(())
}

/// The local calendar day a moment falls on in `zone`.
pub(crate) fn local_day(ms: i64, zone: Tz) -> NaiveDate {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&zone)
        .date_naive()
}

/// The first moment of a local day in `zone`, as milliseconds.
fn start_of_day_ms(day: NaiveDate, zone: Tz) -> i64 {
    periodic::resolve(zone, day.and_hms_opt(0, 0, 0).expect("midnight exists")).timestamp_millis()
}

#[cfg(test)]
mod tests;
