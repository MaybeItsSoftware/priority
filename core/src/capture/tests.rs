//! `TaskCaptureSyntaxTests.swift`, the date-word half of
//! `WaitingFollowUpTests.swift` and Kotlin's `DueDateParsingTest`, ported.

use super::*;
use chrono::TimeZone;

fn at(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, 0)
        .unwrap()
        .timestamp_millis()
}

fn day(year: i32, month: u32, day: u32) -> i64 {
    at(year, month, day, 0, 0)
}

/// Tuesday 29 September 2026, mid-morning.
fn now() -> i64 {
    at(2026, 9, 29, 10, 0)
}

fn p(text: &str) -> CaptureParts {
    parse(text, now(), Tz::UTC)
}

fn title(text: &str) -> CaptureParts {
    CaptureParts {
        title: text.into(),
        ..CaptureParts::default()
    }
}

#[test]
fn a_plain_title_is_left_exactly_as_typed() {
    assert_eq!(
        p("  Write the release notes "),
        title("Write the release notes")
    );
    assert_eq!(p("Two  spaces  kept"), title("Two  spaces  kept"));
}

#[test]
fn checkvists_caret_marks_a_due_day_too() {
    let capture = p("Ring the bank ^fri");
    assert_eq!(capture.title, "Ring the bank");
    assert_eq!(capture.due_at_ms, Some(day(2026, 10, 2)));
    assert_eq!(capture.due_at_ms, p("Ring the bank @fri").due_at_ms);
}

#[test]
fn every_kind_of_token_at_the_end() {
    let capture = p("Write the release notes 45m #work @fri !1");
    assert_eq!(capture.title, "Write the release notes");
    assert_eq!(capture.estimate_seconds, Some(45 * 60));
    assert_eq!(capture.due_at_ms, Some(day(2026, 10, 2)));
    assert_eq!(capture.tags, vec!["work".to_string()]);
    assert_eq!(capture.priority, Some(1));
    assert!(capture.has_details());
}

#[test]
fn tokens_in_the_middle_of_a_title_stay_in_it() {
    assert_eq!(p("Buy 2m of cable"), title("Buy 2m of cable"));
    assert_eq!(p("Read 30 pages"), title("Read 30 pages"));
}

#[test]
fn a_word_the_field_does_not_know_ends_the_scan() {
    let capture = p("Call mum @home 10m");
    assert_eq!(capture.title, "Call mum @home");
    assert_eq!(capture.estimate_seconds, Some(10 * 60));
}

#[test]
fn the_first_word_is_always_the_title() {
    assert_eq!(p("30m"), title("30m"));
    let capture = p("30m #admin");
    assert_eq!(capture.title, "30m");
    assert_eq!(capture.tags, vec!["admin".to_string()]);
}

#[test]
fn estimate_spellings() {
    let cases: [(&str, Option<i64>); 17] = [
        ("30m", Some(30)),
        ("90min", Some(90)),
        ("5mins", Some(5)),
        ("1h", Some(60)),
        ("2hrs", Some(120)),
        ("1.5h", Some(90)),
        ("1h30m", Some(90)),
        ("1h30", Some(90)),
        ("~20m", Some(20)),
        ("2hours", Some(120)),
        ("45minutes", Some(45)),
        ("0m", None),
        ("25h", None),
        ("1h75m", None),
        ("1.5h30", None),
        ("m", None),
        ("10", None),
    ];
    for (word, minutes) in cases {
        assert_eq!(estimate(word), minutes.map(|m| m * 60), "{word}");
    }
}

#[test]
fn due_spellings() {
    let cases: [(&str, Option<i64>); 14] = [
        ("today", Some(day(2026, 9, 29))),
        ("tod", Some(day(2026, 9, 29))),
        ("tomorrow", Some(day(2026, 9, 30))),
        ("tmr", Some(day(2026, 9, 30))),
        // Today is a Tuesday, so "tue" is today rather than a week away.
        ("tue", Some(day(2026, 9, 29))),
        ("wednesday", Some(day(2026, 9, 30))),
        ("mon", Some(day(2026, 10, 5))),
        ("3d", Some(day(2026, 10, 2))),
        ("2w", Some(day(2026, 10, 13))),
        ("2026-12-25", Some(day(2026, 12, 25))),
        ("2027-1-4", Some(day(2027, 1, 4))),
        ("2026-02-31", None),
        ("home", None),
        ("0d", None),
    ];
    for (word, expected) in cases {
        assert_eq!(due(word, now(), Tz::UTC), expected, "{word}");
    }
}

