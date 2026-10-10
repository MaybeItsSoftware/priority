//! The Mac's command palette: what a typed command means
//! (`CommandEngine.parse`) and the date words its `due` and `start` commands
//! take (`CommandEngine.resolveDueDate`). README.md is authoritative for the
//! syntax.
//!
//! The palette's suggestion rows stay in Swift: they are the Mac's own
//! display strings, and filtering them is a substring test.

use std::sync::LazyLock;

use chrono::{DateTime, Datelike, Duration, Months, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use chrono_tz::Tz;
use regex_lite::Regex;

use crate::periodic;

/// What a palette command asks for. Each case is one of Swift's `Command`
/// cases, which wraps it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PaletteCommand {
    Done,
    Undone,
    Invalidate,
    Due {
        raw: String,
    },
    ClearDue,
    SetStart {
        raw: String,
    },
    ClearStart,
    SetRecurrence {
        raw: String,
    },
    ClearRecurrence,
    Edit,
    Search,
    OpenPreferences,
    OpenMainWindow,
    OpenDiagnostics,
    ReloadCheckvistLists,
    UploadOfflineTasks,
    AddSibling,
    AddChild,
    OpenLink,
    Undo,
    ToggleTimer,
    PauseTimer,
    ToggleHideFuture,
    Delete,
    MoveUp,
    MoveDown,
    EnterChildren,
    ExitParent,
    ExpandTask,
    CollapseTask,
    ExpandAll,
    CollapseAll,
    Tag {
        tag: String,
    },
    Untag {
        tag: String,
    },
    List {
        query: String,
    },
    Priority {
        rank: i64,
    },
    PriorityBack,
    ClearPriority,
    SyncObsidian,
    SyncObsidianNewWindow,
    ChooseObsidianInbox,
    ClearObsidianInbox,
    LinkObsidianFolder,
    CreateObsidianFolder,
    ClearObsidianFolderLink,
    SyncAffine,
    OpenAffineDocument,
    SyncAffineDay,
    SyncGoogleCalendar,
    RefreshMcpPath,
    CopyMcpClientConfig,
    OpenMcpGuide,
    QuickAdd,
    ToggleContext,
    ToggleChildrenInMenus,
    EditAtStart,
    OpenCommandPalette,
    /// Nothing the palette knows, carrying the input as typed.
    Unknown {
        input: String,
    },
}

