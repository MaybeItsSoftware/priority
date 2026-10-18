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
fn blocked_and_buried_sections_are_labelled_apart() {
    // Roots a, b (blocked), c (buried, with subtask c1), d (buried and
    // blocked); a's subtasks a1 then a2 (buried). Groups root=0, a=1, c=2.
    // Rows: a, a1, a2, b, c, c1, d.
    let groups = vec![0, 1, 1, 0, 0, 2, 0];
    let blocked = vec![false, false, false, true, false, false, true];
    let buried = vec![false, false, true, false, true, false, true];
    let labels = sibling_section_labels(groups, blocked, buried);
    assert_eq!(labels.blocked, [3]);
    assert_eq!(labels.buried, [2, 4]);
}

#[test]
fn with_nothing_buried_the_blocked_labels_are_as_before() {
    let groups = vec![0, 1, 1, 1, 0, 0];
    let blocked = vec![false, false, true, true, true, true];
    let labels = sibling_section_labels(groups.clone(), blocked.clone(), vec![false; 6]);
    assert_eq!(labels.blocked, blocked_section_labels(groups, blocked));
    assert!(labels.buried.is_empty());
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

#[test]
fn a_single_step_wraps_and_a_page_stops_at_the_ends() {
    assert_eq!(cursor_step(0, -1, 5), 4);
    assert_eq!(cursor_step(4, 1, 5), 0);
    assert_eq!(cursor_step(2, 1, 5), 3);
    assert_eq!(cursor_step(2, -8, 5), 0);
    assert_eq!(cursor_step(2, 8, 5), 4);
    assert_eq!(cursor_step(0, 1, 1), 0);
    assert_eq!(cursor_step(0, -1, 1), 0);
    assert_eq!(cursor_step(3, 1, 0), 0);
}

fn titles() -> Vec<String> {
    strings(&[
        "Call Sam",
        "buy milk",
        "— cancel gym",
        "Écrire",
        "2026 plan",
        "check post",
    ])
}

#[test]
fn find_walks_forward_and_back_and_wraps() {
    assert_eq!(vim_find(titles(), Some(0), "c".into(), true), Some(2));
    assert_eq!(vim_find(titles(), Some(2), "C".into(), true), Some(5));
    assert_eq!(vim_find(titles(), Some(5), "c".into(), true), Some(0));
    assert_eq!(vim_find(titles(), Some(0), "c".into(), false), Some(5));
    assert_eq!(vim_find(titles(), Some(5), "c".into(), false), Some(2));
    assert_eq!(vim_find(titles(), None, "c".into(), true), Some(0));
    assert_eq!(vim_find(titles(), None, "c".into(), false), Some(5));
}

#[test]
fn find_ignores_leading_punctuation_case_and_accents() {
    assert_eq!(vim_find(titles(), Some(0), "e".into(), true), Some(3));
    assert_eq!(vim_find(titles(), Some(0), "É".into(), true), Some(3));
    assert_eq!(vim_find(titles(), Some(0), "2".into(), true), Some(4));
    assert_eq!(vim_find(titles(), Some(1), "b".into(), true), Some(1));
}

#[test]
fn find_with_nothing_to_find_is_nothing() {
    assert_eq!(vim_find(titles(), Some(0), "z".into(), true), None);
    assert_eq!(vim_find(titles(), Some(0), " ".into(), true), None);
    assert_eq!(vim_find(Vec::new(), None, "a".into(), true), None);
    assert_eq!(vim_find(titles(), None, "ab".into(), true), None);
}

// Outline drops: ported from the iPhone's `OutlineDropPlannerTests`, the
// rule's oracle, and Android's `ListsShapingTest` cases on the same tree.

fn drop_row(depth: u32, parent: Option<&str>) -> OutlineDropRow {
    OutlineDropRow {
        depth,
        parent_id: parent.map(str::to_string),
        list_id: "L".to_string(),
    }
}

fn flat(count: usize) -> Vec<OutlineDropRow> {
    (0..count).map(|_| drop_row(0, None)).collect()
}

/// a, a1, a2, a2x, b: a2x is a2's child.
fn nested() -> Vec<OutlineDropRow> {
    vec![
        drop_row(0, None),
        drop_row(1, Some("a")),
        drop_row(1, Some("a")),
        drop_row(2, Some("a2")),
        drop_row(0, None),
    ]
}

#[test]
fn dropping_before_a_sibling_places_it_before_that_sibling() {
    assert_eq!(
        outline_drop_plan(flat(3), 2, 0),
        Some(OutlineDropPlan::Before { target: 0 })
    );
}

#[test]
fn dropping_after_the_last_sibling_moves_it_to_the_end() {
    assert_eq!(
        outline_drop_plan(flat(3), 0, 3),
        Some(OutlineDropPlan::ToEnd)
    );
}

#[test]
fn dropping_among_another_parents_children_reparents() {
    // a, a1, a2, b: b dropped in front of a2 joins a, before a2.
    let rows = vec![
        drop_row(0, None),
        drop_row(1, Some("a")),
        drop_row(1, Some("a")),
        drop_row(0, None),
    ];
    assert_eq!(
        outline_drop_plan(rows, 3, 2),
        Some(OutlineDropPlan::Reparent {
            anchor: 2,
            before: true
        })
    );
}

#[test]
fn dropping_a_row_onto_itself_does_nothing() {
    assert_eq!(outline_drop_plan(flat(2), 0, 1), None);
    // Nor anywhere inside the subtree it carries.
    assert_eq!(outline_drop_plan(nested(), 2, 4), None);
    assert_eq!(outline_drop_plan(nested(), 1, 2), None);
}

#[test]
fn a_parent_moves_with_its_subtree() {
    assert_eq!(
        outline_drop_plan(nested(), 4, 0),
        Some(OutlineDropPlan::Before { target: 0 })
    );
    assert_eq!(
        outline_drop_plan(nested(), 0, 5),
        Some(OutlineDropPlan::ToEnd)
    );
    assert_eq!(
        outline_drop_plan(nested(), 2, 1),
        Some(OutlineDropPlan::Before { target: 1 })
    );
}

#[test]
fn after_a_sibling_whose_children_follow_it_goes_before_the_next_sibling() {
    // a, a1, a2, a2x, b, c: c dropped straight after a, in front of a's
    // first child, follows its sibling a, so it goes before a's next
    // sibling, b, rather than in among a's children.
    let mut rows = nested();
    rows.push(drop_row(0, None));
    assert_eq!(
        outline_drop_plan(rows.clone(), 5, 1),
        Some(OutlineDropPlan::Before { target: 4 })
    );
    assert_eq!(
        outline_drop_plan(rows, 5, 4),
        Some(OutlineDropPlan::Before { target: 4 })
    );
}

#[test]
fn a_drop_below_a_deeper_row_joins_the_row_aboves_parent() {
    // a1 (a's) dropped after a2x and before b: b is not as deep as a2x, so it
    // joins a2x's parent, a2, at the end.
    assert_eq!(
        outline_drop_plan(nested(), 1, 4),
        Some(OutlineDropPlan::Reparent {
            anchor: 3,
            before: false
        })
    );
}

#[test]
fn rows_of_another_list_are_not_siblings() {
    let rows = vec![
        drop_row(0, None),
        OutlineDropRow {
            depth: 0,
            parent_id: None,
            list_id: "M".to_string(),
        },
        drop_row(0, None),
    ];
    // Dropped between its sibling and the other list's root, it follows its
    // sibling: the end of its own level, not a place in the other list.
    assert_eq!(
        outline_drop_plan(rows.clone(), 2, 1),
        Some(OutlineDropPlan::ToEnd)
    );
    // In front of the other list's root with nothing above, it joins that
    // list's level, before that root: X, a, c with a dropped first.
    let rows = vec![rows[1].clone(), rows[0].clone(), rows[2].clone()];
    assert_eq!(
        outline_drop_plan(rows, 1, 0),
        Some(OutlineDropPlan::Reparent {
            anchor: 0,
            before: true
        })
    );
}

#[test]
fn out_of_range_source_plans_nothing() {
    assert_eq!(outline_drop_plan(flat(2), 5, 0), None);
}
