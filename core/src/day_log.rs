//! The day log: an append-only JSON-lines history of what happened on each
//! day, and the projections the Daily view, the daily note and the CLI's
//! `daily_log_fetch` draw from it.
//!
//! The file is `daylog.jsonl` beside the dailies, one event per line. It is
//! append-only, so undoing a completion appends a compensating `reopened`
//! rather than deleting anything, and a torn write costs one line rather than
//! the history. Replaces `DayLogFileStore`, `DayLogAggregator`, `DayBoundary`
//! and `DailyNoteMarkdown.section` in Swift's TaktCore and the CLI's second
//! reading of the same file in `cli/src/local.rs`; where those two disagreed,
//! this follows Swift, which wrote the file first.
//!
//! Whole files cross the FFI, not events: `CoreDayLog` holds the parsed log
//! on the Rust side and answers each projection in one call, because a
//! year's history crossing one record at a time would cost more than the
//! projection itself (`docs/rust-core-migration.md`, "FFI cost on hot
//! reads"). The free functions taking `events` exist for callers that only
//! have an array, which are tests and one-off renders.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Datelike, Days, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use serde_json::Value;

use crate::CoreError;
use crate::periodic::resolve;

/// The rollover hour a day starts at when none is configured: late enough
/// that a session finishing after midnight still lands on the day it belonged
/// to, early enough that it never swallows a real morning.
pub const DEFAULT_ROLLOVER_HOUR: i32 = 4;

/// The kinds of thing the log records, by the raw values the file stores.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DayLogRecordKind {
    Completed,
    Reopened,
    /// "Won't do": recorded, never counted as a completion.
    Invalidated,
    FocusSessionEnded,
    /// A due date pushed on purpose; kept out of the unfinished list.
    Deferred,
    /// The tasks due or starting on the day, captured once at rollover.
    PlanSnapshot,
    /// A daily ticked off; nets only within its own day.
    DailyCompleted,
    DailyUncompleted,
}

impl DayLogRecordKind {
    pub fn raw(self) -> &'static str {
        match self {
            DayLogRecordKind::Completed => "completed",
            DayLogRecordKind::Reopened => "reopened",
            DayLogRecordKind::Invalidated => "invalidated",
            DayLogRecordKind::FocusSessionEnded => "focusSessionEnded",
            DayLogRecordKind::Deferred => "deferred",
            DayLogRecordKind::PlanSnapshot => "planSnapshot",
            DayLogRecordKind::DailyCompleted => "dailyCompleted",
            DayLogRecordKind::DailyUncompleted => "dailyUncompleted",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Some(match raw {
            "completed" => DayLogRecordKind::Completed,
            "reopened" => DayLogRecordKind::Reopened,
            "invalidated" => DayLogRecordKind::Invalidated,
            "focusSessionEnded" => DayLogRecordKind::FocusSessionEnded,
            "deferred" => DayLogRecordKind::Deferred,
            "planSnapshot" => DayLogRecordKind::PlanSnapshot,
            "dailyCompleted" => DayLogRecordKind::DailyCompleted,
            "dailyUncompleted" => DayLogRecordKind::DailyUncompleted,
            _ => return None,
        })
    }
}

/// One line of the log. `title` is denormalised on purpose: a day has to
/// still read correctly after its task is renamed or deleted. `task_id` is 0
/// for the dailies and the plan snapshot, which are not about one task.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct DayLogRecord {
    pub kind: DayLogRecordKind,
    /// Milliseconds since 1970. The file holds whole seconds.
    pub at_ms: i64,
    pub task_id: i64,
    pub title: String,
    /// `FocusSessionEnded` only.
    pub duration_seconds: Option<i64>,
    /// `PlanSnapshot` only.
    pub planned_task_ids: Option<Vec<i64>>,
    /// `DailyCompleted` and `DailyUncompleted` only.
    pub daily_id: Option<String>,
}

/// Where logical days begin: at `rollover_hour` in `zone`, not at midnight,
/// so work finished at 01:30 belongs to the day that began the previous
/// morning. `first_weekday` is Foundation's numbering (1 = Sunday) and only
/// decides where the weekly chart's weeks start.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct DayLogBoundary {
    pub rollover_hour: i32,
    pub zone: String,
    pub first_weekday: u8,
}

/// One bar of the chart: the instant its logical day (or week) began, that
/// day's key, and the dailies ticked in it.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct DayLogBucket {
    pub day_ms: i64,
    pub key: String,
    pub completed: i64,
}

