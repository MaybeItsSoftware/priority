//! Ported from `corelogic-tests/TaktDayLogTests.swift` and
//! `TaktDailyNoteTests.swift`, which still run against the Swift wrappers as
//! the oracle, plus the file-format cases the CLI pinned in `cli/src/tests.rs`.

use super::*;

fn utc() -> DayLogBoundary {
    DayLogBoundary {
        rollover_hour: 4,
        zone: "GMT".into(),
        first_weekday: 1,
    }
}

fn boundary_at(hour: i32) -> Boundary {
    Boundary::new(&DayLogBoundary {
        rollover_hour: hour,
        ..utc()
    })
}

fn boundary() -> Boundary {
    Boundary::new(&utc())
}

fn date(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, 0)
        .unwrap()
}

fn at(year: i32, month: u32, day: u32, hour: u32) -> DateTime<Utc> {
    date(year, month, day, hour, 0)
}

fn event(kind: DayLogRecordKind, task_id: i64, title: &str, when: DateTime<Utc>) -> DayLogRecord {
    DayLogRecord {
        kind,
        at_ms: when.timestamp_millis(),
        task_id,
        title: title.into(),
        duration_seconds: None,
        planned_task_ids: None,
        daily_id: None,
    }
}

fn completed(task_id: i64, title: &str, when: DateTime<Utc>) -> DayLogRecord {
    event(DayLogRecordKind::Completed, task_id, title, when)
}

fn reopened(task_id: i64, title: &str, when: DateTime<Utc>) -> DayLogRecord {
    event(DayLogRecordKind::Reopened, task_id, title, when)
}

fn daily(kind: DayLogRecordKind, id: &str, when: DateTime<Utc>) -> DayLogRecord {
    DayLogRecord {
        daily_id: Some(id.into()),
        ..event(kind, 0, id, when)
    }
}

fn ticked(id: &str, when: DateTime<Utc>) -> DayLogRecord {
    daily(DayLogRecordKind::DailyCompleted, id, when)
}

fn plan(ids: &[i64], when: DateTime<Utc>) -> DayLogRecord {
    DayLogRecord {
        planned_task_ids: Some(ids.to_vec()),
        ..event(DayLogRecordKind::PlanSnapshot, 0, "", when)
    }
}

fn focus(seconds: i64, when: DateTime<Utc>) -> DayLogRecord {
    DayLogRecord {
        duration_seconds: Some(seconds),
        ..event(DayLogRecordKind::FocusSessionEnded, 1, "A", when)
    }
}

fn scratch(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "takt-daylog-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&directory).unwrap();
    directory.join("daylog.jsonl")
}

// -- DayBoundary -------------------------------------------------------------

#[test]
fn work_after_midnight_belongs_to_the_previous_day() {
    assert_eq!(boundary().day_key(date(2026, 8, 15, 1, 30)), "2026-08-14");
    assert_eq!(boundary().day_key(date(2026, 8, 14, 3, 59)), "2026-08-13");
}

#[test]
fn work_after_rollover_belongs_to_the_current_day() {
    assert_eq!(boundary().day_key(date(2026, 8, 14, 4, 0)), "2026-08-14");
    assert_eq!(boundary().day_key(date(2026, 8, 14, 23, 59)), "2026-08-14");
}

#[test]
fn midnight_rollover_matches_the_calendar_day() {
    let midnight = boundary_at(0);
    assert_eq!(midnight.day_key(date(2026, 8, 15, 0, 1)), "2026-08-15");
    assert_eq!(midnight.day_key(date(2026, 8, 14, 23, 59)), "2026-08-14");
}

#[test]
fn the_rollover_hour_is_clamped() {
    assert_eq!(boundary_at(-5).hour, 0);
    assert_eq!(boundary_at(99).hour, 23);
}

#[test]
fn logical_day_is_idempotent() {
    let once = boundary().logical_day(at(2026, 8, 14, 10));
    assert_eq!(boundary().logical_day(once), once);
    assert_eq!(boundary().day_key(once), "2026-08-14");
    let midnight = boundary_at(0);
    assert_eq!(
        midnight.day_key(midnight.logical_day(at(2026, 8, 14, 10))),
        "2026-08-14"
    );
}

