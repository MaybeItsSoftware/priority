//! The Swift and Kotlin suites these rules came from (`PeriodicScheduleTests`,
//! `HabitPolicyTests`, `WaitingFollowUpTests`, `TaktDailiesTests` and their
//! Kotlin namesakes), ported through the exported surface.

use chrono::{TimeZone, Utc};

use super::*;

const DAY: i64 = 86_400_000;

fn ms(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, 0)
        .unwrap()
        .timestamp_millis()
}

fn utc() -> String {
    "UTC".into()
}

// MARK: - Periodic schedules

/// Wednesday 2025-09-24, 09:00 UTC.
const WEDNESDAY: i64 = 1_758_704_400_000;

fn cadence(raw: &str) -> PeriodicCadence {
    periodic_cadence(raw.into()).unwrap()
}

#[test]
fn reads_the_phrases_the_app_already_stores() {
    assert_eq!(cadence("daily"), PeriodicCadence::Days { count: 1 });
    assert_eq!(cadence(" Weekly "), PeriodicCadence::Weeks { count: 1 });
    assert_eq!(cadence("weekdays"), PeriodicCadence::Weekdays);
    assert_eq!(cadence("every 3 days"), PeriodicCadence::Days { count: 3 });
    assert_eq!(
        cadence("every 2 weeks"),
        PeriodicCadence::Weeks { count: 2 }
    );
    assert_eq!(
        cadence("every monday"),
        PeriodicCadence::Weekday { weekday: 2 }
    );
    assert_eq!(cadence("friday"), PeriodicCadence::Weekday { weekday: 6 });
    assert_eq!(cadence("sun"), PeriodicCadence::Weekday { weekday: 1 });
    assert_eq!(cadence("sat"), PeriodicCadence::Weekday { weekday: 7 });
}

#[test]
fn refuses_what_it_cannot_schedule() {
    for raw in [
        "",
        "   ",
        "every so often",
        "every 0 days",
        "every 2 months",
    ] {
        assert_eq!(periodic_cadence(raw.into()), None, "{raw:?}");
    }
}

#[test]
fn steps_one_cadence_forward_and_keeps_the_time_of_day() {
    let next = periodic_next_occurrence(cadence("every 3 days"), WEDNESDAY, None, utc());
    assert_eq!(next, Some(WEDNESDAY + 3 * DAY));
}

#[test]
fn weekdays_skip_the_weekend() {
    let friday = WEDNESDAY + 2 * DAY;
    let next = periodic_next_occurrence(cadence("weekdays"), friday, None, utc());
    assert_eq!(next, Some(friday + 3 * DAY));
}

#[test]
fn a_named_weekday_lands_on_that_day() {
    let next = periodic_next_occurrence(cadence("every monday"), WEDNESDAY, None, utc());
    assert_eq!(next, Some(WEDNESDAY + 5 * DAY));
}

#[test]
fn catches_up_past_a_gap_without_breaking_the_rhythm() {
    let long_ago = WEDNESDAY - 20 * DAY;
    let next = periodic_next_occurrence(cadence("every 3 days"), long_ago, Some(WEDNESDAY), utc())
        .unwrap();
    assert!(next > WEDNESDAY);
    assert_eq!((next - long_ago) % (3 * DAY), 0);
    assert!(next - long_ago <= 24 * DAY);
}

#[test]
fn not_before_never_pulls_an_occurrence_backwards() {
    let next = periodic_next_occurrence(cadence("daily"), WEDNESDAY, Some(WEDNESDAY - DAY), utc());
    assert_eq!(next, Some(WEDNESDAY + DAY));
}

#[test]
fn a_cadence_that_cannot_land_is_none_rather_than_a_panic() {
    let huge = PeriodicCadence::Days { count: u32::MAX };
    assert_eq!(periodic_next_occurrence(huge, WEDNESDAY, None, utc()), None);
    let nonsense = PeriodicCadence::Weekday { weekday: 9 };
    assert_eq!(
        periodic_next_occurrence(nonsense, WEDNESDAY, None, utc()),
        None
    );
}

// MARK: - Habits

/// 2026-10-05 is a Monday.
fn day(value: u32) -> i64 {
    ms(2026, 10, value, 12, 0)
}