/// Everything the Daily view and the note need about one logical day.
/// `unfinished_task_ids` names the fact, not the judgement: the renderer says
/// "left" for today and "slipped" for a day already closed.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct DayLogDay {
    pub key: String,
    pub day_ms: i64,
    pub completed: Vec<DayLogRecord>,
    pub planned_task_ids: Vec<i64>,
    pub unfinished_task_ids: Vec<i64>,
    pub deferred_task_ids: Vec<i64>,
    pub invalidated_task_ids: Vec<i64>,
    pub focus_seconds: i64,
    /// In the order they were first ticked.
    pub completed_daily_ids: Vec<String>,
}

/// A daily as the note renders it: expected on the day, ticked or not.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct DayLogDaily {
    pub id: String,
    pub title: String,
}

// -- the file ----------------------------------------------------------------

/// Every event in `bytes`, in file order. Split on `\n` as bytes and decoded
/// a line at a time, so a torn write or a line that is not UTF-8 costs that
/// line and nothing else. `DayLogFileStore.loadAll`.
pub fn parse_lines(bytes: &[u8]) -> Vec<DayLogRecord> {
    bytes
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .filter_map(parse_line)
        .collect()
}

/// One line as Swift's `JSONDecoder` reads a `DayLogEvent`: an unknown kind,
/// a missing or mistyped field, or a timestamp `ISO8601DateFormatter`
/// refuses (fractional seconds included) drops the line rather than keeping
/// half of it.
fn parse_line(line: &[u8]) -> Option<DayLogRecord> {
    let value: Value = serde_json::from_slice(line).ok()?;
    let object = value.as_object()?;
    let kind = DayLogRecordKind::from_raw(object.get("kind")?.as_str()?)?;
    let at_ms = parse_timestamp(object.get("at")?.as_str()?)?;
    let task_id = integer(object.get("taskId")?)?;
    let title = object.get("title")?.as_str()?.to_string();
    let duration_seconds = match object.get("durationSeconds") {
        None | Some(Value::Null) => None,
        Some(raw) => Some(integer(raw)?),
    };
    let planned_task_ids = match object.get("plannedTaskIds") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) => Some(items.iter().map(integer).collect::<Option<Vec<_>>>()?),
        Some(_) => return None,
    };
    let daily_id = match object.get("dailyId") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(text.clone()),
        Some(_) => return None,
    };
    Some(DayLogRecord {
        kind,
        at_ms,
        task_id,
        title,
        duration_seconds,
        planned_task_ids,
        daily_id,
    })
}

/// A JSON number as Swift decodes an `Int`: whole values only, `1.0` and
/// `1e2` included, nothing outside 64 bits.
fn integer(value: &Value) -> Option<i64> {
    if let Some(whole) = value.as_i64() {
        return Some(whole);
    }
    if value.is_u64() {
        return None;
    }
    let float = value.as_f64()?;
    (float.fract() == 0.0 && float >= -(2f64.powi(63)) && float < 2f64.powi(63))
        .then_some(float as i64)
}

/// `yyyy-MM-ddTHH:mm:ss` with `Z` or an offset (`+01:00` or `+0100`), which
/// is what `JSONDecoder`'s `.iso8601` strategy accepts. Fractional seconds
/// are refused, as they are there.
pub fn parse_timestamp(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<u32> {
        let digits = text.get(range)?;
        digits
            .bytes()
            .all(|byte| byte.is_ascii_digit())
            .then(|| digits.parse().ok())?
    };
    let date = NaiveDate::from_ymd_opt(number(0..4)? as i32, number(5..7)?, number(8..10)?)?;
    let time = date.and_hms_opt(number(11..13)?, number(14..16)?, number(17..19)?)?;
    let offset_seconds = match &text[19..] {
        "Z" => 0,
        zone => {
            let sign = match zone.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let digits = zone[1..].replacen(':', "", 1);
            if digits.len() != 4 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            let hours: i32 = digits[..2].parse().ok()?;
            let minutes: i32 = digits[2..].parse().ok()?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            sign * (hours * 3600 + minutes * 60)
        }
    };
    let utc = time - Duration::seconds(i64::from(offset_seconds));
    Some(utc.and_utc().timestamp_millis())
}