/// Foundation's `.whitespaces`: spaces and tabs, but not line breaks.
fn is_inline_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(
            c,
            '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}

fn trim_inline(text: &str) -> &str {
    text.trim_matches(is_inline_space)
}

/// Reads a typed palette command, case-insensitively. Anything it does not
/// know is [`PaletteCommand::Unknown`] with the input as typed.
#[uniffi::export]
pub fn palette_command_parse(input: String) -> PaletteCommand {
    parse(&input)
}

pub fn parse(input: &str) -> PaletteCommand {
    use PaletteCommand as C;
    let lowered = input.to_lowercase();
    let cmd = trim_inline(&lowered);
    let rest = |prefix: &str| {
        cmd.strip_prefix(prefix)
            .map(|raw| trim_inline(raw).to_string())
    };

    if let Some(raw) = rest("due ") {
        return C::Due { raw };
    }
    if let Some(raw) = rest("start ") {
        return C::SetStart { raw };
    }
    if let Some(raw) = rest("repeat ") {
        return C::SetRecurrence { raw };
    }
    if let Some(tag) = rest("tag ") {
        return C::Tag { tag };
    }
    if let Some(tag) = rest("untag ") {
        return C::Untag { tag };
    }
    if let Some(query) = rest("list ") {
        return C::List { query };
    }
    if let Some(raw) = rest("priority ") {
        match raw.as_str() {
            "back" | "end" => return C::PriorityBack,
            "clear" => return C::ClearPriority,
            _ => {
                // Swift's `Int(_:)`: an optional leading `+`, then digits.
                if let Ok(rank) = raw.parse::<i64>()
                    && rank >= 1
                {
                    return C::Priority { rank };
                }
            }
        }
    }

    match cmd {
        "done" => C::Done,
        "undone" => C::Undone,
        "invalidate" => C::Invalidate,
        "clear due" => C::ClearDue,
        "clear start" | "remove start" | "unstart" => C::ClearStart,
        "clear repeat" | "remove repeat" | "no repeat" | "unrepeat" => C::ClearRecurrence,
        "edit" => C::Edit,
        "search" => C::Search,
        "preferences" | "prefs" | "settings" => C::OpenPreferences,
        "window" | "open window" | "main window" => C::OpenMainWindow,
        "diagnostics" | "support" | "health" => C::OpenDiagnostics,
        "reload checkvist lists" | "reload lists" | "refresh lists" => C::ReloadCheckvistLists,
        "upload offline tasks" | "upload offline" => C::UploadOfflineTasks,
        "add sibling" => C::AddSibling,
        "add child" => C::AddChild,
        "open link" => C::OpenLink,
        "undo" => C::Undo,
        "toggle timer" => C::ToggleTimer,
        "pause timer" => C::PauseTimer,
        "toggle hide future" => C::ToggleHideFuture,
        "delete" => C::Delete,
        "move up" => C::MoveUp,
        "move down" => C::MoveDown,
        "enter children" => C::EnterChildren,
        "exit parent" => C::ExitParent,
        "expand" => C::ExpandTask,
        "collapse" => C::CollapseTask,
        "expand all" => C::ExpandAll,
        "collapse all" => C::CollapseAll,
        "clear priority" | "unpriority" => C::ClearPriority,
        "sync obsidian" | "send to obsidian" | "obsidian" => C::SyncObsidian,
        "open obsidian new window" | "obsidian new window" | "open in new window" => {
            C::SyncObsidianNewWindow
        }
        "choose obsidian inbox" | "choose inbox folder" | "obsidian inbox" => {
            C::ChooseObsidianInbox
        }
        "clear obsidian inbox" | "clear inbox folder" => C::ClearObsidianInbox,
        "link obsidian folder" | "link folder" | "obsidian folder" => C::LinkObsidianFolder,
        "create obsidian folder" | "new obsidian folder" | "make obsidian folder" => {
            C::CreateObsidianFolder
        }
        "clear obsidian folder" | "unlink obsidian folder" | "clear folder link" => {
            C::ClearObsidianFolderLink
        }
        "affine daily" | "sync affine day" | "affine log" => C::SyncAffineDay,
        "sync affine" | "send to affine" | "affine" => C::SyncAffine,
        "open affine" | "open affine document" => C::OpenAffineDocument,
        "sync google calendar"
        | "google calendar"
        | "gcal"
        | "open google calendar"
        | "calendar" => C::SyncGoogleCalendar,
        "refresh mcp path" | "mcp refresh path" => C::RefreshMcpPath,
        "copy mcp config" | "mcp config" | "mcp copy config" => C::CopyMcpClientConfig,
        "open mcp guide" | "mcp guide" => C::OpenMcpGuide,
        "quick add" => C::QuickAdd,
        "toggle context" => C::ToggleContext,
        "toggle children" | "toggle subtree" => C::ToggleChildrenInMenus,
        "edit start" => C::EditAtStart,
        "command palette" | "open palette" | "palette" => C::OpenCommandPalette,
        _ => C::Unknown {
            input: input.to_string(),
        },
    }
}

// MARK: - Due dates

/// The hours the named times of day stand for: Swift's
/// `TaktDateParsingConfig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct NamedHours {
    pub morning: i64,
    pub afternoon: i64,
    pub evening: i64,
    pub end_of_day: i64,
}

impl Default for NamedHours {
    fn default() -> Self {
        Self {
            morning: 9,
            afternoon: 14,
            evening: 18,
            end_of_day: 17,
        }
    }
}

/// A `due` or `start` command's words as the string the task stores:
/// `yyyy-MM-dd` for a day, `yyyy-MM-dd HH:mm:ss +zzzz` for a moment, in
/// `zone`; and the input unchanged for anything it does not read (`asap`).
///
/// It reads, in this order: a time before a day word (`4pm fri`); `today`,
/// `tomorrow`, `next week`, `next month`, `next fri`, `this fri` or a bare
/// weekday (the coming one, never today), each with an optional time after
/// it; `in 90m`, `in 2 days`, `in a week`; a `yyyy-m-d` date with an optional
/// time; and a time alone, which is today.
#[uniffi::export]
pub fn resolve_due_date(input: String, now_ms: i64, zone: String, hours: NamedHours) -> String {
    resolve(&input, now_ms, periodic::zone(&zone), hours)
}

