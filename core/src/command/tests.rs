//! `TaktCommandEngineCommandParsingTests.swift` and
//! `TaktCommandEngineDueDateTests.swift`, ported, with the edges they left
//! out.

use super::*;
use chrono::TimeZone;

use PaletteCommand as C;

fn p(text: &str) -> PaletteCommand {
    parse(text)
}

#[test]
fn simple_keywords() {
    assert_eq!(p("done"), C::Done);
    assert_eq!(p("undone"), C::Undone);
    assert_eq!(p("invalidate"), C::Invalidate);
    assert_eq!(p("edit"), C::Edit);
    assert_eq!(p("search"), C::Search);
    assert_eq!(p("undo"), C::Undo);
    assert_eq!(p("delete"), C::Delete);
    assert_eq!(p("toggle timer"), C::ToggleTimer);
    assert_eq!(p("pause timer"), C::PauseTimer);
    assert_eq!(p("toggle hide future"), C::ToggleHideFuture);
}

#[test]
fn case_and_surrounding_space_do_not_matter() {
    assert_eq!(p("DONE"), C::Done);
    assert_eq!(p("Done"), C::Done);
    assert_eq!(p("  done  "), C::Done);
}

#[test]
fn navigation() {
    assert_eq!(p("add sibling"), C::AddSibling);
    assert_eq!(p("add child"), C::AddChild);
    assert_eq!(p("move up"), C::MoveUp);
    assert_eq!(p("move down"), C::MoveDown);
    assert_eq!(p("enter children"), C::EnterChildren);
    assert_eq!(p("exit parent"), C::ExitParent);
    assert_eq!(p("open link"), C::OpenLink);
    assert_eq!(p("expand"), C::ExpandTask);
    assert_eq!(p("collapse all"), C::CollapseAll);
}

#[test]
fn preference_aliases() {
    for alias in ["preferences", "prefs", "settings"] {
        assert_eq!(p(alias), C::OpenPreferences);
    }
}

#[test]
fn commands_with_an_argument_keep_it_trimmed_and_lowercased() {
    let due = |raw: &str| C::Due { raw: raw.into() };
    assert_eq!(p("due today"), due("today"));
    assert_eq!(p("due Tomorrow 9am"), due("tomorrow 9am"));
    assert_eq!(p("due next week"), due("next week"));
    assert_eq!(p("clear due"), C::ClearDue);
    assert_eq!(p("start fri"), C::SetStart { raw: "fri".into() });
    assert_eq!(p("unstart"), C::ClearStart);
    assert_eq!(
        p("repeat every 2 weeks"),
        C::SetRecurrence {
            raw: "every 2 weeks".into()
        }
    );
    assert_eq!(p("no repeat"), C::ClearRecurrence);
    assert_eq!(
        p("tag urgent"),
        C::Tag {
            tag: "urgent".into()
        }
    );
    assert_eq!(
        p("tag  spaced "),
        C::Tag {
            tag: "spaced".into()
        }
    );
    assert_eq!(
        p("untag urgent"),
        C::Untag {
            tag: "urgent".into()
        }
    );
    assert_eq!(
        p("list my-list"),
        C::List {
            query: "my-list".into()
        }
    );
}

#[test]
fn a_command_word_with_nothing_after_it_is_unknown() {
    assert_eq!(
        p("due"),
        C::Unknown {
            input: "due".into()
        }
    );
    assert_eq!(
        p("due   "),
        C::Unknown {
            input: "due   ".into()
        }
    );
}

#[test]
fn priority_ranks() {
    for rank in 1..=9 {
        assert_eq!(p(&format!("priority {rank}")), C::Priority { rank });
    }
    assert_eq!(p("priority 10"), C::Priority { rank: 10 });
    assert_eq!(p("priority 99"), C::Priority { rank: 99 });
    assert_eq!(
        p("priority 0"),
        C::Unknown {
            input: "priority 0".into()
        }
    );
    assert_eq!(p("priority back"), C::PriorityBack);
    assert_eq!(p("priority end"), C::PriorityBack);
    assert_eq!(p("priority clear"), C::ClearPriority);
    assert_eq!(p("clear priority"), C::ClearPriority);
    assert_eq!(p("unpriority"), C::ClearPriority);
}

