use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

/// Midday on Monday 16 June 2025, UTC.
const NOW: i64 = 1_750_075_200_000;
const HOUR: i64 = 3_600_000;
const T: &str = "2025-06-01 00:00:00.000";

fn candidate(id: &str) -> Candidate {
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

fn today(id: &str) -> Candidate {
    Candidate {
        kanban_column: Some("today".into()),
        ..candidate(id)
    }
}

fn entries(plan: &[DayEntry]) -> Vec<(&str, &str)> {
    plan.iter()
        .map(|e| (e.id.as_str(), e.reason.as_str()))
        .collect()
}

#[test]
fn the_day_is_running_then_planned_then_deadlines_then_starts() {
    let tasks = vec![
        today("planned"),
        Candidate {
            due_at_ms: Some(NOW + HOUR),
            ..candidate("due")
        },
        Candidate {
            due_at_ms: Some(NOW - 24 * HOUR),
            ..candidate("late")
        },
        Candidate {
            start_at_ms: Some(NOW - HOUR),
            ..candidate("starting")
        },
        Candidate {
            due_at_ms: Some(NOW + 24 * HOUR),
            ..candidate("tomorrow")
        },
        Candidate {
            start_at_ms: Some(NOW - 24 * HOUR),
            ..candidate("startedYesterday")
        },
        candidate("someday"),
        candidate("elsewhere"),
    ];
    let day = plan(&tasks, Some("elsewhere"), NOW, "UTC");
    assert_eq!(
        entries(&day),
        [
            ("elsewhere", "running"),
            ("planned", "planned"),
            ("late", "overdue"),
            ("due", "dueToday"),
            ("starting", "startsToday"),
        ]
    );
}

#[test]
fn a_hand_rank_orders_the_column_and_a_task_is_claimed_once() {
    let tasks = vec![
        Candidate {
            sort_order: 3,
            ..today("third")
        },
        Candidate {
            sort_order: 9,
            focus_rank: Some(1),
            ..today("first")
        },
        Candidate {
            sort_order: 1,
            due_at_ms: Some(NOW - 60_000),
            ..today("second")
        },
        Candidate {
            due_date: Some("2025-06-16".into()),
            ..candidate("allDay")
        },
    ];
    let day = plan(&tasks, None, NOW, "UTC");
    assert_eq!(
        entries(&day),
        [
            ("first", "planned"),
            ("second", "planned"),
            ("third", "planned"),
            ("allDay", "dueToday"),
        ]
    );
}

/// Twelve open tasks, two of them in Today and ranked last: the other ten
/// started yesterday, which ranks a task ahead of a commitment without
/// putting it in the day. A short ladder has to reach for the two.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    let mut sql = format!(
        "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
         INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt)
           VALUES ('l', 'w', 'Work', 0, 0, '{T}', '{T}');"
    );
    for index in 0..12 {
        sql += &format!(
            "INSERT INTO tasks (id, listId, title, status, sortOrder, itemKind, createdAt, updatedAt)
               VALUES ('t{index:02}', 'l', 'Task {index}', 'open', {index}, 'task', '{T}', '{T}');
             INSERT INTO task_metadata (taskId, startAt, kanbanColumn, updatedAt)
               VALUES ('t{index:02}', {start}, {column}, '{T}');",
            start = if index >= 10 {
                "NULL"
            } else {
                "'2025-06-15 12:00:00.000'"
            },
            column = if index >= 10 { "'today'" } else { "NULL" },
        );
    }
    connection.execute_batch(&sql).unwrap();
    connection
}

#[test]
fn a_limited_ladder_keeps_its_head_and_the_days_tasks() {
    let connection = workspace();
    let context = FocusContext::default();
    let full = next_up(&connection, NOW, "UTC", &context, None, None).unwrap();
    assert_eq!(full.ranked.len(), 12);
    assert_eq!(full.ranked_count, 12);

    let short = next_up(&connection, NOW, "UTC", &context, None, Some(3)).unwrap();
    let ids: Vec<&str> = short
        .ranked
        .iter()
        .map(|s| s.candidate.id.as_str())
        .collect();
    assert_eq!(ids, ["t00", "t01", "t02", "t10", "t11"]);
    assert_eq!(short.ranked_count, 12);
    assert_eq!(
        entries(&short.day_plan),
        [("t10", "planned"), ("t11", "planned")]
    );
    // Everything else is the full read's, unchanged.
    assert_eq!(short.day_plan, full.day_plan);
    assert_eq!(short.blocked, full.blocked);
    assert_eq!(short.next_evaluation_at_ms, full.next_evaluation_at_ms);
    for scored in &short.ranked {
        assert!(full.ranked.contains(scored));
    }
}
