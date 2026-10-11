//! Ported from `BlockedSectionTests`, `DayArrangementTests` and
//! `DayForecastTests` (Swift) and their Kotlin twins.

use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn the_label_heads_each_groups_blocked_tail() {
    // An outline: a's subtasks drawn between it and its blocked siblings.
    // Rows a, a1, a2, a3, b, c; groups root=0, a=1.
    let groups = vec![0, 1, 1, 1, 0, 0];
    let blocked = vec![false, false, true, true, true, true];
    assert_eq!(blocked_section_labels(groups, blocked), [2, 4]);
}

#[test]
fn nothing_blocked_no_label() {
    assert!(blocked_section_labels(vec![0, 0], vec![false, false]).is_empty());
    assert!(blocked_section_labels(vec![], vec![]).is_empty());
}

#[test]
fn a_blocked_task_above_an_open_one_is_not_labelled() {
    assert!(blocked_section_labels(vec![0, 0, 0], vec![true, false, false]).is_empty());
    assert_eq!(
        blocked_section_labels(vec![0, 0, 0], vec![true, false, true]),
        [2]
    );
}

#[test]
fn a_group_of_only_blocked_tasks_is_labelled_at_its_top() {
    assert_eq!(
        blocked_section_labels(vec![0, 1, 1], vec![false, true, true]),
        [1]
    );
}

#[test]
fn moving_swaps_with_a_neighbour_and_stops_at_the_ends() {
    let order = strings(&["a", "b", "c", "d"]);
    assert_eq!(
        day_arrangement_moving("b".into(), 1, order.clone()),
        Some(strings(&["a", "c", "b", "d"]))
    );
    assert_eq!(
        day_arrangement_moving("c".into(), -1, order.clone()),
        Some(strings(&["a", "c", "b", "d"]))
    );
    assert_eq!(
        day_arrangement_moving("b".into(), 10, order.clone()),
        Some(strings(&["a", "c", "d", "b"]))
    );
    assert_eq!(
        day_arrangement_moving("b".into(), i64::MIN, order.clone()),
        Some(strings(&["b", "a", "c", "d"]))
    );
}

#[test]
fn no_move_is_nothing() {
    let order = strings(&["a", "b", "c", "d"]);
    assert_eq!(day_arrangement_moving("a".into(), -1, order.clone()), None);
    assert_eq!(day_arrangement_moving("d".into(), 1, order.clone()), None);
    assert_eq!(day_arrangement_moving("z".into(), 1, order.clone()), None);
    assert_eq!(day_arrangement_moving("b".into(), 0, order), None);
    assert_eq!(day_arrangement_moving("a".into(), 1, Vec::new()), None);
}

#[test]
fn applying_reorders_only_the_planned_slots() {
    assert_eq!(
        day_arrangement_applying(
            strings(&["b", "a"]),
            strings(&["run", "a", "b", "late"]),
            vec![false, true, true, false]
        ),
        strings(&["run", "b", "a", "late"])
    );
    // An order shorter than the planned slots leaves the rest alone.
    assert_eq!(
        day_arrangement_applying(strings(&["b"]), strings(&["a", "b"]), vec![true, true]),
        strings(&["b", "b"])
    );
}

fn entry(estimate: Option<i64>, logged: i64) -> DayForecastEntry {
    DayForecastEntry {
        estimate_seconds: estimate,
        logged_seconds: logged,
    }
}

const NOW: i64 = 1_778_000_000_000;

#[test]
fn remaining_is_what_each_estimated_task_still_owes() {
    let forecast = day_forecast(vec![entry(Some(3600), 1200), entry(Some(1800), 0)], NOW);
    assert_eq!(forecast.estimated_seconds, 5400);
    assert_eq!(forecast.logged_seconds, 1200);
    assert_eq!(forecast.remaining_seconds, 4200);
    assert_eq!(forecast.unestimated_count, 0);
    assert_eq!(forecast.finish_at_ms, Some(NOW + 4_200_000));
}

