//! The pure scheduling rules the clients used to keep a copy of each:
//! when a repeating task next comes round (`periodic.rs`), whether a habit
//! shows on a day (`habits.rs`), when a waiting task's follow-up is due
//! (`waiting.rs`) and whether a daily is expected on a day (`dailies.rs`).
//!
//! This is their surface across UniFFI. Instants cross as milliseconds since
//! 1970 and zones by name; days are worked out here, in the zone, so Swift's
//! `PeriodicSchedule`, `HabitPolicy`, `WaitingFollowUp`, `Daily` and
//! `WorkspaceDaily` and their Kotlin namesakes keep only their types and
//! convert. Nothing here reads the database.

use chrono::{NaiveDate, Weekday};

use crate::dailies;
use crate::habits::{self, Expiry, Rule, local_day, start_of_day_ms};
use crate::periodic::{self, Cadence};
use crate::waiting::{self, FollowUpPlan, WaitingState};

// MARK: - Periodic schedules

/// How often a repeating task comes round. `PeriodicSchedule.Cadence`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PeriodicCadence {
    Days {
        count: u32,
    },
    Weeks {
        count: u32,
    },
    /// Monday to Friday, skipping the weekend.
    Weekdays,
    /// 1 = Sunday through 7 = Saturday, as Foundation counts them.
    Weekday {
        weekday: u32,
    },
}

impl From<Cadence> for PeriodicCadence {
    fn from(cadence: Cadence) -> Self {
        match cadence {
            Cadence::Days(count) => PeriodicCadence::Days { count },
            Cadence::Weeks(count) => PeriodicCadence::Weeks { count },
            Cadence::Weekdays => PeriodicCadence::Weekdays,
            Cadence::Weekday(day) => PeriodicCadence::Weekday {
                weekday: day.number_from_sunday(),
            },
        }
    }
}

impl PeriodicCadence {
    fn cadence(self) -> Option<Cadence> {
        Some(match self {
            PeriodicCadence::Days { count } if count > 0 => Cadence::Days(count),
            PeriodicCadence::Weeks { count } if count > 0 => Cadence::Weeks(count),
            PeriodicCadence::Weekdays => Cadence::Weekdays,
            PeriodicCadence::Weekday { weekday } => Cadence::Weekday(weekday_from_sunday(weekday)?),
            _ => return None,
        })
    }
}

/// 1 = Sunday through 7 = Saturday.
fn weekday_from_sunday(number: u32) -> Option<Weekday> {
    if !(1..=7).contains(&number) {
        return None;
    }
    // chrono counts from Monday = 0: Sunday (1) is 6, Monday (2) is 0.
    Weekday::try_from(((number + 5) % 7) as u8).ok()
}

/// Parses a stored recurrence rule ("daily", "every 3 days", "every monday");
/// `None` for one this app did not write.
#[uniffi::export]
pub fn periodic_cadence(raw: String) -> Option<PeriodicCadence> {
    Cadence::parse(&raw).map(PeriodicCadence::from)
}

/// The first occurrence strictly after `after_ms`, and strictly after
/// `not_before_ms` when given, stepping on the wall clock in `zone`. `None`
/// for a cadence that cannot land. `PeriodicSchedule.nextOccurrence`.
#[uniffi::export]
pub fn periodic_next_occurrence(
    cadence: PeriodicCadence,
    after_ms: i64,
    not_before_ms: Option<i64>,
    zone: String,
) -> Option<i64> {
    let instant = |ms: i64| chrono::DateTime::from_timestamp_millis(ms);
    let next = cadence.cadence()?.next_occurrence(
        instant(after_ms)?,
        not_before_ms.and_then(instant),
        periodic::zone(&zone),
    )?;
    Some(next.timestamp_millis())
}

// MARK: - Habits

/// Everything that decides whether a habit shows on a day. `HabitRule`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HabitRuleSpec {
    /// 1 = Sunday. Empty is every day.
    pub weekdays: Vec<u32>,
    pub interval_days: Option<i64>,
    /// A moment on the habit's first day, which its interval counts from.
    pub anchor_ms: i64,
    pub drops_at_day_end: bool,
    /// "source", "date" or "never"; anything else, or "date" without a date,
    /// is never.
    pub expiry_rule: String,
    pub expires_at_ms: Option<i64>,
    /// The column its appearance lands in.
    pub placement: String,
}

impl HabitRuleSpec {
    fn rule(&self, zone: chrono_tz::Tz) -> Rule {
        let expiry = match (self.expiry_rule.as_str(), self.expires_at_ms) {
            ("source", _) => Expiry::WhenSourceCompleted,
            ("date", Some(at)) => Expiry::On(local_day(at, zone)),
            _ => Expiry::Never,
        };
        Rule {
            weekdays: self.weekdays.clone(),
            interval_days: self.interval_days,
            anchor: local_day(self.anchor_ms, zone),
            drops_at_day_end: self.drops_at_day_end,
            expiry,
            placement: self.placement.clone(),
        }
    }
}

/// One day's appearance of a habit. `HabitAppearance`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HabitShowing {
    pub column: String,
    /// The first moment of the scheduled day it belongs to.
    pub due_day_ms: i64,
    pub is_carried_over: bool,
}

/// Whether the local day `day_ms` falls on is one of the habit's days; never
/// before its anchor. `HabitPolicy.isScheduled`.
#[uniffi::export]
pub fn habit_is_scheduled(rule: HabitRuleSpec, day_ms: i64, zone: String) -> bool {
    let zone = periodic::zone(&zone);
    habits::is_scheduled(&rule.rule(zone), local_day(day_ms, zone))
}

