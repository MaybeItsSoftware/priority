//! Focus and progress statistics: what the review screens, the timeline and
//! the status bar say about work already done.
//!
//! These summarise many sessions or tasks into a few numbers, so each is one
//! call: the inputs cross once and the summary comes back, and where the
//! inputs are rows (`CoreWorkspace::work_progress`,
//! `CoreWorkspace::resolve_stale_focus_session`) the rows never cross at all.
//! Engines that hand back the caller's own items (the day's blocks, the
//! finished tasks) return indices into the input rather than the items, so a
//! title crosses at most once.
//!
//! Every time zone calculation takes the zone's IANA name and a moment in
//! milliseconds, as `periodic.rs` does. Replaces Swift's `FocusDayTimeline`,
//! `WorkProgressSummary`, `TaskProgressSeries`, `CompletedWorkDigest`,
//! `StaleFocusPolicy`, `FocusPoints`' scoring and
//! `CompletionMilestonePolicy.milestone`, and the Kotlin ports of them.

use std::collections::HashMap;

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};
use chrono_tz::Tz;
use rusqlite::{Connection, TransactionBehavior};

use crate::CoreError;
use crate::focus::{self, FocusContext};
use crate::journal;
use crate::periodic;
use crate::rows;
use crate::workspace::CoreWorkspace;

const HOUR_MS: i64 = 3_600_000;

// -- time helpers -------------------------------------------------------------

fn local(ms: i64, zone: Tz) -> DateTime<Tz> {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&zone)
}

fn local_date(ms: i64, zone: Tz) -> NaiveDate {
    local(ms, zone).date_naive()
}

/// The first moment of `date` in `zone`: `Calendar.startOfDay`.
fn start_of(date: NaiveDate, zone: Tz) -> i64 {
    periodic::resolve(zone, date.and_hms_opt(0, 0, 0).expect("midnight exists")).timestamp_millis()
}

#[cfg(test)]
fn start_of_day(ms: i64, zone: Tz) -> i64 {
    start_of(local_date(ms, zone), zone)
}

/// The instant the logical day containing `ms` began, a day running from
/// `rollover_hour` rather than midnight: `DayBoundary.logicalDay`.
fn logical_day(ms: i64, rollover_hour: u8, zone: Tz) -> i64 {
    let hour = u32::from(rollover_hour.min(23));
    let shifted = local_date(ms - i64::from(hour) * HOUR_MS, zone);
    periodic::resolve(
        zone,
        shifted.and_hms_opt(hour, 0, 0).expect("an hour of the day"),
    )
    .timestamp_millis()
}

/// Midnight on the first day of the week holding `date`, where
/// `first_weekday` counts as Foundation's `Calendar.firstWeekday` does
/// (1 is Sunday, 2 Monday); anything out of range reads as Sunday.
fn week_start_date(date: NaiveDate, first_weekday: u8) -> NaiveDate {
    let first = if (1..=7).contains(&first_weekday) {
        u32::from(first_weekday) - 1
    } else {
        0
    };
    let today = date.weekday().num_days_from_sunday();
    let back = (today + 7 - first) % 7;
    date - Duration::days(i64::from(back))
}

// -- work progress ------------------------------------------------------------

/// A focus block as the week's summary needs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct WorkBlockSeconds {
    pub seconds: i64,
    pub recorded_at_ms: i64,
}

/// Today set against the week it belongs to: `WorkProgress`'s stored half.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct WorkProgressTotals {
    pub today_completed: i64,
    pub today_seconds: i64,
    pub week_completed: i64,
    pub week_seconds: i64,
    /// Days of the week that have happened, today included. At least one.
    pub elapsed_days: i64,
}

/// Midnight on the first day of the user's week holding `date_ms`.
/// `WorkProgressSummary.startOfWeek`.
#[uniffi::export]
pub fn start_of_week_ms(date_ms: i64, zone: String, first_weekday: u8) -> i64 {
    let tz = periodic::zone(&zone);
    start_of(week_start_date(local_date(date_ms, tz), first_weekday), tz)
}