fn rule(anchor: i64) -> HabitRuleSpec {
    HabitRuleSpec {
        weekdays: (1..=7).collect(),
        interval_days: None,
        anchor_ms: anchor,
        drops_at_day_end: true,
        expiry_rule: "never".into(),
        expires_at_ms: None,
        placement: "today".into(),
    }
}

#[test]
fn scheduled_days_follow_weekdays_and_intervals_from_the_anchor() {
    let weekdays = HabitRuleSpec {
        weekdays: vec![2, 4],
        ..rule(day(5))
    };
    assert!(habit_is_scheduled(weekdays.clone(), day(5), utc()));
    assert!(!habit_is_scheduled(weekdays.clone(), day(6), utc()));
    assert!(habit_is_scheduled(weekdays, day(7), utc()));

    let weekly = HabitRuleSpec {
        interval_days: Some(7),
        ..rule(day(5))
    };
    assert!(habit_is_scheduled(weekly.clone(), day(12), utc()));
    assert!(!habit_is_scheduled(weekly.clone(), day(13), utc()));
    assert!(
        !habit_is_scheduled(weekly, ms(2026, 9, 28, 12, 0), utc()),
        "nothing before the day it was made"
    );
}

#[test]
fn expiry_rules() {
    let mut habit = rule(ms(2026, 10, 1, 12, 0));
    assert!(!habit_is_expired(habit.clone(), day(30), true, utc()));

    habit.expiry_rule = "source".into();
    assert!(!habit_is_expired(habit.clone(), day(30), false, utc()));
    assert!(habit_is_expired(habit.clone(), day(30), true, utc()));

    habit.expiry_rule = "date".into();
    habit.expires_at_ms = Some(ms(2026, 10, 10, 18, 0));
    assert!(!habit_is_expired(habit.clone(), day(9), false, utc()));
    assert!(habit_is_expired(
        habit.clone(),
        ms(2026, 10, 10, 1, 0),
        false,
        utc()
    ));
    assert_eq!(habit_appearance(habit, day(11), None, false, utc()), None);
}

#[test]
fn a_date_expiry_without_a_date_and_an_unknown_rule_are_never() {
    let mut habit = rule(day(1));
    habit.expiry_rule = "date".into();
    assert!(!habit_is_expired(habit.clone(), day(30), true, utc()));
    habit.expiry_rule = "nonsense".into();
    assert!(!habit_is_expired(habit, day(30), true, utc()));
}

#[test]
fn a_due_habit_appears_in_its_column_until_it_is_done() {
    let habit = HabitRuleSpec {
        placement: "this-week".into(),
        ..rule(day(5))
    };
    assert_eq!(
        habit_appearance(habit.clone(), day(6), Some(day(5)), false, utc()),
        Some(HabitShowing {
            column: "this-week".into(),
            due_day_ms: ms(2026, 10, 6, 0, 0),
            is_carried_over: false,
        })
    );
    assert_eq!(
        habit_appearance(habit, day(6), Some(ms(2026, 10, 6, 9, 0)), false, utc()),
        None
    );
}

#[test]
fn a_missed_day_is_dropped_when_the_habit_disappears_at_the_end_of_the_day() {
    let habit = HabitRuleSpec {
        interval_days: Some(7),
        ..rule(day(5))
    };
    assert!(habit_appearance(habit.clone(), day(5), None, false, utc()).is_some());
    assert_eq!(habit_appearance(habit, day(6), None, false, utc()), None);
}

#[test]
fn a_missed_day_is_carried_until_done_when_it_does_not_disappear() {
    let habit = HabitRuleSpec {
        interval_days: Some(7),
        drops_at_day_end: false,
        placement: "waiting-on".into(),
        ..rule(day(5))
    };
    assert_eq!(
        habit_appearance(habit.clone(), day(8), None, false, utc()),
        Some(HabitShowing {
            column: "waiting-on".into(),
            due_day_ms: ms(2026, 10, 5, 0, 0),
            is_carried_over: true,
        })
    );
    assert_eq!(
        habit_last_scheduled_day(habit.clone(), day(8), utc()),
        Some(ms(2026, 10, 5, 0, 0))
    );
    assert_eq!(
        habit_appearance(habit.clone(), day(9), Some(day(8)), false, utc()),
        None
    );
    assert!(habit_appearance(habit, day(13), Some(day(8)), false, utc()).is_some());
}