pub fn resolve(input: &str, now_ms: i64, zone: Tz, hours: NamedHours) -> String {
    let raw = input.trim();
    if raw.is_empty() {
        return input.to_string();
    }
    let now = DateTime::<Utc>::from_timestamp_millis(now_ms)
        .unwrap_or_default()
        .with_timezone(&zone)
        .naive_local();
    let normalized = raw.to_lowercase();
    let moment = |at: NaiveDateTime| {
        periodic::resolve(zone, at)
            .with_timezone(&zone)
            .format("%Y-%m-%d %H:%M:%S %z")
            .to_string()
    };

    if let Some(at) = time_first(&normalized, now, hours) {
        return moment(at);
    }
    if let Some((base, time_text)) = relative_day(&normalized, now) {
        return match time_text {
            None => base.date().format("%Y-%m-%d").to_string(),
            Some(text) => match time_of_day(text, hours) {
                Some(time) => moment(base.date().and_time(time)),
                None => raw.to_string(),
            },
        };
    }
    if let Some(at) = relative_offset(&normalized, now_ms, now, zone) {
        return at
            .with_timezone(&zone)
            .format("%Y-%m-%d %H:%M:%S %z")
            .to_string();
    }
    if let Some((day, time_text)) = absolute_day(&normalized) {
        return match time_text {
            None => day.format("%Y-%m-%d").to_string(),
            Some(text) => match time_of_day(text, hours) {
                Some(time) => moment(day.and_time(time)),
                None => raw.to_string(),
            },
        };
    }
    if let Some(time) = time_of_day(&normalized, hours) {
        return moment(now.date().and_time(time));
    }
    raw.to_string()
}

/// `keyword` alone or followed by a space: what follows it, trimmed.
fn suffix<'a>(text: &'a str, keyword: &str) -> Option<&'a str> {
    let rest = text.strip_prefix(keyword)?;
    if rest.is_empty() || rest.starts_with(' ') {
        Some(trim_inline(rest))
    } else {
        None
    }
}

const WEEKDAYS: [(&str, u32); 17] = [
    ("sunday", 0),
    ("sun", 0),
    ("monday", 1),
    ("mon", 1),
    ("tuesday", 2),
    ("tue", 2),
    ("tues", 2),
    ("wednesday", 3),
    ("wed", 3),
    ("thursday", 4),
    ("thu", 4),
    ("thur", 4),
    ("thurs", 4),
    ("friday", 5),
    ("fri", 5),
    ("saturday", 6),
    ("sat", 6),
];

fn found(time: &str) -> Option<&str> {
    (!time.is_empty()).then_some(time)
}

/// A day word and whatever followed it: `None` for no time, else its text.
/// The day keeps `now`'s time of day, as Foundation's calendar arithmetic does.
fn relative_day(text: &str, now: NaiveDateTime) -> Option<(NaiveDateTime, Option<&str>)> {
    let days = |count: i64| now.checked_add_signed(Duration::days(count));

    if let Some(time) = suffix(text, "today") {
        return Some((now, found(time)));
    }
    if let Some(time) = suffix(text, "tomorrow") {
        return Some((days(1)?, found(time)));
    }
    if let Some(time) = suffix(text, "next week") {
        return Some((days(7)?, found(time)));
    }
    if let Some(time) = suffix(text, "next month") {
        return Some((now.checked_add_months(Months::new(1))?, found(time)));
    }
    let current = i64::from(now.weekday().num_days_from_sunday());
    // "next fri": always the coming one, a week on when it is today.
    for (name, weekday) in WEEKDAYS {
        if let Some(time) = suffix(text, &format!("next {name}")) {
            let diff = (i64::from(weekday) - current).rem_euclid(7);
            return Some((days(if diff == 0 { 7 } else { diff })?, found(time)));
        }
    }
    // "this fri": within the current week, today once it has passed.
    for (name, weekday) in WEEKDAYS {
        if let Some(time) = suffix(text, &format!("this {name}")) {
            let diff = (i64::from(weekday) - current).max(0);
            return Some((days(diff)?, found(time)));
        }
    }
    for (name, weekday) in WEEKDAYS {
        if let Some(time) = suffix(text, name) {
            let diff = (i64::from(weekday) - current).rem_euclid(7);
            return Some((days(if diff == 0 { 7 } else { diff })?, found(time)));
        }
    }
    None
}

static TIME_FIRST: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^((?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\s*[ap]m|(?:[01]?[0-9]|2[0-3]):[0-5][0-9]|noon|midnight|morning|afternoon|evening|eod)\s+(.+)$",
    )
    .expect("time-first pattern")
});
static RELATIVE_OFFSET: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^in\s+(a|an|[0-9]+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks)$",
    )
    .expect("relative offset pattern")
});
static TWELVE_HOUR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(1[0-2]|0?[1-9])(?::([0-5][0-9]))?\s*([ap]m)$").expect("twelve-hour pattern")
});
static TWENTY_FOUR_HOUR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([01]?[0-9]|2[0-3])(?::([0-5][0-9]))?$").expect("twenty-four-hour pattern")
});

