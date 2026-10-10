//! What a typed task says about itself beyond its title, and the other short
//! date words the clients read: `TaskCaptureSyntax.swift` and Kotlin's
//! `TaskCaptureSyntax.kt`, and Checkvist's free-text due dates
//! (`DueDateParsing`).
//!
//! Typing `Write the release notes 45m #work @fri !1` into an add field files
//! a task called "Write the release notes" with a 45-minute estimate, the tag
//! `work`, due on Friday, at priority 1.
//!
//! Only the *trailing* words are read, and only while every one of them is a
//! token. The first word from the end that is not one stops the scan, so a
//! title is never rewritten in the middle: `Read 30 pages` and `Email bob
//! @home` keep every word, and `Buy 2m of cable` keeps its `2m`. The first
//! word is never read as a token: a task with no title at all is not a task.
//!
//! Clients pass "now" as milliseconds and the time zone by name, so a test
//! can fix both; every answer that is a moment comes back as milliseconds.

use std::sync::LazyLock;

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc, Weekday};
use chrono_tz::Tz;
use regex_lite::Regex;

use crate::periodic;

/// The longest estimate a token may set. Anything past a day is a typo or
/// not an estimate: `48h` is more likely a deadline than a sitting.
pub const MAXIMUM_ESTIMATE_SECONDS: i64 = 24 * 60 * 60;

/// What [`capture_parse`] read off a typed title.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct CaptureParts {
    /// The title left once the trailing tokens are read off; the trimmed text
    /// as typed when none were.
    pub title: String,
    pub estimate_seconds: Option<i64>,
    /// The start of the day it is due, in the caller's zone.
    pub due_at_ms: Option<i64>,
    pub tags: Vec<String>,
    /// 1 to 4, the range the workspace stores.
    pub priority: Option<i64>,
    /// Who it waits on, from `wait:Sam`.
    pub waiting_on: Option<String>,
}

impl CaptureParts {
    fn has_details(&self) -> bool {
        self.estimate_seconds.is_some()
            || self.due_at_ms.is_some()
            || !self.tags.is_empty()
            || self.priority.is_some()
            || self.waiting_on.is_some()
    }
}

/// One trailing word the add field understands.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Estimate(i64),
    Due(i64),
    Tag(String),
    Priority(i64),
    Waiting(String),
}

/// Parses `text` as typed into an add field. See the module for the rules.
#[uniffi::export]
pub fn capture_parse(text: String, now_ms: i64, zone: String) -> CaptureParts {
    parse(&text, now_ms, periodic::zone(&zone))
}

pub fn parse(text: &str, now_ms: i64, zone: Tz) -> CaptureParts {
    let trimmed = text.trim();
    let mut words: Vec<&str> = trimmed.split(' ').filter(|w| !w.is_empty()).collect();
    let mut capture = CaptureParts {
        title: trimmed.to_string(),
        ..CaptureParts::default()
    };
    let mut tags: Vec<String> = Vec::new();

    // The first word is always the title's, so the scan cannot leave it empty.
    while words.len() > 1 {
        let Some(token) = token(words[words.len() - 1], now_ms, zone) else {
            break;
        };
        // A second token of a kind already found ends the scan: the last one
        // typed wins, and the earlier one stays in the title where it can be
        // seen, rather than being silently thrown away.
        match token {
            Token::Estimate(seconds) => {
                if capture.estimate_seconds.is_some() {
                    break;
                }
                capture.estimate_seconds = Some(seconds);
            }
            Token::Due(at) => {
                if capture.due_at_ms.is_some() {
                    break;
                }
                capture.due_at_ms = Some(at);
            }
            Token::Priority(value) => {
                if capture.priority.is_some() {
                    break;
                }
                capture.priority = Some(value);
            }
            Token::Waiting(name) => {
                if capture.waiting_on.is_some() {
                    break;
                }
                capture.waiting_on = Some(name);
            }
            Token::Tag(tag) => {
                // A repeated tag is harmless, so it is folded rather than
                // ending the scan, keeping the spelling and place of the first
                // one typed.
                let folded = tag.to_lowercase();
                tags.retain(|t| t.to_lowercase() != folded);
                tags.insert(0, tag);
            }
        }
        words.pop();
    }

    if !capture.has_details() && tags.is_empty() {
        return capture;
    }
    capture.title = words.join(" ");
    capture.tags = tags;
    capture
}

