use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// Wednesday 11 March 2026, 10:00 UTC.
const NOW: i64 = 1_773_223_200_000;
const DAY: i64 = 86_400_000;

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, itemKind, createdAt, updatedAt) VALUES
               ('read', 'l', 'Read', 0, 'task', '{T}', '{T}'),
               ('run', 'l', 'Run', 1, 'task', '{T}', '{T}'),
               ('folder', 'l', 'Folder', 2, 'list', '{T}', '{T}');
             -- 'read' every day; 'run' on Mondays only (bit 1 of the mask is Sunday).
             INSERT INTO dailies (id, taskId, activeWeekdaysMask, targetSeconds, sortOrder, createdAt, updatedAt) VALUES
               ('d-read', 'read', 127, 600, 0, '{T}', '{T}'),
               ('d-run', 'run', 2, NULL, 1, '{T}', '{T}'),
               ('d-folder', 'folder', 127, NULL, 2, '{T}', '{T}');
             INSERT INTO daily_contributions (id, dailyId, taskId, dayKey, secondsLogged, completedAt, createdAt)
               VALUES ('c', 'd-read', 'read', '2026-03-11', 600, '2026-03-11 09:00:00.000', '{T}');"
        ))
        .unwrap();
    connection
}

#[test]
fn a_day_shows_its_due_dailies_with_that_days_contribution_and_never_a_list() {
    let connection = workspace();
    let today: Vec<(String, Option<i64>)> = dailies_on(&connection, NOW, "UTC")
        .unwrap()
        .into_iter()
        .map(|d| (d.daily.id, d.contribution.map(|c| c.seconds_logged)))
        .collect();
    assert_eq!(today, [("d-read".to_string(), Some(600))]);
    // Monday 9 March: 'run' is due, and 'read' has nothing logged yet.
    let monday: Vec<(String, bool)> = dailies_on(&connection, NOW - 2 * DAY, "UTC")
        .unwrap()
        .into_iter()
        .map(|d| (d.daily.id, d.contribution.is_some()))
        .collect();
    assert_eq!(
        monday,
        [("d-read".to_string(), false), ("d-run".to_string(), false)]
    );
}

#[test]
fn the_streak_runs_back_until_an_empty_day_and_today_never_breaks_it() {
    let connection = workspace();
    // Today has the contribution; yesterday a completed task; the day before nothing.
    connection
        .execute_batch(
            "UPDATE tasks SET status = 'completed', updatedAt = '2026-03-10 18:00:00.000' WHERE id = 'run';",
        )
        .unwrap();
    let context = completion_context(&connection, NOW, "UTC").unwrap();
    assert_eq!((context.ordinal_today, context.streak_days), (2, 2));
    // A day with nothing yet still counts as the first of the run.
    let later = completion_context(&connection, NOW + 3 * DAY, "UTC").unwrap();
    assert_eq!((later.ordinal_today, later.streak_days), (1, 1));
}

#[test]
fn the_focus_queue_skips_lists_and_missing_tasks() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO focus_sessions (id, startedAt, phase, activeTaskStartedAt, workDurationSeconds, breakDurationSeconds)
               VALUES ('s', '{T}', 'running', '{T}', 1500, 300);
             INSERT INTO focus_queue_items (id, sessionId, taskId, sortOrder, state, createdAt) VALUES
               ('q2', 's', 'run', 1, 'queued', '{T}'),
               ('q1', 's', 'read', 0, 'queued', '{T}'),
               ('q3', 's', 'folder', 2, 'queued', '{T}');"
        ))
        .unwrap();
    let ids: Vec<String> = queue(&connection, "s")
        .unwrap()
        .into_iter()
        .map(|entry| entry.task.id)
        .collect();
    assert_eq!(ids, ["read", "run"]);
    assert_eq!(active_session(&connection).unwrap().unwrap().id, "s");
    assert!(!has_manual_focus_order(&connection).unwrap());
}

#[test]
fn contributions_come_back_oldest_first_for_the_days_asked() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO daily_contributions (id, dailyId, taskId, dayKey, secondsLogged, createdAt)
               VALUES ('older', 'd-read', 'read', '2026-03-09', 60, '{T}');"
        ))
        .unwrap();
    let keys = ["2026-03-11", "2026-03-10", "2026-03-09"].map(String::from);
    let days: Vec<String> = contributions(&connection, "d-read", &keys)
        .unwrap()
        .into_iter()
        .map(|c| c.day_key)
        .collect();
    assert_eq!(days, ["2026-03-09", "2026-03-11"]);
}

#[test]
fn metadata_comes_back_for_the_tasks_that_have_it() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, matrixUrgency, updatedAt)
               VALUES ('read', '[]', '[]', 'today', 2, '{T}');"
        ))
        .unwrap();
    let rows =
        metadata_for_tasks(&connection, &["read".into(), "run".into(), "read".into()]).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(
        (rows[0].kanban_column.as_deref(), rows[0].matrix_urgency),
        (Some("today"), Some(2))
    );
}

#[test]
fn closed_tasks_in_a_window_come_oldest_first_without_lists() {
    let connection = workspace();
    connection
        .execute_batch(
            "UPDATE tasks SET status = 'completed', completedAt = '2026-03-11 09:00:00.000' WHERE id = 'run';
             UPDATE tasks SET status = 'cancelled', completedAt = '2026-03-11 08:00:00.000' WHERE id = 'read';
             UPDATE tasks SET completedAt = '2026-03-11 07:00:00.000' WHERE id = 'folder';",
        )
        .unwrap();
    let ids: Vec<String> = closed_between(&connection, NOW - DAY, NOW)
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(ids, ["read", "run"]);
}

#[test]
fn counts_leave_lists_out_of_the_totals_but_not_the_per_list_figures() {
    let connection = workspace();
    connection
        .execute("UPDATE tasks SET status = 'completed' WHERE id = 'run'", [])
        .unwrap();
    let counts = task_counts(&connection).unwrap();
    assert_eq!((counts.open, counts.completed), (1, 1));
    assert_eq!(counts.by_list.len(), 1);
    assert_eq!(
        (counts.by_list[0].list_id.as_str(), counts.by_list[0].open),
        ("l", 2)
    );
    assert!(kanban_boards(&connection).unwrap().is_empty());
}