#[test]
fn week_start_is_idempotent() {
    let once = boundary().week_start(at(2026, 8, 14, 10));
    assert_eq!(boundary().week_start(once), once);
    // 2026-08-14 is a Friday; a Sunday-first week began on the 9th.
    assert_eq!(boundary().day_key(once), "2026-08-09");
    let monday = Boundary::new(&DayLogBoundary {
        first_weekday: 2,
        ..utc()
    });
    assert_eq!(
        monday.day_key(monday.week_start(at(2026, 8, 14, 10))),
        "2026-08-10"
    );
}

#[test]
fn stepping_back_a_day_and_rekeying_lands_on_yesterday() {
    let yesterday = boundary().day_offset(-1, at(2026, 8, 14, 10));
    assert_eq!(boundary().day_key(yesterday), "2026-08-13");
}

#[test]
fn days_ending_on_is_an_inclusive_oldest_first_window() {
    let days = boundary().days_ending_on(at(2026, 8, 14, 10), 3);
    let keys: Vec<String> = days.iter().map(|day| boundary().day_key(*day)).collect();
    assert_eq!(keys, ["2026-08-12", "2026-08-13", "2026-08-14"]);
    assert!(boundary().days_ending_on(at(2026, 8, 14, 10), 0).is_empty());
}

#[test]
fn weeks_ending_on_steps_back_a_week_at_a_time() {
    let weeks = boundary().weeks_ending_on(at(2026, 8, 14, 10), 3);
    assert_eq!(weeks.len(), 3);
    assert_eq!(weeks[1] - weeks[0], Duration::days(7));
}