/// `4pm fri`, `9am tomorrow`, `morning next monday`: a time, then a day word
/// with nothing after it.
fn time_first(text: &str, now: NaiveDateTime, hours: NamedHours) -> Option<NaiveDateTime> {
    let captures = TIME_FIRST.captures(text)?;
    let (base, trailing) = relative_day(&captures[2], now)?;
    if trailing.is_some() {
        return None;
    }
    Some(base.date().and_time(time_of_day(&captures[1], hours)?))
}

/// `in 90m`, `in 2 days`, `in a week`. Minutes and hours are elapsed time;
/// days and weeks keep the time of day.
fn relative_offset(text: &str, now_ms: i64, now: NaiveDateTime, zone: Tz) -> Option<DateTime<Utc>> {
    let captures = RELATIVE_OFFSET.captures(text)?;
    let amount: i64 = match &captures[1] {
        "a" | "an" => 1,
        digits => digits.parse().ok().filter(|n| *n > 0)?,
    };
    let elapsed = |unit: i64| {
        let ms = now_ms.checked_add(amount.checked_mul(unit)?)?;
        DateTime::<Utc>::from_timestamp_millis(ms)
    };
    let wall = |days: i64| {
        let at = now.checked_add_signed(Duration::try_days(amount.checked_mul(days)?)?)?;
        Some(periodic::resolve(zone, at))
    };
    match &captures[2] {
        "m" | "min" | "mins" | "minute" | "minutes" => elapsed(60_000),
        "h" | "hr" | "hrs" | "hour" | "hours" => elapsed(3_600_000),
        "d" | "day" | "days" => wall(1),
        _ => wall(7),
    }
}

/// `2026-4-2`, then an optional time after a space or a `t`. A month or day
/// out of range rolls over, as Foundation's calendar does: `2026-13-1` is
/// January 2027 and `2026-3-0` the last day of February.
fn absolute_day(text: &str) -> Option<(NaiveDate, Option<&str>)> {
    let (date_part, time_part) = match text.find([' ', 't']) {
        Some(index) => {
            let rest = trim_inline(&text[index + 1..]);
            (&text[..index], (!rest.is_empty()).then_some(rest))
        }
        None => (text, None),
    };
    let parts: Vec<&str> = date_part.split('-').collect();
    if parts.len() != 3 || parts[0].chars().count() != 4 {
        return None;
    }
    let year: i32 = parts[0].parse().ok()?;
    let month: i64 = parts[1].parse().ok()?;
    let day: i64 = parts[2].parse().ok()?;
    let months = u32::try_from(month.checked_sub(1)?.max(0)).ok()?;
    let mut first = NaiveDate::from_ymd_opt(year, 1, 1)?.checked_add_months(Months::new(months))?;
    if month < 1 {
        first = first.checked_sub_months(Months::new(u32::try_from(1 - month).ok()?))?;
    }
    let date = first.checked_add_signed(Duration::try_days(day.checked_sub(1)?)?)?;
    Some((date, time_part))
}

/// `9am`, `1:30pm`, `14:00`, `9`, `noon`, `midnight`, `morning`,
/// `afternoon`, `evening`, `eod` (`end of day`, `cob`), each optionally after
/// `at`.
fn time_of_day(raw: &str, hours: NamedHours) -> Option<NaiveTime> {
    let lowered = raw.trim().to_lowercase();
    let mut text = lowered.as_str();
    if let Some(rest) = text.strip_prefix("at ") {
        text = rest.trim();
    }
    if text.is_empty() {
        return None;
    }
    let hour = |hour: i64| NaiveTime::from_hms_opt(u32::try_from(hour).ok()?, 0, 0);
    match text {
        "noon" => return hour(12),
        "midnight" => return hour(0),
        "morning" => return hour(hours.morning),
        "afternoon" => return hour(hours.afternoon),
        "evening" => return hour(hours.evening),
        "eod" | "end of day" | "cob" => return hour(hours.end_of_day),
        _ => {}
    }
    if let Some(captures) = TWELVE_HOUR.captures(text) {
        let mut hour: u32 = captures[1].parse().ok()?;
        let minute: u32 = captures
            .get(2)
            .map_or(Some(0), |m| m.as_str().parse().ok())?;
        match &captures[3] {
            "pm" if hour != 12 => hour += 12,
            "am" if hour == 12 => hour = 0,
            _ => {}
        }
        return NaiveTime::from_hms_opt(hour, minute, 0);
    }
    if let Some(captures) = TWENTY_FOUR_HOUR.captures(text) {
        let hour: u32 = captures[1].parse().ok()?;
        let minute: u32 = captures
            .get(2)
            .map_or(Some(0), |m| m.as_str().parse().ok())?;
        return NaiveTime::from_hms_opt(hour, minute, 0);
    }
    None
}

#[cfg(test)]
mod tests;