#[test]
fn a_due_day_starts_at_local_midnight() {
    // 23:30 UTC on the 29th is already the 30th in Tokyo.
    let late = at(2026, 9, 29, 23, 30);
    assert_eq!(
        due("today", late, Tz::Asia__Tokyo),
        Some(at(2026, 9, 29, 15, 0))
    );
    assert_eq!(
        due("tomorrow", now(), Tz::Europe__London),
        Some(at(2026, 9, 29, 23, 0))
    );
}

#[test]
fn due_needs_its_at() {
    assert_eq!(p("Stand up tomorrow"), title("Stand up tomorrow"));
    assert_eq!(p("Stand up @tomorrow").due_at_ms, Some(day(2026, 9, 30)));
}

#[test]
fn tags_must_start_with_a_letter() {
    assert_eq!(p("Fix issue #123"), title("Fix issue #123"));
    assert_eq!(p("Chapter #1"), title("Chapter #1"));
    assert_eq!(p("Plan #q4-launch").tags, vec!["q4-launch".to_string()]);
    assert_eq!(p("Read #café").tags, vec!["café".to_string()]);
}

#[test]
fn several_tags_keep_their_order_and_drop_repeats() {
    let capture = p("Plan offsite #Work #travel #work");
    assert_eq!(capture.title, "Plan offsite");
    assert_eq!(capture.tags, vec!["Work".to_string(), "travel".to_string()]);
}

#[test]
fn priority_is_one_to_four() {
    assert_eq!(p("Ship it !4").priority, Some(4));
    assert_eq!(p("Ship it !5"), title("Ship it !5"));
    assert_eq!(p("Ship it !"), title("Ship it !"));
}

/// The last one typed wins, and the earlier one stays visible in the title.
#[test]
fn a_second_token_of_one_kind_stays_in_the_title() {
    let capture = p("Draft 30m 45m");
    assert_eq!(capture.title, "Draft 30m");
    assert_eq!(capture.estimate_seconds, Some(45 * 60));
}

#[test]
fn labels_name_what_was_found() {
    let labels = |text: &str| detail_labels(&p(text), now(), Tz::UTC);
    assert_eq!(
        labels("Write notes 1h30m @tomorrow #work !2"),
        vec!["1h 30m", "Tomorrow", "#work", "!2"]
    );
    assert_eq!(labels("Book flights @2026-10-02"), vec!["Fri 2 Oct"]);
    assert_eq!(labels("Renew passport @2027-03-01"), vec!["1 Mar 2027"]);
    assert_eq!(labels("Ring @today"), vec!["Today"]);
    assert_eq!(labels("Ask 2h wait:Sam"), vec!["2h", "waiting on Sam"]);
    assert_eq!(labels("Plan @2026-09-03"), vec!["Thu 3 Sep"]);
}

#[test]
fn wait_colon_files_it_as_waiting_on_someone() {
    let capture = p("Contract signed wait:Sam ^fri");
    assert_eq!(capture.title, "Contract signed");
    assert_eq!(capture.waiting_on.as_deref(), Some("Sam"));
    assert_eq!(capture.due_at_ms, Some(day(2026, 10, 2)));
    assert_eq!(p("Can't wait").title, "Can't wait");
    assert_eq!(p("Ask wait:").waiting_on, None);
}

#[test]
fn durations_read_as_hours_and_minutes() {
    assert_eq!(duration_label(45 * 60), "45m");
    assert_eq!(duration_label(2 * 3600), "2h");
    assert_eq!(duration_label(90 * 60), "1h 30m");
    assert_eq!(duration_label(-5), "0m");
}

// MARK: - Date and time words (WaitingFollowUpTests)

/// Tuesday 6 October 2026, 10:00 UTC.
fn follow_up(text: &str) -> Option<i64> {
    date_time(text, at(2026, 10, 6, 10, 0), Tz::UTC, 9)
}