#[test]
fn an_expired_habit_never_appears() {
    let habit = HabitRuleSpec {
        drops_at_day_end: false,
        expiry_rule: "source".into(),
        ..rule(day(5))
    };
    assert_eq!(habit_appearance(habit, day(6), None, true, utc()), None);
}

#[test]
fn the_reconciled_column_only_manages_the_habits_own_column() {
    let change = |current: Option<&str>, appearance: Option<&str>| {
        habit_reconciled_column(
            current.map(String::from),
            appearance.map(String::from),
            "today".into(),
        )
        .map(|change| change.column)
    };
    assert_eq!(change(None, Some("today")), Some(Some("today".into())));
    assert_eq!(change(Some("today"), Some("today")), None);
    assert_eq!(change(Some("in-progress"), Some("today")), None);
    assert_eq!(change(Some("today"), None), Some(None));
    assert_eq!(change(Some("backlog"), None), None);
    assert_eq!(change(None, None), None);
}

#[test]
fn the_habits_list_id_is_the_one_every_client_pinned() {
    assert_eq!(
        habit_list_id("WORKSPACE".into()),
        "CBC20FA7-CBCE-52A3-A729-95DCFFC9C2A4"
    );
}

// MARK: - Waiting follow-ups

fn waiting(at: Option<i64>) -> WaitingState {
    WaitingState {
        task_id: "SOURCE".into(),
        title: "Contract signed".into(),
        is_open: true,
        column: Some("waiting-on".into()),
        waiting_on: Some("Sam".into()),
        follow_up_at_ms: at,
        made_follow_up_task_id: None,
    }
}

/// Tuesday 6 October 2026, 10:00 UTC.
fn now() -> i64 {
    ms(2026, 10, 6, 10, 0)
}

#[test]
fn a_follow_up_is_due_at_its_time_while_the_task_is_still_waiting() {
    let at = ms(2026, 10, 6, 9, 0);
    let plan = waiting_due_follow_up(waiting(Some(at)), now()).unwrap();
    assert_eq!(plan.title, "Follow up with Sam: Contract signed");
    assert_eq!(plan.due_at_ms, at);
    assert_eq!(plan.source_task_id, "SOURCE");
    assert_eq!(plan.task_id, waiting_follow_up_task_id("SOURCE".into(), at));
    assert!(waiting_due_follow_up(waiting(Some(now())), now()).is_some());
}

#[test]
fn nothing_is_due_before_the_time_or_without_one() {
    assert_eq!(
        waiting_due_follow_up(waiting(Some(ms(2026, 10, 6, 11, 0))), now()),
        None
    );
    assert_eq!(waiting_due_follow_up(waiting(None), now()), None);
}

#[test]
fn a_task_that_left_waiting_or_closed_gets_no_follow_up() {
    let at = Some(ms(2026, 10, 6, 9, 0));
    for state in [
        WaitingState {
            column: Some("today".into()),
            ..waiting(at)
        },
        WaitingState {
            column: None,
            ..waiting(at)
        },
        WaitingState {
            is_open: false,
            ..waiting(at)
        },
    ] {
        assert_eq!(waiting_due_follow_up(state, now()), None);
    }
}

#[test]
fn a_follow_up_is_made_once_per_time_set() {
    let at = ms(2026, 10, 6, 9, 0);
    let made = waiting_follow_up_task_id("SOURCE".into(), at);
    let done = WaitingState {
        made_follow_up_task_id: Some(made.clone()),
        ..waiting(Some(at))
    };
    assert_eq!(waiting_due_follow_up(done, now()), None);
    let later = WaitingState {
        made_follow_up_task_id: Some(made.clone()),
        ..waiting(Some(ms(2026, 10, 6, 9, 30)))
    };
    let plan = waiting_due_follow_up(later, now()).unwrap();
    assert_ne!(plan.task_id, made);
}

#[test]
fn the_title_names_the_tag_only_when_there_is_one() {
    assert_eq!(
        waiting_follow_up_title("Invoice paid".into(), None),
        "Follow up: Invoice paid"
    );
    assert_eq!(
        waiting_follow_up_title("Invoice paid".into(), Some("  ".into())),
        "Follow up: Invoice paid"
    );
    assert_eq!(
        waiting_follow_up_title("Invoice paid".into(), Some(" Legal ".into())),
        "Follow up with Legal: Invoice paid"
    );
}