/// Today's and this week's completions and focused seconds, every interval
/// half open so midnight belongs to one day. `WorkProgressSummary.summarise`.
#[uniffi::export]
pub fn summarise_work_progress(
    completions_ms: Vec<i64>,
    blocks: Vec<WorkBlockSeconds>,
    now_ms: i64,
    zone: String,
    first_weekday: u8,
) -> WorkProgressTotals {
    summarise(
        &completions_ms,
        &blocks,
        now_ms,
        periodic::zone(&zone),
        first_weekday,
    )
}

fn summarise(
    completions: &[i64],
    blocks: &[WorkBlockSeconds],
    now_ms: i64,
    zone: Tz,
    first_weekday: u8,
) -> WorkProgressTotals {
    let today = local_date(now_ms, zone);
    let start_of_today = start_of(today, zone);
    let end_of_today = start_of(today + Duration::days(1), zone);
    let week_date = week_start_date(today, first_weekday);
    let week_start = start_of(week_date, zone);
    let totals = |from: i64, to: i64| {
        let completed = completions
            .iter()
            .filter(|at| **at >= from && **at < to)
            .count() as i64;
        let seconds = blocks
            .iter()
            .filter(|block| block.recorded_at_ms >= from && block.recorded_at_ms < to)
            .map(|block| block.seconds.max(0))
            .sum::<i64>();
        (completed, seconds)
    };
    let (today_completed, today_seconds) = totals(start_of_today, end_of_today);
    let (week_completed, week_seconds) = totals(week_start, end_of_today);
    WorkProgressTotals {
        today_completed,
        today_seconds,
        week_completed,
        week_seconds,
        elapsed_days: ((today - week_date).num_days() + 1).max(1),
    }
}

/// The week's progress from the rows themselves, so neither the completions
/// nor the blocks cross. `WorkspaceStore.workProgress`.
pub fn work_progress(
    connection: &Connection,
    now_ms: i64,
    zone: &str,
    first_weekday: u8,
) -> Result<WorkProgressTotals, CoreError> {
    let tz = periodic::zone(zone);
    let today = local_date(now_ms, tz);
    let start = start_of(week_start_date(today, first_weekday), tz);
    let end = start_of(today + Duration::days(1), tz);
    if end <= start {
        return Ok(summarise(&[], &[], now_ms, tz, first_weekday));
    }
    let completions = rows::completions_between(connection, start, end)?;
    let blocks: Vec<WorkBlockSeconds> = rows::work_blocks_between(connection, start, end)?
        .into_iter()
        .map(|block| WorkBlockSeconds {
            seconds: block.seconds,
            recorded_at_ms: block.recorded_at_ms,
        })
        .collect();
    Ok(summarise(&completions, &blocks, now_ms, tz, first_weekday))
}

// -- task progress over a period -------------------------------------------

/// A half-open span of time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MillisInterval {
    pub start_ms: i64,
    pub end_ms: i64,
}

/// One day on the progress graph. `TaskProgressDay`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TaskProgressCount {
    pub day_start_ms: i64,
    pub completed: i64,
    pub added: i64,
    pub cumulative_completed: i64,
}

/// From the start of the period's first day to the end of today, half open.
/// `TaskProgressSeries.interval`.
#[uniffi::export]
pub fn task_progress_interval(days: u32, now_ms: i64, zone: String) -> MillisInterval {
    interval(days, now_ms, periodic::zone(&zone))
}

fn interval(days: u32, now_ms: i64, zone: Tz) -> MillisInterval {
    let today = local_date(now_ms, zone);
    let back = i64::from(days.max(1)) - 1;
    MillisInterval {
        start_ms: start_of(today - Duration::days(back), zone),
        end_ms: start_of(today + Duration::days(1), zone),
    }
}