/// Across the spring change a logical day is 23 hours long, and stepping by
/// calendar days rather than 24-hour blocks keeps every anchor at 04:00.
#[test]
fn days_step_by_the_wall_clock_across_daylight_saving() {
    let london = Boundary::new(&DayLogBoundary {
        zone: "Europe/London".into(),
        ..utc()
    });
    // The clocks went forward at 01:00 UTC on 2026-03-29.
    let days = london.days_ending_on(date(2026, 3, 30, 12, 0), 3);
    let local: Vec<String> = days
        .iter()
        .map(|day| {
            day.with_timezone(&london.zone)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .collect();
    assert_eq!(
        local,
        ["2026-03-28 04:00", "2026-03-29 04:00", "2026-03-30 04:00"]
    );
    // 01:30 BST on the 30th is still the 29th.
    assert_eq!(london.day_key(date(2026, 3, 30, 0, 30)), "2026-03-29");
}

/// A rollover hour the clocks skip lands at the end of the gap, as
/// Foundation's `bySettingHour` does.
#[test]
fn a_skipped_rollover_hour_moves_to_the_end_of_the_gap() {
    let new_york = Boundary::new(&DayLogBoundary {
        rollover_hour: 2,
        zone: "America/New_York".into(),
        first_weekday: 1,
    });
    // 2026-03-08 02:00 does not exist there; 03:00 EDT is 07:00 UTC.
    let day = new_york.logical_day(date(2026, 3, 8, 12, 0));
    assert_eq!(day, date(2026, 3, 8, 7, 0));
    assert_eq!(new_york.logical_day(day), day);
}

// -- netting -----------------------------------------------------------------

#[test]
fn a_reopen_cancels_the_matching_completion() {
    let events = [
        completed(1, "A", at(2026, 8, 14, 10)),
        reopened(1, "A", at(2026, 8, 14, 11)),
    ];
    assert!(net_completions(&events).is_empty());
}

#[test]
fn a_reopen_only_cancels_its_own_task() {
    let events = [
        completed(1, "A", at(2026, 8, 14, 10)),
        completed(2, "B", at(2026, 8, 14, 11)),
        reopened(1, "A", at(2026, 8, 14, 12)),
    ];
    let ids: Vec<i64> = net_completions(&events).iter().map(|e| e.task_id).collect();
    assert_eq!(ids, [2]);
}

#[test]
fn a_reopen_the_next_day_removes_the_previous_days_completion() {
    let events = [
        completed(1, "A", at(2026, 8, 13, 10)),
        reopened(1, "A", at(2026, 8, 14, 9)),
    ];
    assert!(
        summary(&events, &boundary(), at(2026, 8, 13, 20))
            .completed
            .is_empty()
    );
    assert!(
        summary(&events, &boundary(), at(2026, 8, 14, 12))
            .completed
            .is_empty()
    );
}

#[test]
fn a_reopen_cancels_only_the_latest_completion_of_a_repeating_task() {
    let events = [
        completed(1, "A", at(2026, 8, 12, 10)),
        completed(1, "A", at(2026, 8, 13, 10)),
        reopened(1, "A", at(2026, 8, 14, 9)),
    ];
    let surviving = net_completions(&events);
    assert_eq!(surviving.len(), 1);
    assert_eq!(
        boundary().day_key(instant(surviving[0].at_ms)),
        "2026-08-12"
    );
}

#[test]
fn an_invalidation_is_never_a_completion() {
    let events = [event(
        DayLogRecordKind::Invalidated,
        1,
        "Abandoned",
        at(2026, 8, 14, 10),
    )];
    assert!(net_completions(&events).is_empty());
}

// -- buckets -----------------------------------------------------------------

#[test]
fn daily_buckets_zero_fill_days_with_no_activity() {
    let events = [
        ticked("a", at(2026, 8, 12, 10)),
        ticked("b", at(2026, 8, 14, 10)),
        ticked("c", at(2026, 8, 14, 15)),
    ];
    let buckets = daily_buckets(&events, &boundary(), at(2026, 8, 14, 20), 3);
    let keys: Vec<&str> = buckets.iter().map(|b| b.key.as_str()).collect();
    assert_eq!(keys, ["2026-08-12", "2026-08-13", "2026-08-14"]);
    let counts: Vec<i64> = buckets.iter().map(|b| b.completed).collect();
    assert_eq!(counts, [1, 0, 2]);
}

#[test]
fn daily_buckets_always_fill_the_window() {
    let buckets = daily_buckets(&[], &boundary(), at(2026, 8, 14, 20), 30);
    assert_eq!(buckets.len(), 30);
    assert!(buckets.iter().all(|b| b.completed == 0));
}

#[test]
fn weekly_buckets_add_up_the_week() {
    let events = [
        ticked("a", at(2026, 8, 10, 10)),
        ticked("b", at(2026, 8, 12, 10)),
        ticked("c", at(2026, 8, 14, 10)),
    ];
    let buckets = weekly_buckets(&events, &boundary(), at(2026, 8, 14, 20), 2);
    assert_eq!(buckets.len(), 2);
    assert_eq!(buckets.last().unwrap().completed, 3);
}

#[test]
fn an_untick_cancels_only_its_own_days_tick() {
    let events = [
        ticked("a", at(2026, 8, 13, 10)),
        daily(DayLogRecordKind::DailyUncompleted, "a", at(2026, 8, 14, 10)),
        ticked("b", at(2026, 8, 14, 11)),
        daily(DayLogRecordKind::DailyUncompleted, "b", at(2026, 8, 14, 12)),
    ];
    let counts: Vec<i64> = daily_buckets(&events, &boundary(), at(2026, 8, 14, 20), 2)
        .iter()
        .map(|b| b.completed)
        .collect();
    assert_eq!(counts, [1, 0]);
    assert_eq!(
        completed_daily_ids(&events, &boundary(), at(2026, 8, 13, 20)),
        ["a"]
    );
}

// -- summary -----------------------------------------------------------------

#[test]
fn a_summary_counts_only_its_own_day() {
    let events = [
        completed(1, "Yesterday", at(2026, 8, 13, 10)),
        completed(2, "Today", at(2026, 8, 14, 10)),
    ];
    let day = summary(&events, &boundary(), at(2026, 8, 14, 20));
    assert_eq!(
        day.completed.iter().map(|e| e.task_id).collect::<Vec<_>>(),
        [2]
    );
    assert_eq!(day.key, "2026-08-14");
    assert_eq!(day.day_ms, at(2026, 8, 14, 4).timestamp_millis());
}

#[test]
fn unfinished_leaves_out_completed_deferred_and_invalidated_tasks() {
    let events = [
        plan(&[1, 2, 3, 4], at(2026, 8, 14, 4)),
        completed(1, "Done", at(2026, 8, 14, 10)),
        event(DayLogRecordKind::Deferred, 2, "Pushed", at(2026, 8, 14, 11)),
        event(
            DayLogRecordKind::Invalidated,
            3,
            "Dropped",
            at(2026, 8, 14, 12),
        ),
    ];
    let day = summary(&events, &boundary(), at(2026, 8, 14, 20));
    assert_eq!(day.planned_task_ids, [1, 2, 3, 4]);
    assert_eq!(day.unfinished_task_ids, [4]);
    assert_eq!(day.deferred_task_ids, [2]);
    assert_eq!(day.invalidated_task_ids, [3]);
}

#[test]
fn a_second_snapshot_on_the_same_day_wins() {
    let events = [
        plan(&[1], at(2026, 8, 14, 4)),
        plan(&[1, 2], at(2026, 8, 14, 9)),
    ];
    let day = summary(&events, &boundary(), at(2026, 8, 14, 20));
    assert_eq!(day.planned_task_ids, [1, 2]);
}

#[test]
fn focus_seconds_add_up_across_sessions() {
    let events = [
        focus(1500, at(2026, 8, 14, 10)),
        focus(1500, at(2026, 8, 14, 11)),
        focus(900, at(2026, 8, 13, 11)),
    ];
    assert_eq!(
        summary(&events, &boundary(), at(2026, 8, 14, 20)).focus_seconds,
        3000
    );
}

#[test]
fn an_empty_day_is_zeroed_rather_than_missing() {
    let day = summary(&[], &boundary(), at(2026, 8, 14, 20));
    assert!(day.completed.is_empty());
    assert!(day.planned_task_ids.is_empty());
    assert_eq!(day.focus_seconds, 0);
}

// -- history probes ----------------------------------------------------------

#[test]
fn recorded_days_are_counted_once_each() {
    let events = [
        completed(1, "A", at(2026, 8, 12, 10)),
        completed(2, "B", at(2026, 8, 12, 18)),
        completed(3, "C", at(2026, 8, 14, 10)),
    ];
    assert_eq!(recorded_day_count(&events, &boundary()), 2);
}

#[test]
fn the_first_recorded_day_is_the_earliest_logical_day() {
    let events = [
        completed(2, "B", at(2026, 8, 14, 10)),
        completed(1, "A", at(2026, 8, 12, 10)),
    ];
    let first = first_recorded_day(&events, &boundary()).unwrap();
    assert_eq!(boundary().day_key(first), "2026-08-12");
    assert!(first_recorded_day(&[], &boundary()).is_none());
}

// -- streak ------------------------------------------------------------------

fn streak(events: &[DayLogRecord], now: DateTime<Utc>) -> u32 {
    prior_completion_streak(events, &boundary(), now)
}

#[test]
fn no_history_is_no_streak() {
    assert_eq!(streak(&[], at(2026, 8, 19, 10)), 0);
}

#[test]
fn consecutive_days_accumulate_and_a_gap_ends_them() {
    let run = [
        completed(1, "A", at(2026, 8, 16, 10)),
        completed(2, "B", at(2026, 8, 17, 10)),
        completed(3, "C", at(2026, 8, 18, 10)),
    ];
    assert_eq!(streak(&run, at(2026, 8, 19, 10)), 3);
    let gapped = [
        completed(1, "A", at(2026, 8, 15, 10)),
        completed(2, "B", at(2026, 8, 17, 10)),
        completed(3, "C", at(2026, 8, 18, 10)),
    ];
    assert_eq!(streak(&gapped, at(2026, 8, 19, 10)), 2);
}

#[test]
fn todays_own_completions_are_left_out() {
    let events = [completed(1, "A", at(2026, 8, 19, 10))];
    assert_eq!(streak(&events, at(2026, 8, 19, 22)), 0);
}

#[test]
fn daily_ticks_keep_a_streak_alive_unless_taken_back() {
    let kept = [
        completed(1, "A", at(2026, 8, 17, 10)),
        ticked("habit", at(2026, 8, 18, 10)),
    ];
    assert_eq!(streak(&kept, at(2026, 8, 19, 10)), 2);
    let taken_back = [
        ticked("habit", at(2026, 8, 18, 9)),
        daily(
            DayLogRecordKind::DailyUncompleted,
            "habit",
            at(2026, 8, 18, 11),
        ),
    ];
    assert_eq!(streak(&taken_back, at(2026, 8, 19, 10)), 0);
}

#[test]
fn a_reopened_task_cannot_hold_a_day_open() {
    let events = [
        completed(1, "A", at(2026, 8, 18, 10)),
        reopened(1, "A", at(2026, 8, 19, 9)),
    ];
    assert_eq!(streak(&events, at(2026, 8, 19, 12)), 0);
}

#[test]
fn the_streak_follows_the_rollover_hour() {
    let events = [completed(1, "A", at(2026, 8, 19, 1))];
    assert_eq!(streak(&events, at(2026, 8, 19, 12)), 1);
}

#[test]
fn a_long_run_terminates() {
    let events: Vec<DayLogRecord> = (1..=20)
        .map(|day| completed(i64::from(day), "T", at(2026, 7, day, 10)))
        .collect();
    assert_eq!(streak(&events, at(2026, 7, 21, 10)), 20);
}

// -- the file ----------------------------------------------------------------

#[test]
fn appended_events_round_trip_in_order() {
    let path = scratch("round-trip");
    append(&path, &completed(1, "First", instant(100_000))).unwrap();
    append(&path, &completed(2, "Second", instant(200_000))).unwrap();
    append(&path, &focus(1500, instant(300_000))).unwrap();
    append(&path, &plan(&[1, 2, 3], instant(400_000))).unwrap();
    let loaded = load(&path);
    assert_eq!(
        loaded.iter().map(|e| e.task_id).collect::<Vec<_>>(),
        [1, 2, 1, 0]
    );
    assert_eq!(loaded[0].title, "First");
    assert_eq!(loaded[2].duration_seconds, Some(1500));
    assert_eq!(loaded[3].planned_task_ids, Some(vec![1, 2, 3]));
}

#[test]
fn a_missing_file_is_an_empty_log() {
    assert!(load(&scratch("missing")).is_empty());
}

#[test]
fn a_line_is_what_json_encoder_wrote() {
    let mut tick = ticked("x/y", instant(100_900));
    tick.title = "a/b \"q\" é \u{1}".into();
    assert_eq!(
        event_line(&tick),
        "{\"at\":\"1970-01-01T00:01:40Z\",\"dailyId\":\"x\\/y\",\"kind\":\"dailyCompleted\",\
         \"taskId\":0,\"title\":\"a\\/b \\\"q\\\" é \\u0001\"}"
    );
    assert_eq!(
        event_line(&focus(5, instant(-500))),
        "{\"at\":\"1969-12-31T23:59:59Z\",\"durationSeconds\":5,\"kind\":\"focusSessionEnded\",\
         \"taskId\":1,\"title\":\"A\"}"
    );
    assert_eq!(
        event_line(&plan(&[], instant(0))),
        "{\"at\":\"1970-01-01T00:00:00Z\",\"kind\":\"planSnapshot\",\"plannedTaskIds\":[],\
         \"taskId\":0,\"title\":\"\"}"
    );
}

#[test]
fn a_torn_line_costs_only_itself_and_the_next_append_starts_afresh() {
    let path = scratch("torn");
    append(&path, &completed(1, "Good", instant(0))).unwrap();
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    file.write_all(b"{\"kind\":\"comple").unwrap();
    drop(file);
    append(&path, &completed(2, "Later", instant(0))).unwrap();
    let ids: Vec<i64> = load(&path).iter().map(|e| e.task_id).collect();
    assert_eq!(ids, [1, 2]);
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(
        bytes
            .split(|b| *b == b'\n')
            .filter(|l| !l.is_empty())
            .count(),
        3
    );
}

#[test]
fn garbage_and_invalid_utf8_cost_only_their_own_lines() {
    let path = scratch("garbage");
    append(&path, &completed(1, "Before", instant(0))).unwrap();
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    file.write_all(b"garbage\n{\"kind\":\"completed\",\"title\":\"\xff\"}\n")
        .unwrap();
    drop(file);
    append(&path, &completed(2, "After", instant(0))).unwrap();
    let ids: Vec<i64> = load(&path).iter().map(|e| e.task_id).collect();
    assert_eq!(ids, [1, 2]);
}

#[test]
fn into_a_clean_file_no_blank_line_is_added() {
    let path = scratch("clean");
    append(&path, &completed(1, "A", instant(0))).unwrap();
    append(&path, &completed(2, "B", instant(0))).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert_eq!(text.lines().count(), 2);
    assert!(text.ends_with("}\n"));
}

/// What Swift's `JSONDecoder` with `.iso8601` keeps and drops, as probed
/// against Foundation: a line it would refuse is refused whole.
#[test]
fn lines_are_read_as_swift_reads_them() {
    let line = |body: &str| {
        parse_lines(
            format!("{{\"kind\":\"completed\",\"taskId\":1,\"title\":\"a\",{body}}}").as_bytes(),
        )
    };
    let kept = |body: &str| line(body).len() == 1;
    assert!(kept("\"at\":\"2026-08-14T10:00:00Z\""));
    assert!(kept("\"at\":\"2026-08-14T10:00:00+0100\""));
    assert!(kept("\"at\":\"2026-08-14T10:00:00-00:00\""));
    assert_eq!(
        line("\"at\":\"2026-08-14T10:00:00+01:00\"")[0].at_ms,
        at(2026, 8, 14, 9).timestamp_millis()
    );
    assert!(
        !kept("\"at\":\"2026-08-14T10:00:00.123Z\""),
        "fractional seconds"
    );
    assert!(!kept("\"at\":\"2026-08-14 10:00:00Z\""));
    assert!(!kept("\"at\":\"2026-08-14T10:00Z\""));
    assert!(!kept("\"at\":\"2026-08-14T10:00:00\""));
    assert!(!kept("\"at\":\"2026-08-14T10:00:00+01\""));
    assert!(!kept(
        "\"at\":\"2026-08-14T10:00:00Z\",\"durationSeconds\":\"x\""
    ));
    assert!(kept(
        "\"at\":\"2026-08-14T10:00:00Z\",\"durationSeconds\":null"
    ));
    assert!(kept(
        "\"at\":\"2026-08-14T10:00:00Z\",\"durationSeconds\":2.0"
    ));
    assert!(!kept(
        "\"at\":\"2026-08-14T10:00:00Z\",\"plannedTaskIds\":[1,\"x\"]"
    ));
    assert!(!kept("\"at\":\"2026-08-14T10:00:00Z\",\"dailyId\":5"));
    assert!(
        parse_lines(
            b"{\"kind\":\"bogus\",\"at\":\"2026-08-14T10:00:00Z\",\"taskId\":1,\"title\":\"a\"}"
        )
        .is_empty()
    );
    assert!(parse_lines(b"{\"kind\":\"completed\",\"at\":\"2026-08-14T10:00:00Z\",\"taskId\":1.5,\"title\":\"a\"}").is_empty());
    assert!(
        parse_lines(b"{\"kind\":\"completed\",\"at\":\"2026-08-14T10:00:00Z\",\"taskId\":1}")
            .is_empty()
    );
    assert_eq!(
        parse_lines(b"{\"kind\":\"completed\",\"at\":\"2026-08-14T10:00:00Z\",\"taskId\":1e2,\"title\":\"a\"}\r")[0].task_id,
        100
    );
}

#[test]
fn the_held_log_reloads_only_when_the_file_changed() {
    let path = scratch("held");
    let log = CoreDayLog::open(path.to_string_lossy().into());
    assert_eq!(log.event_count(), 0);
    log.record(completed(1, "A", at(2026, 8, 14, 10))).unwrap();
    assert!(!log.reload(), "its own append is already held");
    append(&path, &completed(2, "B", at(2026, 8, 14, 11))).unwrap();
    assert!(log.reload());
    assert_eq!(
        log.summary(utc(), at(2026, 8, 14, 20).timestamp_millis())
            .completed
            .len(),
        2
    );
    assert_eq!(
        log.prior_completion_streak(utc(), at(2026, 8, 15, 12).timestamp_millis()),
        1
    );
}

// -- the note ----------------------------------------------------------------

fn day_with(completed_titles: &[&str]) -> DayLogDay {
    DayLogDay {
        key: "2026-08-14".into(),
        day_ms: 0,
        completed: completed_titles
            .iter()
            .enumerate()
            .map(|(index, title)| completed(index as i64 + 1, title, instant(0)))
            .collect(),
        planned_task_ids: vec![],
        unfinished_task_ids: vec![],
        deferred_task_ids: vec![],
        invalidated_task_ids: vec![],
        focus_seconds: 0,
        completed_daily_ids: vec![],
    }
}

fn render(day: &DayLogDay) -> String {
    section(day, &HashMap::new(), &[], "## Log")
}

#[test]
fn the_section_is_wrapped_in_both_markers_and_lists_completions() {
    let text = render(&day_with(&["Ship it", "Write tests"]));
    assert!(text.starts_with(BEGIN_MARKER));
    assert!(text.ends_with(END_MARKER));
    assert!(text.contains("- [x] Ship it"));
    assert!(text.contains("- [x] Write tests"));
    assert!(render(&day_with(&[])).contains("_Nothing recorded._"));
}

#[test]
fn the_section_names_unfinished_and_deferred_tasks() {
    let mut day = day_with(&[]);
    day.planned_task_ids = vec![1, 2];
    day.unfinished_task_ids = vec![1];
    day.deferred_task_ids = vec![2];
    let titles = HashMap::from([(1, "Left over".to_string()), (2, "Pushed back".to_string())]);
    let text = section(&day, &titles, &[], "## Log");
    assert!(text.contains("- [ ] Left over"));
    assert!(text.contains("- Pushed back"));
    assert!(text.contains("1 of 2 planned left"));
}

#[test]
fn focus_time_shows_only_when_there_is_some() {
    let mut day = day_with(&[]);
    day.focus_seconds = 6000;
    assert!(render(&day).contains("1h 40m focused"));
    assert!(!render(&day_with(&[])).contains("focused"));
}

#[test]
fn titles_cannot_restructure_the_note() {
    assert!(render(&day_with(&["# not a heading"])).contains("- [x] \\# not a heading"));
    assert!(
        render(&day_with(&["first line\nsecond line"])).contains("- [x] first line second line")
    );
    assert!(render(&day_with(&["  \n "])).contains("- [x] (untitled)"));
}

#[test]
fn dailies_are_ticked_and_counted_in_the_headline() {
    let mut day = day_with(&[]);
    day.completed_daily_ids = vec!["a".into()];
    let dailies = [
        DayLogDaily {
            id: "a".into(),
            title: "Read".into(),
        },
        DayLogDaily {
            id: "b".into(),
            title: "Run".into(),
        },
    ];
    let text = section(&day, &HashMap::new(), &dailies, "## Log");
    assert_eq!(
        text,
        [
            BEGIN_MARKER,
            "## Log",
            "",
            "**0 done** · **1/2 dailies**",
            "",
            "_Dailies:_",
            "- [x] Read",
            "- [ ] Run",
            "",
            END_MARKER,
        ]
        .join("\n")
    );
}

#[test]
fn focus_durations_read_as_people_say_them() {
    assert_eq!(focus_duration(0), "—");
    assert_eq!(focus_duration(1500), "25m");
    assert_eq!(focus_duration(30), "1m");
    assert_eq!(focus_duration(3600), "1h");
    assert_eq!(focus_duration(6000), "1h 40m");
}