#[test]
fn the_follow_up_id_is_deterministic_and_uuid_shaped() {
    let at = 1_791_291_600_000;
    let id = waiting_follow_up_task_id("6F1C2A9E-0000-4000-8000-000000000001".into(), at);
    assert_eq!(id, "D2D0E044-BDD3-5ED3-95C6-C687611541D1");
    assert_eq!(
        id,
        waiting_follow_up_task_id("6F1C2A9E-0000-4000-8000-000000000001".into(), at + 400)
    );
}

/// Swift clips by grapheme cluster, so the core does: a family emoji is one
/// character, not seven scalars.
#[test]
fn a_tag_is_clipped_by_the_characters_a_person_sees() {
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    let long: String = std::iter::repeat_n(family, 45).collect();
    let clipped = waiting_normalized_tag(Some(long)).unwrap();
    assert_eq!(clipped, std::iter::repeat_n(family, 40).collect::<String>());
    assert_eq!(waiting_normalized_tag(Some(" \n ".into())), None);
    assert_eq!(waiting_normalized_tag(None), None);
    assert_eq!(
        waiting_normalized_tag(Some("  Sam ".into())),
        Some("Sam".into())
    );
}

// MARK: - Dailies

/// 2026-08-14 is a Friday, 2026-08-15 a Saturday.
fn on(day: u32, hour: u32) -> i64 {
    ms(2026, 8, day, hour, 0)
}

fn plugin_due(weekdays: &[u32], interval: Option<i64>, anchor: i64, day: i64) -> bool {
    plugin_daily_is_due(
        false,
        weekdays.to_vec(),
        interval,
        anchor,
        day,
        "GMT".into(),
    )
}

#[test]
fn a_plugin_daily_follows_its_weekdays() {
    let all: Vec<u32> = (1..=7).collect();
    assert!(plugin_due(&all, None, on(1, 10), on(15, 10)));
    assert!(plugin_due(&[2, 3, 4, 5, 6], None, on(1, 10), on(14, 10)));
    assert!(!plugin_due(&[2, 3, 4, 5, 6], None, on(1, 10), on(15, 10)));
    assert!(!plugin_daily_is_due(
        true,
        all,
        None,
        on(1, 10),
        on(14, 10),
        utc()
    ));
}

#[test]
fn a_plugin_daily_cycle_runs_both_ways_from_its_anchor() {
    let anchor = on(14, 10);
    assert!(plugin_due(&[], Some(3), anchor, on(14, 10)));
    assert!(!plugin_due(&[], Some(3), anchor, on(15, 10)));
    assert!(!plugin_due(&[], Some(3), anchor, on(16, 10)));
    assert!(plugin_due(&[], Some(3), anchor, on(17, 10)));
    assert!(plugin_due(&[], Some(3), anchor, on(20, 10)));
    assert!(plugin_due(&[], Some(2), anchor, on(12, 10)));
    assert!(!plugin_due(&[], Some(2), anchor, on(13, 10)));
    // Only the days count, not the times within them.
    assert!(plugin_due(&[], Some(2), on(14, 22), on(16, 9)));
    assert!(!plugin_due(&[], Some(2), on(14, 22), on(17, 9)));
    assert!(plugin_due(&[], Some(1), anchor, on(15, 10)));
}

#[test]
fn a_workspace_daily_cycle_starts_at_its_anchor() {
    let anchor = on(14, 10);
    let due = |mask: i64, interval: Option<i64>, day: i64| {
        workspace_daily_is_due(mask, interval, anchor, day, utc())
    };
    assert!(due(127, Some(3), on(17, 10)));
    assert!(!due(127, Some(3), on(15, 10)));
    assert!(!due(127, Some(3), on(11, 10)), "nothing before the anchor");
    assert!(!due(127, Some(1), on(13, 10)));
    // Monday to Friday: Friday the 14th yes, Saturday the 15th no.
    assert!(due(0b011_1110, None, on(14, 10)));
    assert!(!due(0b011_1110, None, on(15, 10)));
}