/// Completions and creations bucketed into the period's days, every day
/// present, times outside the period ignored. `TaskProgressSeries.build`.
#[uniffi::export]
pub fn task_progress_days(
    days: u32,
    completions_ms: Vec<i64>,
    creations_ms: Vec<i64>,
    now_ms: i64,
    zone: String,
) -> Vec<TaskProgressCount> {
    let tz = periodic::zone(&zone);
    let span = interval(days, now_ms, tz);
    let counts = |moments: &[i64]| {
        let mut counts: HashMap<NaiveDate, i64> = HashMap::new();
        for at in moments
            .iter()
            .filter(|at| **at >= span.start_ms && **at < span.end_ms)
        {
            *counts.entry(local_date(*at, tz)).or_default() += 1;
        }
        counts
    };
    let done = counts(&completions_ms);
    let added = counts(&creations_ms);
    let mut running = 0;
    let mut result = Vec::new();
    let mut date = local_date(span.start_ms, tz);
    loop {
        let day_start = start_of(date, tz);
        if day_start >= span.end_ms {
            break;
        }
        let completed = done.get(&date).copied().unwrap_or(0);
        running += completed;
        result.push(TaskProgressCount {
            day_start_ms: day_start,
            completed,
            added: added.get(&date).copied().unwrap_or(0),
            cumulative_completed: running,
        });
        date += Duration::days(1);
    }
    result
}

// -- finished work by day -----------------------------------------------------

/// How far back a day is from today, as a relation. `CompletedWorkDayKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CompletedDayKind {
    Today,
    Yesterday,
    /// Two to six days back, where a weekday name is still unambiguous.
    ThisWeek,
    Earlier,
}

/// One day of finished work: indices into the caller's items, newest first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CompletedDay {
    pub day_start_ms: i64,
    pub kind: CompletedDayKind,
    pub items: Vec<u32>,
}

/// Counted in calendar days, both ends taken to their day's start first.
/// `CompletedWorkDigest.kind`.
#[uniffi::export]
pub fn completed_day_kind(day_ms: i64, now_ms: i64, zone: String) -> CompletedDayKind {
    let tz = periodic::zone(&zone);
    kind_of(local_date(day_ms, tz), local_date(now_ms, tz))
}

fn kind_of(day: NaiveDate, today: NaiveDate) -> CompletedDayKind {
    match (today - day).num_days() {
        ..=0 => CompletedDayKind::Today,
        1 => CompletedDayKind::Yesterday,
        2..=6 => CompletedDayKind::ThisWeek,
        _ => CompletedDayKind::Earlier,
    }
}

/// Items grouped by the calendar day they were finished on, days newest
/// first and each day's items newest first. `CompletedWorkDigest.group`.
#[uniffi::export]
pub fn group_completed_work(
    completed_at_ms: Vec<i64>,
    now_ms: i64,
    zone: String,
) -> Vec<CompletedDay> {
    let tz = periodic::zone(&zone);
    let today = local_date(now_ms, tz);
    let mut buckets: HashMap<NaiveDate, Vec<u32>> = HashMap::new();
    for (index, at) in completed_at_ms.iter().enumerate() {
        buckets
            .entry(local_date(*at, tz))
            .or_default()
            .push(index as u32);
    }
    let mut days: Vec<NaiveDate> = buckets.keys().copied().collect();
    days.sort_unstable_by(|a, b| b.cmp(a));
    days.into_iter()
        .map(|date| {
            let mut items = buckets.remove(&date).unwrap_or_default();
            items.sort_by(|a, b| completed_at_ms[*b as usize].cmp(&completed_at_ms[*a as usize]));
            CompletedDay {
                day_start_ms: start_of(date, tz),
                kind: kind_of(date, today),
                items,
            }
        })
        .collect()
}

// -- the day's focus timeline -------------------------------------------------

/// The narrowest the ruler gets, in hours.
pub const TIMELINE_MINIMUM_HOURS: i64 = 5;
/// What a day with nothing in it shows.
pub const TIMELINE_DEFAULT_WINDOW: (i64, i64) = (9, 18);