#[test]
fn obsidian_aliases() {
    for alias in ["sync obsidian", "send to obsidian", "obsidian"] {
        assert_eq!(p(alias), C::SyncObsidian);
    }
    for alias in [
        "open obsidian new window",
        "obsidian new window",
        "open in new window",
    ] {
        assert_eq!(p(alias), C::SyncObsidianNewWindow);
    }
    for alias in ["link obsidian folder", "link folder", "obsidian folder"] {
        assert_eq!(p(alias), C::LinkObsidianFolder);
    }
    for alias in [
        "create obsidian folder",
        "new obsidian folder",
        "make obsidian folder",
    ] {
        assert_eq!(p(alias), C::CreateObsidianFolder);
    }
    for alias in [
        "clear obsidian folder",
        "unlink obsidian folder",
        "clear folder link",
    ] {
        assert_eq!(p(alias), C::ClearObsidianFolderLink);
    }
}

#[test]
fn integration_aliases() {
    for alias in [
        "sync google calendar",
        "google calendar",
        "gcal",
        "open google calendar",
        "calendar",
    ] {
        assert_eq!(p(alias), C::SyncGoogleCalendar);
    }
    assert_eq!(p("affine daily"), C::SyncAffineDay);
    assert_eq!(p("affine"), C::SyncAffine);
    assert_eq!(p("open affine document"), C::OpenAffineDocument);
    assert_eq!(p("mcp guide"), C::OpenMcpGuide);
    assert_eq!(p("palette"), C::OpenCommandPalette);
}

#[test]
fn unknown_keeps_the_input_as_typed() {
    assert_eq!(
        p("Gibberish "),
        C::Unknown {
            input: "Gibberish ".into()
        }
    );
    assert_eq!(
        p(""),
        C::Unknown {
            input: String::new()
        }
    );
}

// MARK: - Due dates

fn utc(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, 0)
        .unwrap()
        .timestamp_millis()
}

fn due_at(text: &str, now: i64) -> String {
    resolve(text, now, Tz::UTC, NamedHours::default())
}

#[test]
fn relative_day_words() {
    let now = utc(2026, 3, 30, 10, 15); // a Monday
    assert_eq!(due_at("today", now), "2026-03-30");
    assert_eq!(due_at("today 14:30", now), "2026-03-30 14:30:00 +0000");
    assert_eq!(due_at("tomorrow 9am", now), "2026-03-31 09:00:00 +0000");
    assert_eq!(due_at("monday 11am", now), "2026-04-06 11:00:00 +0000");
    assert_eq!(due_at("next mon", now), "2026-04-06");
    assert_eq!(due_at("this mon", now), "2026-03-30");
    assert_eq!(
        due_at("this sun", now),
        "2026-03-30",
        "passed this week, so today"
    );
    assert_eq!(due_at("this fri", now), "2026-04-03");
    assert_eq!(due_at("next week", now), "2026-04-06");
}

#[test]
fn absolute_dates() {
    let now = utc(2026, 3, 30, 10, 15);
    assert_eq!(due_at("2026-4-2", now), "2026-04-02");
    assert_eq!(due_at("2026-4-2 8:05pm", now), "2026-04-02 20:05:00 +0000");
    assert_eq!(due_at("2026-04-02t09:00", now), "2026-04-02 09:00:00 +0000");
    // Foundation's calendar rolls an out-of-range month or day over.
    assert_eq!(due_at("2026-2-31", now), "2026-03-03");
    assert_eq!(due_at("2026-13-1", now), "2027-01-01");
    assert_eq!(due_at("2026-3-0", now), "2026-02-28");
    assert_eq!(due_at("2026-0-1", now), "2025-12-01");
    assert_eq!(due_at("26-4-2", now), "26-4-2");
    assert_eq!(due_at("2026-4-2 whenever", now), "2026-4-2 whenever");
}

#[test]
fn a_time_alone_is_today_and_an_offset_counts_from_now() {
    let now = utc(2026, 3, 30, 10, 15);
    assert_eq!(due_at("9am", now), "2026-03-30 09:00:00 +0000");
    assert_eq!(due_at("in 90m", now), "2026-03-30 11:45:00 +0000");
}

#[test]
fn noon_midnight_and_the_twelve_hour_clock() {
    let now = utc(2026, 4, 1, 10, 0);
    assert_eq!(due_at("today noon", now), "2026-04-01 12:00:00 +0000");
    assert_eq!(due_at("today midnight", now), "2026-04-01 00:00:00 +0000");
    assert_eq!(due_at("12pm", now), "2026-04-01 12:00:00 +0000");
    assert_eq!(due_at("12am", now), "2026-04-01 00:00:00 +0000");
    assert_eq!(due_at("1:30pm", now), "2026-04-01 13:30:00 +0000");
    assert_eq!(due_at("1:30 PM", now), "2026-04-01 13:30:00 +0000");
    assert_eq!(due_at("23:45", now), "2026-04-01 23:45:00 +0000");
    assert_eq!(due_at("0:00", now), "2026-04-01 00:00:00 +0000");
    assert_eq!(due_at("13pm", now), "13pm");
    assert_eq!(due_at("24:00", now), "24:00");
}