/// Short labels for what was found, in the order the field shows them:
/// `45m`, `Fri 3 Oct`, `#work`, `!1`, `waiting on Sam`.
#[uniffi::export]
pub fn capture_detail_labels(capture: CaptureParts, now_ms: i64, zone: String) -> Vec<String> {
    detail_labels(&capture, now_ms, periodic::zone(&zone))
}

pub fn detail_labels(capture: &CaptureParts, now_ms: i64, zone: Tz) -> Vec<String> {
    let mut labels = Vec::new();
    if let Some(seconds) = capture.estimate_seconds {
        labels.push(duration_label(seconds));
    }
    if let Some(due) = capture.due_at_ms {
        labels.push(due_label(due, now_ms, zone));
    }
    labels.extend(capture.tags.iter().map(|tag| format!("#{tag}")));
    if let Some(priority) = capture.priority {
        labels.push(format!("!{priority}"));
    }
    if let Some(name) = &capture.waiting_on {
        labels.push(format!("waiting on {name}"));
    }
    labels
}

/// `45m`, `2h`, `1h 30m`.
pub fn duration_label(seconds: i64) -> String {
    let minutes = seconds.max(0) / 60;
    if minutes < 60 {
        return format!("{minutes}m");
    }
    let remainder = minutes % 60;
    if remainder == 0 {
        format!("{}h", minutes / 60)
    } else {
        format!("{}h {remainder}m", minutes / 60)
    }
}

/// `Today`, `Tomorrow`, `Fri 2 Oct`, or `1 Mar 2027` in another year, as
/// `DateFormatter` writes them in `en_GB`.
fn due_label(due_ms: i64, now_ms: i64, zone: Tz) -> String {
    let day = local(due_ms, zone).date_naive();
    let today = local(now_ms, zone).date_naive();
    if day == today {
        return "Today".into();
    }
    if Some(day) == today.succ_opt() {
        return "Tomorrow".into();
    }
    if day.year() == today.year() {
        day.format("%a %-d %b").to_string()
    } else {
        day.format("%-d %b %Y").to_string()
    }
}

fn local(ms: i64, zone: Tz) -> DateTime<Tz> {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&zone)
}

fn start_of(day: NaiveDate, zone: Tz) -> i64 {
    periodic::resolve(zone, day.and_hms_opt(0, 0, 0).expect("midnight exists")).timestamp_millis()
}

fn token(word: &str, now_ms: i64, zone: Tz) -> Option<Token> {
    let lower = word.to_lowercase();
    if let Some(seconds) = estimate(&lower) {
        return Some(Token::Estimate(seconds));
    }
    // `^` is Checkvist's due marker (`^fri`, `^tomorrow`), so hands used to it
    // type the same thing here.
    if let Some(rest) = lower.strip_prefix('@').or_else(|| lower.strip_prefix('^'))
        && let Some(at) = due(rest, now_ms, zone)
    {
        return Some(Token::Due(at));
    }
    if let Some(tag) = tag(word) {
        return Some(Token::Tag(tag));
    }
    if let Some(value) = priority(&lower) {
        return Some(Token::Priority(value));
    }
    if lower.starts_with("wait:") && word.chars().count() > 5 {
        // `wait:Sam`: the name keeps the case it was typed in.
        return Some(Token::Waiting(word.chars().skip(5).collect()));
    }
    None
}

static ESTIMATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:([0-9]+(?:\.[0-9]+)?)(h|hr|hrs|hour|hours)(?:([0-9]+)(m|min|mins)?)?|([0-9]+)(m|min|mins|minute|minutes))$",
    )
    .expect("estimate pattern")
});

/// `30m`, `90min`, `1h`, `1.5h`, `2hrs`, `1h30m`, `1h30`, each optionally
/// after a `~`. Seconds, or `None` for anything else, for nothing, or for
/// more than a day.
#[uniffi::export]
pub fn capture_estimate(word: String) -> Option<i64> {
    estimate(&word)
}

pub fn estimate(word: &str) -> Option<i64> {
    let body = word.strip_prefix('~').unwrap_or(word);
    let captures = ESTIMATE.captures(body)?;
    let number = |index: usize| {
        captures
            .get(index)
            .and_then(|m| m.as_str().parse::<f64>().ok())
    };
    let minutes = if let Some(hours) = number(1) {
        // `1.5h30` is not something anyone means; a fractional hour stands alone.
        let extra = number(3).unwrap_or(0.0);
        if extra > 0.0 && hours.round() != hours {
            return None;
        }
        if extra >= 60.0 {
            return None;
        }
        hours * 60.0 + extra
    } else {
        number(5)?
    };
    // Half away from zero, as Swift's `rounded()`.
    let seconds = (minutes * 60.0).round();
    if seconds <= 0.0 || seconds > MAXIMUM_ESTIMATE_SECONDS as f64 {
        return None;
    }
    Some(seconds as i64)
}

static RELATIVE_DAYS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([0-9]{1,3})([dw])$").expect("relative pattern"));
static ISO_DAY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$").expect("day pattern"));

/// `today`, `tomorrow`, a weekday (the next one, today included), `3d` or
/// `2w` from today, or a `yyyy-mm-dd` date: the start of that day in `zone`.
#[uniffi::export]
pub fn capture_due(word: String, now_ms: i64, zone: String) -> Option<i64> {
    due(&word, now_ms, periodic::zone(&zone))
}

pub fn due(word: &str, now_ms: i64, zone: Tz) -> Option<i64> {
    due_day(word, now_ms, zone).map(|day| start_of(day, zone))
}

fn due_day(word: &str, now_ms: i64, zone: Tz) -> Option<NaiveDate> {
    let today = local(now_ms, zone).date_naive();
    let days = |count: i64| today.checked_add_signed(Duration::days(count));
    match word {
        "today" | "tod" => return Some(today),
        "tomorrow" | "tmr" | "tom" => return days(1),
        _ => {}
    }
    if let Some(weekday) = weekday(word) {
        let ahead = (i64::from(weekday.num_days_from_sunday())
            - i64::from(today.weekday().num_days_from_sunday())
            + 7)
            % 7;
        return days(ahead);
    }
    if let Some(captures) = RELATIVE_DAYS.captures(word) {
        let count: i64 = captures[1].parse().ok()?;
        if count > 0 {
            return days(if &captures[2] == "w" {
                count * 7
            } else {
                count
            });
        }
    }
    if let Some(captures) = ISO_DAY.captures(word) {
        // Reject a date the calendar would roll over (`2026-02-31`) rather
        // than quietly filing the task in March.
        return NaiveDate::from_ymd_opt(
            captures[1].parse().ok()?,
            captures[2].parse().ok()?,
            captures[3].parse().ok()?,
        );
    }
    None
}

fn weekday(word: &str) -> Option<Weekday> {
    Some(match word {
        "sun" | "sunday" => Weekday::Sun,
        "mon" | "monday" => Weekday::Mon,
        "tue" | "tues" | "tuesday" => Weekday::Tue,
        "wed" | "wednesday" => Weekday::Wed,
        "thu" | "thur" | "thurs" | "thursday" => Weekday::Thu,
        "fri" | "friday" => Weekday::Fri,
        "sat" | "saturday" => Weekday::Sat,
        _ => return None,
    })
}