/// Whether the habit has stopped for good by the day `day_ms` falls on.
/// `HabitPolicy.isExpired`.
#[uniffi::export]
pub fn habit_is_expired(
    rule: HabitRuleSpec,
    day_ms: i64,
    source_completed: bool,
    zone: String,
) -> bool {
    let zone = periodic::zone(&zone);
    habits::is_expired(&rule.rule(zone), local_day(day_ms, zone), source_completed)
}

/// The first moment of the most recent scheduled day on or before the one
/// `day_ms` falls on, since the anchor. `HabitPolicy.lastScheduledDay`.
#[uniffi::export]
pub fn habit_last_scheduled_day(rule: HabitRuleSpec, day_ms: i64, zone: String) -> Option<i64> {
    let zone = periodic::zone(&zone);
    habits::last_scheduled_day(&rule.rule(zone), local_day(day_ms, zone))
        .map(|day| start_of_day_ms(day, zone))
}

/// Where the habit stands on the day `day_ms` falls on; `None` when it should
/// not be showing. `HabitPolicy.appearance`.
#[uniffi::export]
pub fn habit_appearance(
    rule: HabitRuleSpec,
    day_ms: i64,
    last_done_ms: Option<i64>,
    source_completed: bool,
    zone: String,
) -> Option<HabitShowing> {
    let zone = periodic::zone(&zone);
    let showing = habits::appearance(
        &rule.rule(zone),
        local_day(day_ms, zone),
        last_done_ms.map(|ms| local_day(ms, zone)),
        source_completed,
    )?;
    Some(HabitShowing {
        column: showing.column,
        due_day_ms: start_of_day_ms(showing.due_day, zone),
        is_carried_over: showing.is_carried_over,
    })
}

/// A column to write: `column` `None` takes the card out of the habit's.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HabitColumnChange {
    pub column: Option<String>,
}

/// The column a habit's card should be in, given where it is and the column
/// its appearance (if any) lands in; `None` leaves it alone. A card moved
/// elsewhere by hand is the user's. `HabitPolicy.reconciledColumn`.
#[uniffi::export]
pub fn habit_reconciled_column(
    current: Option<String>,
    appearance_column: Option<String>,
    placement: String,
) -> Option<HabitColumnChange> {
    let appearance = appearance_column.map(|column| habits::Appearance {
        column,
        due_day: NaiveDate::default(),
        is_carried_over: false,
    });
    habits::reconciled_column(current.as_deref(), appearance.as_ref(), &placement)
        .map(|column| HabitColumnChange { column })
}

/// The Habits list's id in a workspace, the same on every device.
/// `HabitPolicy.habitsListId`.
#[uniffi::export]
pub fn habit_list_id(workspace_id: String) -> String {
    habits::habits_list_id(&workspace_id)
}

// MARK: - Waiting follow-ups

/// The follow-up to make for `task` at `now_ms`, if one is due.
/// `WaitingFollowUp.dueFollowUp`.
#[uniffi::export]
pub fn waiting_due_follow_up(task: WaitingState, now_ms: i64) -> Option<FollowUpPlan> {
    waiting::due_follow_up(&task, now_ms)
}

/// "Follow up with Sam: Contract signed". `WaitingFollowUp.title`.
#[uniffi::export]
pub fn waiting_follow_up_title(title: String, waiting_on: Option<String>) -> String {
    waiting::follow_up_title(&title, waiting_on.as_deref())
}

/// Who a task waits on, trimmed and clipped, or nothing.
/// `WaitingFollowUp.normalizedTag`.
#[uniffi::export]
pub fn waiting_normalized_tag(text: Option<String>) -> Option<String> {
    waiting::normalized_tag(text.as_deref())
}

/// The follow-up's id, the same on every device: it follows the source and
/// the whole second of the follow-up time. `WaitingFollowUp.followUpTaskId`.
#[uniffi::export]
pub fn waiting_follow_up_task_id(source_task_id: String, follow_up_at_ms: i64) -> String {
    waiting::follow_up_task_id(&source_task_id, follow_up_at_ms)
}

// MARK: - Dailies

/// Whether a workspace daily is expected on the day `day_ms` falls on.
/// `WorkspaceDaily.isDue(on:)`; the caller rules out an archived one.
#[uniffi::export]
pub fn workspace_daily_is_due(
    weekdays_mask: i64,
    interval_days: Option<i64>,
    anchor_ms: i64,
    day_ms: i64,
    zone: String,
) -> bool {
    let zone = periodic::zone(&zone);
    dailies::workspace_daily_is_due(
        Some(weekdays_mask),
        interval_days,
        local_day(anchor_ms, zone),
        local_day(day_ms, zone),
    )
}

/// Whether a plugin-era daily is expected on the day `day_ms` falls on.
/// `Daily.isDue(on:)`.
#[uniffi::export]
pub fn plugin_daily_is_due(
    archived: bool,
    weekdays: Vec<u32>,
    interval_days: Option<i64>,
    anchor_ms: i64,
    day_ms: i64,
    zone: String,
) -> bool {
    let zone = periodic::zone(&zone);
    dailies::plugin_daily_is_due(
        archived,
        &weekdays,
        interval_days,
        local_day(anchor_ms, zone),
        local_day(day_ms, zone),
    )
}

#[cfg(test)]
mod tests;