/// A block of work as the timeline needs it: logged at `ended_at_ms` after
/// `seconds` of work. `FocusDayTimeline.Block`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TimelineBlock {
    pub id: String,
    pub seconds: i64,
    pub ended_at_ms: i64,
}

/// A block given a position. `block` indexes the input.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TimelinePlacement {
    pub block: u32,
    pub offset_minutes: f64,
    pub minutes: f64,
    pub lane: u32,
}

/// The hour-aligned window a day is drawn through, and what sits in it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TimelineLayout {
    pub start_ms: i64,
    pub end_ms: i64,
    pub placements: Vec<TimelinePlacement>,
    /// At least one.
    pub lane_count: u32,
}

/// Lays out the day containing `day_ms`: each block runs from `ended_at -
/// seconds` to `ended_at`, clamped to the day; zero-length blocks are
/// dropped; a block takes the leftmost lane free when it starts.
/// `FocusDayTimeline.layout`.
#[uniffi::export]
pub fn focus_day_layout(blocks: Vec<TimelineBlock>, day_ms: i64, zone: String) -> TimelineLayout {
    let tz = periodic::zone(&zone);
    let day = local_date(day_ms, tz);
    let day_start = start_of(day, tz);
    let day_end = start_of(day + Duration::days(1), tz);

    let mut spans: Vec<(u32, i64, i64)> = Vec::new();
    for (index, block) in blocks.iter().enumerate() {
        if block.seconds <= 0 {
            continue;
        }
        let end = block.ended_at_ms.clamp(day_start, day_end.max(day_start));
        let start = (end - block.seconds * 1000).max(day_start);
        if end <= start {
            continue;
        }
        spans.push((index as u32, start, end));
    }
    spans.sort_by(|a, b| {
        a.1.cmp(&b.1)
            .then_with(|| blocks[a.0 as usize].id.cmp(&blocks[b.0 as usize].id))
    });

    let (window_start, window_end) = window(&spans, day_start, day_end);
    let mut lane_ends: Vec<i64> = Vec::new();
    let mut placements = Vec::new();
    for (index, start, end) in spans {
        let lane = lane_ends
            .iter()
            .position(|lane_end| *lane_end <= start)
            .unwrap_or(lane_ends.len());
        if lane == lane_ends.len() {
            lane_ends.push(end);
        } else {
            lane_ends[lane] = end;
        }
        placements.push(TimelinePlacement {
            block: index,
            offset_minutes: (start - window_start) as f64 / 60_000.0,
            minutes: (end - start) as f64 / 60_000.0,
            lane: lane as u32,
        });
    }
    TimelineLayout {
        start_ms: window_start,
        end_ms: window_end,
        placements,
        lane_count: lane_ends.len().max(1) as u32,
    }
}

/// Whole hours around every span, widened to the minimum and pushed back
/// inside the day rather than overhanging it.
fn window(spans: &[(u32, i64, i64)], day_start: i64, day_end: i64) -> (i64, i64) {
    let earliest = spans.iter().map(|span| span.1).min();
    let latest = spans.iter().map(|span| span.2).max();
    let (Some(earliest), Some(latest)) = (earliest, latest) else {
        let (from, to) = TIMELINE_DEFAULT_WINDOW;
        return (day_start + from * HOUR_MS, day_start + to * HOUR_MS);
    };
    let floor_hours = (earliest - day_start).div_euclid(HOUR_MS).max(0);
    let ceil_hours = (-((-(latest - day_start)).div_euclid(HOUR_MS))).max(1);
    let mut start = day_start + floor_hours * HOUR_MS;
    let mut end = day_start + ceil_hours * HOUR_MS;
    let minimum = TIMELINE_MINIMUM_HOURS * HOUR_MS;
    if end - start < minimum {
        end = start + minimum;
        if end > day_end {
            end = day_end;
            start = day_start.max(end - minimum);
        }
    }
    (start, end)
}