static TWELVE_HOUR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([0-9]{1,2})(?:[:.]([0-9]{2}))?(am|pm|a|p)$").expect("12-hour pattern")
});
static TWENTY_FOUR_HOUR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([0-9]{1,2})[:.]([0-9]{2})$").expect("24-hour pattern"));

/// `9am`, `9:30pm`, `12am`, `14:00`, `9.30`, `noon`, `midnight`: an hour and
/// minute on the 24-hour clock.
pub fn time_of_day(word: &str) -> Option<(u32, u32)> {
    match word {
        "noon" | "midday" => return Some((12, 0)),
        "midnight" => return Some((0, 0)),
        _ => {}
    }
    if let Some(captures) = TWELVE_HOUR.captures(word) {
        let hour: u32 = captures[1].parse().ok()?;
        if (1..=12).contains(&hour) {
            let minute: u32 = match captures.get(2) {
                Some(m) => m.as_str().parse().ok()?,
                None => 0,
            };
            if minute >= 60 {
                return None;
            }
            let pm = captures[3].starts_with('p');
            return Some((hour % 12 + if pm { 12 } else { 0 }, minute));
        }
    }
    if let Some(captures) = TWENTY_FOUR_HOUR.captures(word) {
        let hour: u32 = captures[1].parse().ok()?;
        let minute: u32 = captures[2].parse().ok()?;
        if hour < 24 && minute < 60 {
            return Some((hour, minute));
        }
    }
    None
}

/// A day and a time of day, as the follow-up field reads them: the add
/// field's date words (`@fri`, `tomorrow`, `3d`, `2026-10-08`, each with or
/// without the `@`), a time (`9am`, `9:30pm`, `14:00`, `noon`), or both in
/// either order, with an optional `at` between.
///
/// A day with no time is at `default_hour`. A time with no day is today, or
/// tomorrow once that time has passed; a weekday whose time has passed today
/// is next week's. `None` for anything else.
#[uniffi::export]
pub fn capture_date_time(
    text: String,
    now_ms: i64,
    zone: String,
    default_hour: i64,
) -> Option<i64> {
    date_time(&text, now_ms, periodic::zone(&zone), default_hour)
}

pub fn date_time(text: &str, now_ms: i64, zone: Tz, default_hour: i64) -> Option<i64> {
    let mut day: Option<NaiveDate> = None;
    let mut time: Option<(u32, u32)> = None;
    let mut named_weekday = false;
    let lower = text.to_lowercase();
    for raw in lower
        .split([' ', ','])
        .filter(|w| !w.is_empty() && *w != "at")
    {
        let word = raw.strip_prefix('@').unwrap_or(raw);
        if time.is_none()
            && let Some(parsed) = time_of_day(word)
        {
            time = Some(parsed);
        } else if day.is_none()
            && let Some(parsed) = due_day(word, now_ms, zone)
        {
            day = Some(parsed);
            named_weekday = weekday(word).is_some();
        } else {
            return None;
        }
    }
    if day.is_none() && time.is_none() {
        return None;
    }
    let start = day.unwrap_or_else(|| local(now_ms, zone).date_naive());
    let (hour, minute) = match time {
        Some((hour, minute)) => (i64::from(hour), i64::from(minute)),
        // Foundation's `date(bySettingHour:)` refuses an hour off the clock.
        None if (0..24).contains(&default_hour) => (default_hour, 0),
        None => return None,
    };
    let at = |date: NaiveDate| {
        let wall = date.and_hms_opt(0, 0, 0)? + Duration::hours(hour) + Duration::minutes(minute);
        Some(periodic::resolve(zone, wall).timestamp_millis())
    };
    let result = at(start)?;
    if result <= now_ms && time.is_some() && (day.is_none() || named_weekday) {
        let step = if day.is_none() { 1 } else { 7 };
        return at(start.checked_add_signed(Duration::days(step))?).or(Some(result));
    }
    Some(result)
}