#[test]
fn a_day_alone_is_at_nine() {
    assert_eq!(follow_up("tomorrow"), Some(at(2026, 10, 7, 9, 0)));
    assert_eq!(follow_up("@fri"), Some(at(2026, 10, 9, 9, 0)));
    assert_eq!(follow_up("3d"), Some(at(2026, 10, 9, 9, 0)));
    assert_eq!(follow_up("2026-10-08"), Some(at(2026, 10, 8, 9, 0)));
}

#[test]
fn a_day_and_a_time_in_either_order() {
    assert_eq!(follow_up("tomorrow 9am"), Some(at(2026, 10, 7, 9, 0)));
    assert_eq!(follow_up("2026-10-08 14:00"), Some(at(2026, 10, 8, 14, 0)));
    assert_eq!(follow_up("fri at 2:30pm"), Some(at(2026, 10, 9, 14, 30)));
    assert_eq!(follow_up("3pm @thu"), Some(at(2026, 10, 8, 15, 0)));
    assert_eq!(follow_up("Tomorrow Noon"), Some(at(2026, 10, 7, 12, 0)));
    assert_eq!(follow_up("tomorrow, 9.30"), Some(at(2026, 10, 7, 9, 30)));
}

#[test]
fn a_time_alone_is_the_next_one_to_come() {
    assert_eq!(follow_up("14:00"), Some(at(2026, 10, 6, 14, 0)));
    assert_eq!(follow_up("9am"), Some(at(2026, 10, 7, 9, 0)));
    assert_eq!(follow_up("12am"), Some(at(2026, 10, 7, 0, 0)));
}

/// Today is a Tuesday: "tue 9am" has gone, so it is next Tuesday's.
#[test]
fn a_weekday_whose_time_has_passed_is_next_weeks() {
    assert_eq!(follow_up("tue 9am"), Some(at(2026, 10, 13, 9, 0)));
    assert_eq!(follow_up("tue 4pm"), Some(at(2026, 10, 6, 16, 0)));
    // "today" means today, even when the time has gone: it is due at once.
    assert_eq!(follow_up("today 9am"), Some(at(2026, 10, 6, 9, 0)));
}

#[test]
fn unreadable_text_is_none() {
    for text in [
        "",
        "soon",
        "25:00",
        "13pm",
        "9:75",
        "tomorrow tomorrow",
        "9am 10am",
        "2026-02-31",
    ] {
        assert_eq!(follow_up(text), None, "{text}");
    }
    assert_eq!(
        date_time("tomorrow", at(2026, 10, 6, 10, 0), Tz::UTC, 24),
        None
    );
}

// MARK: - Checkvist's due dates

#[test]
fn no_date_for_nothing_or_a_keyword() {
    assert_eq!(checkvist_due_date(None), None);
    assert_eq!(checkvist_due_date(Some("  ".into())), None);
    assert_eq!(checkvist_due_date(Some("asap".into())), None);
}

#[test]
fn checkvists_formats_read_as_foundation_read_them() {
    let read = |text: &str| checkvist_due_date(Some(text.into()));
    assert_eq!(read("2026-10-02"), Some(day(2026, 10, 2)));
    assert_eq!(read("2026-10-02T09:30:00Z"), Some(at(2026, 10, 2, 9, 30)));
    assert_eq!(
        read("2026-10-02T10:30:00.000+01:00"),
        Some(at(2026, 10, 2, 9, 30))
    );
    assert_eq!(
        read("2026-10-02T10:30:00+0100"),
        Some(at(2026, 10, 2, 9, 30))
    );
    assert_eq!(read("2026-1-5"), Some(day(2026, 1, 5)));
    assert_eq!(read("2026/10/02"), Some(day(2026, 10, 2)));
    // The full-date reading ran first and ignored what followed the day.
    assert_eq!(read("2026/10/02 09:00:00 +0100"), Some(day(2026, 10, 2)));
    assert_eq!(read("2026-10-02 sometime"), Some(day(2026, 10, 2)));
    assert_eq!(read("2026-10-02T09:30:00"), Some(day(2026, 10, 2)));
    // A day past the month's end rolls on; a month past twelve is nothing.
    assert_eq!(read("2026-02-31"), Some(day(2026, 3, 3)));
    assert_eq!(read("2026-13-05"), None);
    assert_eq!(read("2026-10-00"), None);
    assert_eq!(read("20261002"), None);
}