#[test]
fn an_overrun_task_contributes_nothing() {
    let forecast = day_forecast(vec![entry(Some(600), 3000), entry(Some(900), 300)], NOW);
    assert_eq!(forecast.remaining_seconds, 600);
    assert_eq!(forecast.logged_seconds, 3300);
}

#[test]
fn unestimated_tasks_are_counted_but_not_forecast() {
    let forecast = day_forecast(
        vec![entry(None, 500), entry(Some(0), 0), entry(Some(1200), 0)],
        NOW,
    );
    assert_eq!(forecast.unestimated_count, 2);
    assert_eq!(forecast.estimated_seconds, 1200);
    assert_eq!(forecast.remaining_seconds, 1200);
    assert_eq!(forecast.logged_seconds, 500);
}

#[test]
fn no_finish_time_when_nothing_remains() {
    let done = day_forecast(vec![entry(Some(600), 600)], NOW);
    assert_eq!(done.remaining_seconds, 0);
    assert_eq!(done.finish_at_ms, None);
    assert_eq!(day_forecast(vec![entry(None, 0)], NOW).finish_at_ms, None);
    let empty = day_forecast(Vec::new(), NOW);
    assert_eq!(empty.finish_at_ms, None);
    assert_eq!(empty.unestimated_count, 0);
    // A negative logged time counts as none.
    assert_eq!(
        day_forecast(vec![entry(Some(60), -30)], NOW).remaining_seconds,
        60
    );
}

fn set(values: &[&str]) -> Vec<String> {
    let mut values = strings(values);
    values.sort();
    values
}

#[test]
fn turning_on_a_place_replaces_the_last_place() {
    let places = strings(&["home", "campus"]);
    assert_eq!(
        focus_context_toggle(
            "campus".into(),
            true,
            strings(&["home", "floor"]),
            places.clone()
        ),
        set(&["campus", "floor"])
    );
    assert_eq!(
        focus_context_toggle(
            "quiet".into(),
            false,
            strings(&["home", "floor"]),
            places.clone()
        ),
        set(&["home", "floor", "quiet"])
    );
    assert_eq!(
        focus_context_toggle(
            "home".into(),
            true,
            strings(&["home", "floor"]),
            places.clone()
        ),
        set(&["floor"])
    );
    assert_eq!(
        focus_context_toggle("floor".into(), false, strings(&["home", "floor"]), places),
        set(&["home"])
    );
}

#[test]
fn restoring_drops_conditions_that_no_longer_exist() {
    assert_eq!(
        focus_context_restore(
            strings(&["home", "gone", "home"]),
            strings(&["home", "floor"])
        ),
        set(&["home"])
    );
    assert!(focus_context_restore(Vec::new(), strings(&["home"])).is_empty());
}

#[test]
fn deferrals_land_on_the_wall_clock_in_the_zone() {
    // 2026-10-12 09:00 UTC.
    let t0 = 1_791_795_600_000;
    let hour = 3_600_000;
    let utc = "UTC".to_string();
    assert_eq!(
        focus_deferral_date(FocusDeferral::AnHour, t0, utc.clone()),
        t0 + hour
    );
    assert_eq!(
        focus_deferral_date(FocusDeferral::ThisAfternoon, t0, utc.clone()),
        t0 + 5 * hour
    );
    assert_eq!(
        focus_deferral_date(FocusDeferral::Tomorrow, t0, utc.clone()),
        t0 + 24 * hour
    );
    assert_eq!(
        focus_deferral_date(FocusDeferral::NextWeek, t0, utc.clone()),
        t0 + 7 * 24 * hour
    );
    // Past two in the afternoon, an hour from now instead.
    let evening = t0 + 8 * hour;
    assert_eq!(
        focus_deferral_date(FocusDeferral::ThisAfternoon, evening, utc),
        evening + hour
    );
    // 09:00 in London (BST, UTC+1) is 08:00 UTC.
    assert_eq!(
        focus_deferral_date(FocusDeferral::Tomorrow, t0, "Europe/London".into()),
        t0 + 23 * hour
    );
}