/// A block's task, for the breakdown under the chart.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FocusTimelineEntry {
    /// The task's id where the block names one, else its title.
    pub key: String,
    pub seconds: i64,
}

/// One task's share of the day. `latest` indexes the input entry whose title
/// names it, the last of the task's blocks.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TimelineSummary {
    pub key: String,
    pub latest: u32,
    pub seconds: i64,
    pub blocks: u32,
}

/// The day's blocks gathered by task, most time first, ties by key.
/// `FocusDayTimeline.summaries`.
#[uniffi::export]
pub fn focus_day_summaries(entries: Vec<FocusTimelineEntry>) -> Vec<TimelineSummary> {
    let mut by_key: HashMap<&str, TimelineSummary> = HashMap::new();
    for (index, entry) in entries.iter().enumerate() {
        let summary = by_key
            .entry(entry.key.as_str())
            .or_insert_with(|| TimelineSummary {
                key: entry.key.clone(),
                latest: 0,
                seconds: 0,
                blocks: 0,
            });
        summary.latest = index as u32;
        summary.seconds += entry.seconds.max(0);
        summary.blocks += 1;
    }
    let mut summaries: Vec<TimelineSummary> = by_key.into_values().collect();
    summaries.sort_by(|a, b| b.seconds.cmp(&a.seconds).then_with(|| a.key.cmp(&b.key)));
    summaries
}

// -- a block left paused --------------------------------------------------------

/// What becomes of a block that was paused and then left.
/// `StaleFocusResolution`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StaleFocusOutcome {
    /// Still today's block; it stays paused.
    Keep,
    /// Close it out, crediting its seconds to the day it was worked on.
    Close,
    /// End it without crediting anything.
    Discard,
}

/// Under a minute is not a sitting.
pub const MINIMUM_CREDITED_SECONDS: i64 = 60;

/// Whether a paused session is still live: one paused on an earlier logical
/// day is closed, or discarded under a minute; one with no task on it is
/// discarded at once. `StaleFocusPolicy.resolution`.
#[uniffi::export]
pub fn stale_focus_outcome(
    paused_at_ms: Option<i64>,
    accumulated_seconds: i64,
    has_active_task: bool,
    now_ms: i64,
    rollover_hour: u8,
    zone: String,
) -> StaleFocusOutcome {
    stale_outcome(
        paused_at_ms,
        accumulated_seconds,
        has_active_task,
        now_ms,
        rollover_hour,
        periodic::zone(&zone),
    )
}

fn stale_outcome(
    paused_at_ms: Option<i64>,
    accumulated_seconds: i64,
    has_active_task: bool,
    now_ms: i64,
    rollover_hour: u8,
    zone: Tz,
) -> StaleFocusOutcome {
    let Some(paused_at) = paused_at_ms else {
        return StaleFocusOutcome::Keep;
    };
    // Swift's order, which Kotlin's port had reversed: a paused session with
    // nothing on it goes the same day.
    if !has_active_task {
        return StaleFocusOutcome::Discard;
    }
    if logical_day(paused_at, rollover_hour, zone) >= logical_day(now_ms, rollover_hour, zone) {
        return StaleFocusOutcome::Keep;
    }
    if accumulated_seconds >= MINIMUM_CREDITED_SECONDS {
        StaleFocusOutcome::Close
    } else {
        StaleFocusOutcome::Discard
    }
}

// -- points -------------------------------------------------------------------

fn one_decimal_place(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// A block's minutes to one decimal place. `FocusPoints.minutes`.
#[uniffi::export]
pub fn focus_minutes(seconds: i64) -> f64 {
    one_decimal_place(seconds.max(0) as f64 / 60.0)
}

/// A multiplier clamped to 0 to 5, a non-finite one read as solid work.
/// `FocusPoints.clamped`.
#[uniffi::export]
pub fn clamped_focus_multiplier(multiplier: f64) -> f64 {
    if multiplier.is_finite() {
        multiplier.clamp(0.0, 5.0)
    } else {
        1.0
    }
}

/// Minutes times the multiplier, to one decimal place. `FocusPoints.score`.
#[uniffi::export]
pub fn focus_score(seconds: i64, multiplier: f64) -> f64 {
    one_decimal_place(focus_minutes(seconds) * clamped_focus_multiplier(multiplier))
}

// -- completion milestones --------------------------------------------------

/// How hard a completion lands. `CompletionMilestone`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MilestoneOccasion {
    Ordinary,
    ListCleared,
    DailyTicked,
    DailyTally { count: i64 },
    DailyStreak { days: i64 },
}