/// `#word`, where the word starts with a letter, so `#1` and `#123`, which
/// are issue numbers and list positions, stay in the title.
fn tag(word: &str) -> Option<String> {
    let body = word.strip_prefix('#')?;
    let mut chars = body.chars();
    let first = chars.next()?;
    if !first.is_alphabetic() {
        return None;
    }
    chars
        .all(|c| c.is_alphabetic() || c.is_numeric() || matches!(c, '_' | '-' | '/'))
        .then(|| body.to_string())
}

/// `!1` to `!4`.
fn priority(word: &str) -> Option<i64> {
    let body = word.strip_prefix('!')?;
    if body.chars().count() != 1 {
        return None;
    }
    let value: i64 = body.parse().ok()?;
    (1..=4).contains(&value).then_some(value)
}

// MARK: - Checkvist's due dates

static INTERNET_DATE_TIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})",
    )
    .expect("internet date-time pattern")
});
static LENIENT_FULL_DATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([0-9]{1,4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})").expect("full date pattern")
});

/// Checkvist's `due` string as a moment, when it names one: `DueDateParsing`.
///
/// Checkvist stores a due date as free text and returns it in whichever shape
/// it was entered: ISO 8601 with or without a time, `yyyy/MM/dd`, an unpadded
/// `yyyy-M-d`, sometimes with a trailing zone. It also stores keywords like
/// `asap` that never resolve to a date at all, which is why the answer is
/// optional rather than an error.
///
/// This is what the Mac's Foundation parsers actually answered, measured
/// rather than read off their format strings: an internet date-time (`T`,
/// seconds, an offset, optional fractional seconds) is that moment, and
/// anything else that starts with a year, month and day, separated by `-` or
/// `/`, is that day's midnight in UTC, whatever follows it. Foundation's
/// ISO 8601 full-date reading is that lenient, and it ran before the
/// zone-aware formatters, which therefore never saw a date: so
/// `2026/10/02 09:00:00 +0100` is the 2nd at midnight UTC, not 08:00. A month
/// outside 1 to 12 or a day of 0 is no date; a day past the month's end rolls
/// into the next (`2026-02-31` is 3 March), as Foundation's did.
#[uniffi::export]
pub fn checkvist_due_date(due: Option<String>) -> Option<i64> {
    checkvist_due(due.as_deref()?).map(|at| at.timestamp_millis())
}

pub fn checkvist_due(due: &str) -> Option<DateTime<Utc>> {
    let raw = due.trim();
    if raw.is_empty() {
        return None;
    }
    if let Some(at) = internet_date_time(raw) {
        return Some(at);
    }
    let captures = LENIENT_FULL_DATE.captures(raw)?;
    let year: i32 = captures[1].parse().ok()?;
    let month: u32 = captures[2].parse().ok()?;
    let day: i64 = captures[3].parse().ok()?;
    if !(1..=12).contains(&month) || day == 0 {
        return None;
    }
    let first = NaiveDate::from_ymd_opt(year, month, 1)?;
    let date = first.checked_add_signed(Duration::days(day - 1))?;
    Some(date.and_hms_opt(0, 0, 0)?.and_utc())
}

fn internet_date_time(raw: &str) -> Option<DateTime<Utc>> {
    let captures = INTERNET_DATE_TIME.captures(raw)?;
    let offset = &captures[8];
    let offset = if offset == "Z" {
        "+00:00".to_string()
    } else if offset.contains(':') {
        offset.to_string()
    } else {
        format!("{}:{}", &offset[..3], &offset[3..])
    };
    let fraction = captures.get(7).map_or("", |m| m.as_str());
    let text = format!(
        "{}-{}-{}T{}:{}:{}{fraction}{offset}",
        &captures[1], &captures[2], &captures[3], &captures[4], &captures[5], &captures[6]
    );
    DateTime::parse_from_rfc3339(&text)
        .ok()
        .map(|at| at.with_timezone(&Utc))
}

#[cfg(test)]
mod tests;
