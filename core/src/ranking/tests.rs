use super::*;

const NOW: i64 = 1_773_223_200_000; // Wednesday 11 March 2026, 10:00 UTC
const HOUR: i64 = 3_600_000;

fn task(id: &str) -> Candidate {
    Candidate {
        id: id.into(),
        title: id.into(),
        is_daily_due_today: false,
        due_at_ms: None,
        start_at_ms: None,
        matrix_urgency: None,
        matrix_importance: None,
        priority: None,
        estimate_seconds: None,
        kanban_column: None,
        focus_rank: None,
        sort_order: 0,
        created_at_ms: NOW - 24 * HOUR,
        due_date: None,
        requirement_groups: vec![],
        logged_seconds: 0,
        minimum_block_seconds: None,
        requires_single_sitting: false,
        daily_remaining_seconds: None,
        daily_unavailable: None,
    }
}

fn ids(ranking: &Ranking) -> Vec<&str> {
    ranking
        .ranked
        .iter()
        .map(|s| s.candidate.id.as_str())
        .collect()
}

#[test]
fn late_work_comes_first_then_today_then_the_rest_by_importance() {
    let late = Candidate {
        due_at_ms: Some(NOW - 2 * 24 * HOUR - HOUR),
        ..task("late")
    };
    let today = Candidate {
        due_at_ms: Some(NOW + 3 * HOUR),
        ..task("today")
    };
    let important = Candidate {
        matrix_importance: Some(2),
        ..task("important")
    };
    let plain = task("plain");
    let ranking = evaluate(
        &[plain, important, today, late],
        NOW,
        "UTC",
        &FocusContext::default(),
    );
    assert_eq!(ids(&ranking), ["late", "today", "important", "plain"]);
    assert_eq!(ranking.ranked[0].reason, "overdue");
    assert_eq!(
        ranking.ranked[0].explanation.as_deref(),
        Some("overdue by 2 days")
    );
    assert_eq!(ranking.ranked[2].reason, "importance");
    assert_eq!(ranking.next_evaluation_at_ms, Some(NOW + 3 * HOUR));
}

#[test]
fn a_pin_places_free_work_but_does_not_jump_a_tier() {
    let pinned = Candidate {
        focus_rank: Some(0),
        sort_order: 9,
        ..task("pinned")
    };
    let first = Candidate {
        sort_order: 1,
        ..task("first")
    };
    let late = Candidate {
        due_at_ms: Some(NOW - HOUR),
        ..task("late")
    };
    let ranking = evaluate(&[first, pinned, late], NOW, "UTC", &FocusContext::default());
    assert_eq!(ids(&ranking), ["late", "pinned", "first"]);
}

#[test]
fn blocked_work_is_kept_apart_with_its_reasons() {
    let later = Candidate {
        start_at_ms: Some(NOW + HOUR),
        ..task("later")
    };
    let ranking = evaluate(&[later, task("now")], NOW, "UTC", &FocusContext::default());
    assert_eq!(ids(&ranking), ["now"]);
    assert_eq!(
        ranking.blocked[0].reasons,
        [Unavailable::StartsLater { at_ms: NOW + HOUR }]
    );
}