/// Every Nth completion of the day earns a tally.
pub const TALLY_INTERVAL: i64 = 10;
/// The shortest run of days that earns a streak.
pub const STREAK_MINIMUM: i64 = 3;

/// Which occasion a completion is: clearing the list, then a streak on the
/// day's first completion, then a daily's tick, then a tally.
/// `CompletionMilestonePolicy.milestone`.
#[uniffi::export]
pub fn completion_milestone(
    is_daily: bool,
    remaining_visible_task_count: i64,
    ordinal: i64,
    streak_days: i64,
) -> MilestoneOccasion {
    if !is_daily && remaining_visible_task_count <= 1 {
        return MilestoneOccasion::ListCleared;
    }
    if ordinal == 1 && streak_days >= STREAK_MINIMUM {
        return MilestoneOccasion::DailyStreak { days: streak_days };
    }
    if is_daily {
        return MilestoneOccasion::DailyTicked;
    }
    if ordinal > 0 && ordinal % TALLY_INTERVAL == 0 {
        return MilestoneOccasion::DailyTally { count: ordinal };
    }
    MilestoneOccasion::Ordinary
}

// -- the handle -----------------------------------------------------------------

#[uniffi::export]
impl CoreWorkspace {
    /// Today against the week, read and summed in the core.
    pub fn work_progress(
        &self,
        now_ms: i64,
        zone: String,
        first_weekday: u8,
    ) -> Result<WorkProgressTotals, CoreError> {
        work_progress(&self.read(), now_ms, &zone, first_weekday)
    }

    /// Settles the session left paused when the app last went away: closes
    /// it, crediting its seconds at the moment it was paused, as one "Log
    /// Daily Progress" step, or discards it. `resolveStaleFocusSession`.
    pub fn resolve_stale_focus_session(
        &self,
        now_ms: i64,
        zone: String,
        rollover_hour: u8,
        context: FocusContext,
    ) -> Result<StaleFocusOutcome, CoreError> {
        let mut connection = self.lock();
        resolve_stale_session(&mut connection, now_ms, &zone, rollover_hour, &context)
    }
}

/// `CoreWorkspace::resolve_stale_focus_session` on a connection.
pub fn resolve_stale_session(
    connection: &mut Connection,
    now_ms: i64,
    zone: &str,
    rollover_hour: u8,
    context: &FocusContext,
) -> Result<StaleFocusOutcome, CoreError> {
    let Some(session) = rows::active_session(connection)? else {
        return Ok(StaleFocusOutcome::Keep);
    };
    let accumulated = session.accumulated_seconds.unwrap_or(0).max(0);
    let outcome = stale_outcome(
        session.paused_at_ms,
        accumulated,
        session.active_task_id.is_some(),
        now_ms,
        rollover_hour,
        periodic::zone(zone),
    );
    let ended_at = session.paused_at_ms.unwrap_or(now_ms);
    if outcome == StaleFocusOutcome::Close {
        // The block ran out of day, which says nothing about whether the
        // task is done.
        journal::journalled(connection, "Log Daily Progress", |tx| {
            focus::finish_block(
                tx,
                &session.id,
                accumulated,
                None,
                false,
                session.active_block_id.as_deref(),
                context,
                ended_at,
                zone,
            )
        })?;
    }
    if outcome != StaleFocusOutcome::Keep {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        focus::finish_session(&transaction, &session.id, ended_at)?;
        transaction.commit()?;
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests;