#[test]
fn offsets() {
    let now = utc(2026, 4, 1, 10, 0);
    assert_eq!(due_at("in 30m", now), "2026-04-01 10:30:00 +0000");
    assert_eq!(due_at("in 2h", now), "2026-04-01 12:00:00 +0000");
    assert_eq!(due_at("in 1 day", now), "2026-04-02 10:00:00 +0000");
    assert_eq!(due_at("in 45 minutes", now), "2026-04-01 10:45:00 +0000");
    assert_eq!(due_at("in a week", now), "2026-04-08 10:00:00 +0000");
    assert_eq!(due_at("in an hour", now), "2026-04-01 11:00:00 +0000");
    assert_eq!(due_at("in 0m", now), "in 0m");
}

#[test]
fn what_it_does_not_read_passes_through() {
    let now = utc(2026, 4, 1, 10, 0);
    assert_eq!(due_at("asap", now), "asap");
    assert_eq!(due_at("", now), "");
    assert_eq!(due_at("  Someday  ", now), "Someday");
    assert_eq!(due_at("today whenever", now), "today whenever");
}

#[test]
fn weekdays_and_months() {
    let now = utc(2026, 4, 1, 10, 0); // a Wednesday
    assert_eq!(due_at("friday", now), "2026-04-03");
    assert_eq!(
        due_at("wednesday", now),
        "2026-04-08",
        "a bare weekday is never today"
    );
    assert_eq!(due_at("next month", now), "2026-05-01");
    assert_eq!(due_at("next month", utc(2026, 1, 31, 10, 0)), "2026-02-28");
}

#[test]
fn at_and_a_time_before_the_day() {
    let now = utc(2026, 4, 1, 10, 0);
    assert_eq!(due_at("today at 3pm", now), "2026-04-01 15:00:00 +0000");
    assert_eq!(due_at("4pm fri", now), "2026-04-03 16:00:00 +0000");
    assert_eq!(
        due_at("morning next monday", now),
        "2026-04-06 09:00:00 +0000"
    );
    assert_eq!(due_at("9am tomorrow", now), "2026-04-02 09:00:00 +0000");
    assert_eq!(due_at("eod tomorrow", now), "2026-04-02 17:00:00 +0000");
}

#[test]
fn named_hours_are_the_callers() {
    let now = utc(2026, 4, 1, 10, 0);
    let hours = NamedHours {
        morning: 7,
        afternoon: 13,
        evening: 20,
        end_of_day: 16,
    };
    assert_eq!(
        resolve("tomorrow morning", now, Tz::UTC, hours),
        "2026-04-02 07:00:00 +0000"
    );
    assert_eq!(
        resolve("today cob", now, Tz::UTC, hours),
        "2026-04-01 16:00:00 +0000"
    );
}

#[test]
fn the_answer_is_in_the_callers_zone() {
    // 23:30 UTC on 31 March is already 1 April in London (BST).
    let now = utc(2026, 3, 31, 23, 30);
    let london = periodic::zone("Europe/London");
    let hours = NamedHours::default();
    assert_eq!(resolve("today", now, london, hours), "2026-04-01");
    assert_eq!(
        resolve("today 9am", now, london, hours),
        "2026-04-01 09:00:00 +0100"
    );
    assert_eq!(
        resolve("in 30m", now, london, hours),
        "2026-04-01 01:00:00 +0100"
    );
    // The night the clocks go forward, 01:30 does not exist: it moves on an hour.
    let before = utc(2026, 3, 28, 12, 0);
    assert_eq!(
        resolve("tomorrow 1:30am", before, london, hours),
        "2026-03-29 02:30:00 +0100"
    );
}

/// Answers measured from the Swift `CommandEngine` before it moved here.
#[test]
fn edges_measured_against_foundation() {
    let now = utc(2026, 4, 1, 10, 0);
    let london = periodic::zone("Europe/London");
    let hours = NamedHours::default();
    assert_eq!(due_at("9", now), "2026-04-01 09:00:00 +0000");
    assert_eq!(due_at("2026-4-2t", now), "2026-04-02");
    assert_eq!(due_at("today  at  3pm", now), "2026-04-01 15:00:00 +0000");
    // Weeks keep the wall clock across the change to summer time.
    assert_eq!(
        resolve("in 2 weeks", utc(2026, 3, 20, 10, 0), london, hours),
        "2026-04-03 10:00:00 +0100"
    );
    assert_eq!(
        resolve("tomorrow", utc(2026, 3, 28, 0, 30), london, hours),
        "2026-03-29"
    );
    assert_eq!(p("priority +3"), C::Priority { rank: 3 });
}