/// An instant as the file holds it: UTC, whole seconds, `Z`. Rounded down,
/// as `JSONEncoder`'s `.iso8601` strategy does.
pub fn format_timestamp(at_ms: i64) -> String {
    DateTime::from_timestamp(at_ms.div_euclid(1000), 0)
        .unwrap_or_default()
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

/// One event as a line of the file, without its newline: keys sorted, absent
/// fields left out and `/` escaped, byte for byte what `DayLogFileStore`
/// wrote with `JSONEncoder` and `.sortedKeys`.
pub fn event_line(event: &DayLogRecord) -> String {
    let mut fields: Vec<(&str, Value)> = vec![("at", Value::from(format_timestamp(event.at_ms)))];
    if let Some(daily_id) = &event.daily_id {
        fields.push(("dailyId", Value::from(daily_id.clone())));
    }
    if let Some(seconds) = event.duration_seconds {
        fields.push(("durationSeconds", Value::from(seconds)));
    }
    fields.push(("kind", Value::from(event.kind.raw())));
    if let Some(planned) = &event.planned_task_ids {
        fields.push(("plannedTaskIds", Value::from(planned.clone())));
    }
    fields.push(("taskId", Value::from(event.task_id)));
    fields.push(("title", Value::from(event.title.clone())));
    let body: Vec<String> = fields
        .into_iter()
        .map(|(key, value)| format!("\"{key}\":{value}"))
        .collect();
    format!("{{{}}}", body.join(",")).replace('/', "\\/")
}

/// Every event in the file at `path`; a missing or unreadable file is an
/// empty log, which is the state on first launch.
pub fn load(path: &Path) -> Vec<DayLogRecord> {
    std::fs::read(path)
        .map(|bytes| parse_lines(&bytes))
        .unwrap_or_default()
}

/// Appends one event as a single write of its line and newline, under the
/// `flock` on `<path>.lock` that the app, the CLI and the MCP server all
/// take. If the file does not end in a newline, an earlier writer died
/// mid-line, and one is written first so this event is not glued onto the
/// fragment and dropped with it.
pub fn append(path: &Path, event: &DayLogRecord) -> Result<(), CoreError> {
    let failed = |error: std::io::Error| CoreError::File {
        detail: format!("Could not write to the daily log: {error}"),
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(failed)?;
    }
    let mut bytes = event_line(event).into_bytes();
    bytes.push(b'\n');
    with_exclusive_lock(path, || {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .open(path)?;
        let length = file.metadata()?.len();
        if length > 0 {
            let mut last = [0_u8; 1];
            file.seek(SeekFrom::Start(length - 1))?;
            file.read_exact(&mut last)?;
            if last[0] != b'\n' {
                bytes.insert(0, b'\n');
            }
        }
        file.write_all(&bytes)
    })
    .map_err(failed)
}

/// Runs `body` holding `flock(LOCK_EX)` on a sibling `.lock` file, the
/// protocol of Swift's `FileLock` and the CLI's `lock.rs`.
#[cfg(unix)]
fn with_exclusive_lock<T>(
    path: &Path,
    body: impl FnOnce() -> std::io::Result<T>,
) -> std::io::Result<T> {
    use std::os::unix::io::AsRawFd;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    const LOCK_EX: i32 = 2;
    const LOCK_UN: i32 = 8;

    let mut name = path.as_os_str().to_os_string();
    name.push(".lock");
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(PathBuf::from(name))?;
    let descriptor = lock.as_raw_fd();
    // SAFETY: `flock` on a descriptor this function owns for its whole span.
    if unsafe { flock(descriptor, LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let result = body();
    // SAFETY: as above; closing the file would release it anyway.
    unsafe { flock(descriptor, LOCK_UN) };
    result
}

#[cfg(not(unix))]
fn with_exclusive_lock<T>(
    _path: &Path,
    body: impl FnOnce() -> std::io::Result<T>,
) -> std::io::Result<T> {
    body()
}

// -- logical days ------------------------------------------------------------

/// `DayLogBoundary` resolved for use: the hour clamped and the zone parsed.
#[derive(Debug, Clone, Copy)]
pub struct Boundary {
    pub hour: u32,
    pub zone: Tz,
    first_weekday: u32,
}

impl Boundary {
    pub fn new(boundary: &DayLogBoundary) -> Self {
        Boundary {
            hour: boundary.rollover_hour.clamp(0, 23) as u32,
            zone: crate::periodic::zone(&boundary.zone),
            first_weekday: u32::from(boundary.first_weekday.clamp(1, 7)),
        }
    }

    /// `date` at the rollover hour, a skipped hour moving later by the gap
    /// and a repeated one taking its first occurrence, as Foundation does.
    fn at_rollover(&self, date: NaiveDate) -> DateTime<Utc> {
        resolve(self.zone, anchor_time(date, self.hour))
    }

    /// The instant the logical day containing `at` began. Idempotent, which
    /// it has to be: these instants are passed back in as day identifiers.
    pub fn logical_day(&self, at: DateTime<Utc>) -> DateTime<Utc> {
        let shifted = at - Duration::hours(i64::from(self.hour));
        self.at_rollover(shifted.with_timezone(&self.zone).date_naive())
    }

    fn local_date(&self, at: DateTime<Utc>) -> NaiveDate {
        self.logical_day(at).with_timezone(&self.zone).date_naive()
    }

    /// `yyyy-MM-dd` for the logical day containing `at`.
    pub fn day_key(&self, at: DateTime<Utc>) -> String {
        let date = self.local_date(at);
        format!("{:04}-{:02}-{:02}", date.year(), date.month(), date.day())
    }

    /// Wall-clock days from the logical day containing `from`, as
    /// `Calendar.date(byAdding: .day)` steps.
    pub fn day_offset(&self, offset: i64, from: DateTime<Utc>) -> DateTime<Utc> {
        let anchor = self
            .logical_day(from)
            .with_timezone(&self.zone)
            .naive_local();
        resolve(self.zone, shift_days(anchor, offset))
    }

    /// The `count` logical days ending on, and including, the one containing
    /// `at`, oldest first.
    pub fn days_ending_on(&self, at: DateTime<Utc>, count: i64) -> Vec<DateTime<Utc>> {
        (0..count.max(0))
            .rev()
            .map(|back| self.day_offset(-back, at))
            .collect()
    }

    /// The start of the calendar week holding the logical day for `at`,
    /// anchored at the rollover hour like the days are.
    pub fn week_start(&self, at: DateTime<Utc>) -> DateTime<Utc> {
        let date = self.local_date(at);
        let weekday = date.weekday().num_days_from_sunday() + 1;
        let back = (weekday + 7 - self.first_weekday) % 7;
        self.at_rollover(date - Days::new(u64::from(back)))
    }

    /// The `count` week starts ending on the week holding `at`, oldest first.
    pub fn weeks_ending_on(&self, at: DateTime<Utc>, count: i64) -> Vec<DateTime<Utc>> {
        let anchor = self.week_start(at).with_timezone(&self.zone).naive_local();
        (0..count.max(0))
            .rev()
            .map(|back| resolve(self.zone, shift_days(anchor, -7 * back)))
            .collect()
    }
}

fn anchor_time(date: NaiveDate, hour: u32) -> NaiveDateTime {
    date.and_hms_opt(hour, 0, 0).unwrap_or_default()
}

fn shift_days(from: NaiveDateTime, days: i64) -> NaiveDateTime {
    let magnitude = Days::new(days.unsigned_abs());
    let shifted = if days >= 0 {
        from.checked_add_days(magnitude)
    } else {
        from.checked_sub_days(magnitude)
    };
    shifted.unwrap_or(from)
}

pub(crate) fn instant(ms: i64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt(ms).single().unwrap_or_default()
}

// -- projections -------------------------------------------------------------

/// The completions that survive their compensating reopens. A reopen cancels
/// the most recent surviving completion of the same task, whichever day it
/// was on, so undoing yesterday's tick empties yesterday.
pub fn net_completions(events: &[DayLogRecord]) -> Vec<&DayLogRecord> {
    let mut open: HashMap<i64, Vec<usize>> = HashMap::new();
    let mut cancelled: HashSet<usize> = HashSet::new();
    for (index, event) in events.iter().enumerate() {
        match event.kind {
            DayLogRecordKind::Completed => open.entry(event.task_id).or_default().push(index),
            DayLogRecordKind::Reopened => {
                if let Some(latest) = open.get_mut(&event.task_id).and_then(Vec::pop) {
                    cancelled.insert(latest);
                }
            }
            _ => {}
        }
    }
    events
        .iter()
        .enumerate()
        .filter(|(index, event)| {
            event.kind == DayLogRecordKind::Completed && !cancelled.contains(index)
        })
        .map(|(_, event)| event)
        .collect()
}

/// The dailies ticked on the logical day containing `on`, netted within that
/// day only: a daily is asked afresh each morning, so an un-tick never
/// reaches back to blank yesterday.
pub fn completed_daily_ids(
    events: &[DayLogRecord],
    boundary: &Boundary,
    on: DateTime<Utc>,
) -> Vec<String> {
    let key = boundary.day_key(on);
    let mut ticked: Vec<String> = Vec::new();
    for event in events {
        let Some(daily_id) = &event.daily_id else {
            continue;
        };
        if !matches!(
            event.kind,
            DayLogRecordKind::DailyCompleted | DayLogRecordKind::DailyUncompleted
        ) || boundary.day_key(instant(event.at_ms)) != key
        {
            continue;
        }
        tick(&mut ticked, event.kind, daily_id);
    }
    ticked
}

fn tick(ticked: &mut Vec<String>, kind: DayLogRecordKind, daily_id: &str) {
    match kind {
        DayLogRecordKind::DailyCompleted if !ticked.iter().any(|id| id == daily_id) => {
            ticked.push(daily_id.to_string());
        }
        DayLogRecordKind::DailyUncompleted => ticked.retain(|id| id != daily_id),
        _ => {}
    }
}

/// Daily ticks per logical day (keyed by the day's start), netted per day.
fn daily_ticks_by_day(events: &[DayLogRecord], boundary: &Boundary) -> HashMap<i64, Vec<String>> {
    let mut by_day: HashMap<i64, Vec<String>> = HashMap::new();
    for event in events {
        let Some(daily_id) = &event.daily_id else {
            continue;
        };
        if !matches!(
            event.kind,
            DayLogRecordKind::DailyCompleted | DayLogRecordKind::DailyUncompleted
        ) {
            continue;
        }
        let day = boundary
            .logical_day(instant(event.at_ms))
            .timestamp_millis();
        tick(by_day.entry(day).or_default(), event.kind, daily_id);
    }
    by_day
}

/// Daily ticks per logical day across the window, zero-filled: a day with
/// nothing ticked keeps its slot on the axis. Dailies only, so the line is
/// the shape of the routine rather than of whatever was on the list.
pub fn daily_buckets(
    events: &[DayLogRecord],
    boundary: &Boundary,
    ending_on: DateTime<Utc>,
    days: i64,
) -> Vec<DayLogBucket> {
    let by_day = daily_ticks_by_day(events, boundary);
    boundary
        .days_ending_on(ending_on, days)
        .into_iter()
        .map(|day| {
            let day_ms = day.timestamp_millis();
            DayLogBucket {
                day_ms,
                key: boundary.day_key(day),
                completed: by_day.get(&day_ms).map_or(0, |ids| ids.len() as i64),
            }
        })
        .collect()
}

/// Daily ticks per calendar week, zero-filled, for the year range. Netted
/// per day first, then rolled up, so Monday's un-tick cannot cancel
/// Tuesday's tick.
pub fn weekly_buckets(
    events: &[DayLogRecord],
    boundary: &Boundary,
    ending_on: DateTime<Utc>,
    weeks: i64,
) -> Vec<DayLogBucket> {
    let mut by_week: HashMap<i64, i64> = HashMap::new();
    for (day, ids) in daily_ticks_by_day(events, boundary) {
        let week = boundary.week_start(instant(day)).timestamp_millis();
        *by_week.entry(week).or_default() += ids.len() as i64;
    }
    boundary
        .weeks_ending_on(ending_on, weeks)
        .into_iter()
        .map(|week| {
            let day_ms = week.timestamp_millis();
            DayLogBucket {
                day_ms,
                key: boundary.day_key(week),
                completed: by_week.get(&day_ms).copied().unwrap_or(0),
            }
        })
        .collect()
}

/// One logical day. Netting runs over the whole log, because the reopen that
/// cancels one of this day's completions may land on a later one, and a
/// completion from any day settles a planned task.
pub fn summary(events: &[DayLogRecord], boundary: &Boundary, on: DateTime<Utc>) -> DayLogDay {
    let key = boundary.day_key(on);
    let on_this_day: Vec<&DayLogRecord> = events
        .iter()
        .filter(|event| boundary.day_key(instant(event.at_ms)) == key)
        .collect();
    let surviving = net_completions(events);
    let completed: Vec<DayLogRecord> = surviving
        .iter()
        .filter(|event| boundary.day_key(instant(event.at_ms)) == key)
        .map(|event| (*event).clone())
        .collect();

    let planned = on_this_day
        .iter()
        .rev()
        .find(|event| event.kind == DayLogRecordKind::PlanSnapshot)
        .and_then(|event| event.planned_task_ids.clone())
        .unwrap_or_default();
    let of_kind = |kind: DayLogRecordKind| {
        let mut ordered: Vec<i64> = Vec::new();
        for event in on_this_day.iter().filter(|event| event.kind == kind) {
            if !ordered.contains(&event.task_id) {
                ordered.push(event.task_id);
            }
        }
        ordered
    };
    let deferred = of_kind(DayLogRecordKind::Deferred);
    let invalidated = of_kind(DayLogRecordKind::Invalidated);

    let closed: HashSet<i64> = surviving
        .iter()
        .map(|event| event.task_id)
        .chain(deferred.iter().copied())
        .chain(invalidated.iter().copied())
        .collect();
    let unfinished = planned
        .iter()
        .copied()
        .filter(|id| !closed.contains(id))
        .collect();
    let focus_seconds = on_this_day
        .iter()
        .filter(|event| event.kind == DayLogRecordKind::FocusSessionEnded)
        .filter_map(|event| event.duration_seconds)
        .sum();

    DayLogDay {
        day_ms: boundary.logical_day(on).timestamp_millis(),
        completed_daily_ids: completed_daily_ids(events, boundary, on),
        key,
        completed,
        planned_task_ids: planned,
        unfinished_task_ids: unfinished,
        deferred_task_ids: deferred,
        invalidated_task_ids: invalidated,
        focus_seconds,
    }
}

/// How many logical days have at least one event.
pub fn recorded_day_count(events: &[DayLogRecord], boundary: &Boundary) -> u32 {
    events
        .iter()
        .map(|event| boundary.day_key(instant(event.at_ms)))
        .collect::<HashSet<_>>()
        .len() as u32
}

/// The earliest logical day in the log: "collecting since".
pub fn first_recorded_day(events: &[DayLogRecord], boundary: &Boundary) -> Option<DateTime<Utc>> {
    let earliest = events.iter().map(|event| event.at_ms).min()?;
    Some(boundary.logical_day(instant(earliest)))
}

/// Consecutive logical days before `now`'s on which a task was completed (and
/// not reopened) or a daily ticked. Today is left out so the two completion
/// paths agree; callers add the day they are earning. Bounded by the log's
/// own history so it always ends.
pub fn prior_completion_streak(
    events: &[DayLogRecord],
    boundary: &Boundary,
    now: DateTime<Utc>,
) -> u32 {
    if events.is_empty() {
        return 0;
    }
    let task_days: HashSet<String> = net_completions(events)
        .iter()
        .map(|event| boundary.day_key(instant(event.at_ms)))
        .collect();
    let daily_days: HashSet<String> = daily_ticks_by_day(events, boundary)
        .into_iter()
        .filter(|(_, ids)| !ids.is_empty())
        .map(|(day, _)| boundary.day_key(instant(day)))
        .collect();
    let horizon = recorded_day_count(events, boundary).max(1) + 1;
    let mut streak = 0;
    for offset in 1..=i64::from(horizon) {
        let key = boundary.day_key(boundary.day_offset(-offset, now));
        if !task_days.contains(&key) && !daily_days.contains(&key) {
            break;
        }
        streak += 1;
    }
    streak
}

// -- the note ----------------------------------------------------------------

/// The comment pair `ManagedMarkdownBlock.takt` splices by. They keep the
/// old name because they are already in people's notes.
pub const BEGIN_MARKER: &str = "<!-- priority:begin -->";
pub const END_MARKER: &str = "<!-- priority:end -->";

/// `"—"` for nothing, `"45m"` under an hour, `"1h 40m"` above it; never a
/// real session rounded down to `"0m"`.
pub fn focus_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return "—".into();
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{}m", minutes.max(1));
    }
    match (minutes / 60, minutes % 60) {
        (hours, 0) => format!("{hours}h"),
        (hours, rest) => format!("{hours}h {rest}m"),
    }
}

/// The managed block for a day, markers included, as spliced into an
/// Obsidian daily note or an AFFiNE doc. `titles` needs only the
/// unfinished and deferred tasks; `dailies` are those expected on the day,
/// in display order, since the log records only what was ticked.
pub fn section(
    day: &DayLogDay,
    titles: &HashMap<i64, String>,
    dailies: &[DayLogDaily],
    heading: &str,
) -> String {
    let mut lines: Vec<String> = vec![BEGIN_MARKER.into(), heading.into(), String::new()];
    let ticked = |id: &str| day.completed_daily_ids.iter().any(|done| done == id);

    let mut headline = vec![format!("**{} done**", day.completed.len())];
    if !dailies.is_empty() {
        let done = dailies.iter().filter(|daily| ticked(&daily.id)).count();
        headline.push(format!("**{done}/{} dailies**", dailies.len()));
    }
    if day.focus_seconds > 0 {
        headline.push(format!("**{} focused**", focus_duration(day.focus_seconds)));
    }
    if !day.planned_task_ids.is_empty() {
        headline.push(format!(
            "{} of {} planned left",
            day.unfinished_task_ids.len(),
            day.planned_task_ids.len()
        ));
    }
    lines.push(headline.join(" · "));
    lines.push(String::new());

    if !dailies.is_empty() {
        lines.push("_Dailies:_".into());
        for daily in dailies {
            let mark = if ticked(&daily.id) { "x" } else { " " };
            lines.push(format!("- [{mark}] {}", escaped_title(&daily.title)));
        }
        lines.push(String::new());
    }

    if day.completed.is_empty() {
        // A day where the dailies got done is not a blank day.
        if dailies.is_empty() {
            lines.push("_Nothing recorded._".into());
        }
    } else {
        for event in &day.completed {
            lines.push(format!("- [x] {}", escaped_title(&event.title)));
        }
    }

    let named =
        |ids: &[i64]| -> Vec<&String> { ids.iter().filter_map(|id| titles.get(id)).collect() };
    let unfinished = named(&day.unfinished_task_ids);
    if !unfinished.is_empty() {
        lines.extend([String::new(), "_Unfinished:_".into()]);
        lines.extend(
            unfinished
                .iter()
                .map(|title| format!("- [ ] {}", escaped_title(title))),
        );
    }
    let deferred = named(&day.deferred_task_ids);
    if !deferred.is_empty() {
        lines.extend([String::new(), "_Deferred:_".into()]);
        lines.extend(
            deferred
                .iter()
                .map(|title| format!("- {}", escaped_title(title))),
        );
    }

    lines.push(END_MARKER.into());
    lines.join("\n")
}

/// A title as one markdown list item: line breaks collapsed, and leading
/// list or heading punctuation escaped so it cannot restructure the note.
fn escaped_title(raw: &str) -> String {
    let collapsed = raw
        .replace("\r\n", " ")
        .replace(['\n', '\r'], " ")
        .trim()
        .to_string();
    if collapsed.is_empty() {
        return "(untitled)".into();
    }
    if collapsed.starts_with(['-', '*', '+', '#', '>']) {
        return format!("\\{collapsed}");
    }
    collapsed
}

// -- the FFI -----------------------------------------------------------------

/// The log held in memory, read from and appended to its file here, so a
/// client asks for a projection in one call instead of passing its whole
/// history across the boundary for each one.
#[derive(uniffi::Object)]
pub struct CoreDayLog {
    path: PathBuf,
    events: Mutex<Vec<DayLogRecord>>,
}

impl CoreDayLog {
    fn with<T>(&self, body: impl FnOnce(&[DayLogRecord]) -> T) -> T {
        let events = self
            .events
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        body(&events)
    }
}

#[uniffi::export]
impl CoreDayLog {
    /// The log at `path`, read now; a missing file is an empty log.
    #[uniffi::constructor]
    pub fn open(path: String) -> Arc<Self> {
        let path = PathBuf::from(path);
        let events = load(&path);
        Arc::new(CoreDayLog {
            path,
            events: Mutex::new(events),
        })
    }

    /// Rereads the file, returning whether anything differs from what was
    /// held: another process (the MCP server) may have appended.
    pub fn reload(&self) -> bool {
        let fresh = load(&self.path);
        let mut events = self
            .events
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if *events == fresh {
            return false;
        }
        *events = fresh;
        true
    }

    /// Records `event` in memory and appends it to the file. A failed write
    /// still leaves it in memory, so the session stays right and only
    /// durability is lost; the error says so.
    pub fn record(&self, event: DayLogRecord) -> Result<(), CoreError> {
        self.events
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .push(event.clone());
        append(&self.path, &event)
    }

    pub fn events(&self) -> Vec<DayLogRecord> {
        self.with(<[DayLogRecord]>::to_vec)
    }

    pub fn event_count(&self) -> u64 {
        self.with(|events| events.len() as u64)
    }

    pub fn summary(&self, boundary: DayLogBoundary, on_ms: i64) -> DayLogDay {
        self.with(|events| summary(events, &Boundary::new(&boundary), instant(on_ms)))
    }

    pub fn completed_daily_ids(&self, boundary: DayLogBoundary, on_ms: i64) -> Vec<String> {
        self.with(|events| completed_daily_ids(events, &Boundary::new(&boundary), instant(on_ms)))
    }

    pub fn daily_buckets(
        &self,
        boundary: DayLogBoundary,
        ending_on_ms: i64,
        days: i64,
    ) -> Vec<DayLogBucket> {
        self.with(|events| {
            daily_buckets(
                events,
                &Boundary::new(&boundary),
                instant(ending_on_ms),
                days,
            )
        })
    }

    pub fn weekly_buckets(
        &self,
        boundary: DayLogBoundary,
        ending_on_ms: i64,
        weeks: i64,
    ) -> Vec<DayLogBucket> {
        self.with(|events| {
            weekly_buckets(
                events,
                &Boundary::new(&boundary),
                instant(ending_on_ms),
                weeks,
            )
        })
    }

    pub fn recorded_day_count(&self, boundary: DayLogBoundary) -> u32 {
        self.with(|events| recorded_day_count(events, &Boundary::new(&boundary)))
    }

    pub fn first_recorded_day(&self, boundary: DayLogBoundary) -> Option<i64> {
        self.with(|events| {
            first_recorded_day(events, &Boundary::new(&boundary)).map(|day| day.timestamp_millis())
        })
    }

    pub fn prior_completion_streak(&self, boundary: DayLogBoundary, now_ms: i64) -> u32 {
        self.with(|events| {
            prior_completion_streak(events, &Boundary::new(&boundary), instant(now_ms))
        })
    }
}

/// Every event in the file at `path`.
#[uniffi::export]
pub fn day_log_load(path: String) -> Vec<DayLogRecord> {
    load(Path::new(&path))
}

/// Appends `event` to the file at `path`.
#[uniffi::export]
pub fn day_log_append(path: String, event: DayLogRecord) -> Result<(), CoreError> {
    append(Path::new(&path), &event)
}

#[uniffi::export]
pub fn day_log_net_completions(events: Vec<DayLogRecord>) -> Vec<DayLogRecord> {
    net_completions(&events).into_iter().cloned().collect()
}

#[uniffi::export]
pub fn day_log_summary(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
    on_ms: i64,
) -> DayLogDay {
    summary(&events, &Boundary::new(&boundary), instant(on_ms))
}

#[uniffi::export]
pub fn day_log_completed_daily_ids(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
    on_ms: i64,
) -> Vec<String> {
    completed_daily_ids(&events, &Boundary::new(&boundary), instant(on_ms))
}

#[uniffi::export]
pub fn day_log_daily_buckets(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
    ending_on_ms: i64,
    days: i64,
) -> Vec<DayLogBucket> {
    daily_buckets(
        &events,
        &Boundary::new(&boundary),
        instant(ending_on_ms),
        days,
    )
}

#[uniffi::export]
pub fn day_log_weekly_buckets(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
    ending_on_ms: i64,
    weeks: i64,
) -> Vec<DayLogBucket> {
    weekly_buckets(
        &events,
        &Boundary::new(&boundary),
        instant(ending_on_ms),
        weeks,
    )
}

#[uniffi::export]
pub fn day_log_recorded_day_count(events: Vec<DayLogRecord>, boundary: DayLogBoundary) -> u32 {
    recorded_day_count(&events, &Boundary::new(&boundary))
}

#[uniffi::export]
pub fn day_log_first_recorded_day(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
) -> Option<i64> {
    first_recorded_day(&events, &Boundary::new(&boundary)).map(|day| day.timestamp_millis())
}

#[uniffi::export]
pub fn day_log_prior_completion_streak(
    events: Vec<DayLogRecord>,
    boundary: DayLogBoundary,
    now_ms: i64,
) -> u32 {
    prior_completion_streak(&events, &Boundary::new(&boundary), instant(now_ms))
}

/// The managed note block for `day`; see `section`.
#[uniffi::export]
pub fn day_log_section(
    day: DayLogDay,
    titles: HashMap<i64, String>,
    dailies: Vec<DayLogDaily>,
    heading: String,
) -> String {
    section(&day, &titles, &dailies, &heading)
}

#[uniffi::export]
pub fn day_log_focus_duration(seconds: i64) -> String {
    focus_duration(seconds)
}

/// The instant the logical day containing `at_ms` began.
#[uniffi::export]
pub fn day_boundary_logical_day(boundary: DayLogBoundary, at_ms: i64) -> i64 {
    Boundary::new(&boundary)
        .logical_day(instant(at_ms))
        .timestamp_millis()
}

/// `yyyy-MM-dd` for the logical day containing `at_ms`.
#[uniffi::export]
pub fn day_boundary_day_key(boundary: DayLogBoundary, at_ms: i64) -> String {
    Boundary::new(&boundary).day_key(instant(at_ms))
}

/// The logical day `offset` days from the one containing `from_ms`.
#[uniffi::export]
pub fn day_boundary_day_offset(boundary: DayLogBoundary, offset: i64, from_ms: i64) -> i64 {
    Boundary::new(&boundary)
        .day_offset(offset, instant(from_ms))
        .timestamp_millis()
}

#[uniffi::export]
pub fn day_boundary_days_ending_on(boundary: DayLogBoundary, at_ms: i64, count: i64) -> Vec<i64> {
    Boundary::new(&boundary)
        .days_ending_on(instant(at_ms), count)
        .iter()
        .map(DateTime::timestamp_millis)
        .collect()
}

#[uniffi::export]
pub fn day_boundary_week_start(boundary: DayLogBoundary, at_ms: i64) -> i64 {
    Boundary::new(&boundary)
        .week_start(instant(at_ms))
        .timestamp_millis()
}

#[uniffi::export]
pub fn day_boundary_weeks_ending_on(boundary: DayLogBoundary, at_ms: i64, count: i64) -> Vec<i64> {
    Boundary::new(&boundary)
        .weeks_ending_on(instant(at_ms), count)
        .iter()
        .map(DateTime::timestamp_millis)
        .collect()
}

#[cfg(test)]
mod tests;
