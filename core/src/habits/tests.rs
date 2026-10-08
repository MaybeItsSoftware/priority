use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// Wednesday 11 March 2026, 10:00 UTC.
const WEDNESDAY: i64 = 1_773_223_200_000;
const DAY: i64 = 86_400_000;

fn day(text: &str) -> NaiveDate {
    NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap()
}

fn rule() -> Rule {
    Rule {
        weekdays: vec![],
        interval_days: None,
        anchor: day("2026-03-02"),
        drops_at_day_end: true,
        expiry: Expiry::Never,
        placement: "today".into(),
    }
}

#[test]
fn a_rule_is_scheduled_from_its_anchor_by_weekday_or_interval() {
    let weekdays = Rule {
        weekdays: vec![2, 4, 6],
        ..rule()
    };
    assert!(is_scheduled(&weekdays, day("2026-03-02")));
    assert!(!is_scheduled(&weekdays, day("2026-03-03")));
    assert!(!is_scheduled(&weekdays, day("2026-02-23")));
    let every_three = Rule {
        interval_days: Some(3),
        ..rule()
    };
    assert!(is_scheduled(&every_three, day("2026-03-08")));
    assert!(!is_scheduled(&every_three, day("2026-03-09")));
}

#[test]
fn a_missed_day_is_carried_only_when_it_does_not_drop() {
    let every_three = Rule {
        interval_days: Some(3),
        ..rule()
    };
    assert_eq!(
        appearance(&every_three, day("2026-03-06"), None, false),
        None
    );
    let carried = Rule {
        drops_at_day_end: false,
        ..every_three.clone()
    };
    assert_eq!(
        appearance(&carried, day("2026-03-06"), None, false),
        Some(Appearance {
            column: "today".into(),
            due_day: day("2026-03-05"),
            is_carried_over: true
        })
    );
    assert_eq!(
        appearance(&carried, day("2026-03-06"), Some(day("2026-03-05")), false),
        None
    );
    assert_eq!(
        appearance(&carried, day("2026-03-05"), Some(day("2026-03-05")), false),
        None
    );
    let ends = Rule {
        expiry: Expiry::On(day("2026-03-05")),
        ..carried
    };
    assert_eq!(appearance(&ends, day("2026-03-05"), None, false), None);
    let with_source = Rule {
        expiry: Expiry::WhenSourceCompleted,
        ..rule()
    };
    assert!(is_expired(&with_source, day("2026-03-05"), true));
}

#[test]
fn only_the_habits_own_column_or_none_is_managed() {
    let showing = Appearance {
        column: "today".into(),
        due_day: day("2026-03-05"),
        is_carried_over: false,
    };
    assert_eq!(
        reconciled_column(None, Some(&showing), "today"),
        Some(Some("today".into()))
    );
    assert_eq!(
        reconciled_column(Some("doing"), Some(&showing), "today"),
        None
    );
    assert_eq!(reconciled_column(Some("today"), None, "today"), Some(None));
    assert_eq!(reconciled_column(Some("doing"), None, "today"), None);
}

#[test]
fn the_habits_list_id_matches_the_clients() {
    assert_eq!(habits_list_id("w"), "7A8CA1E8-5CB0-519C-932A-995A2B6D5028");
}

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt)
               VALUES ('drums', 'l', 'Learn drums', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn draft() -> HabitDraft {
    HabitDraft {
        title: " Practise ".into(),
        weekdays: vec![1, 2, 3, 4, 5, 6, 7],
        interval_days: None,
        drops_at_day_end: true,
        estimate_seconds: Some(1_200),
        expiry_rule: "source".into(),
        expires_at_ms: None,
        placement: "today".into(),
        source_task_id: Some("drums".into()),
    }
}

fn column(connection: &Connection, task_id: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
        .flatten()
}

#[test]
fn a_new_habit_lives_in_the_habits_list_and_lands_in_its_column_today() {
    let mut connection = workspace();
    let daily_id = journalled(&mut connection, "New Habit", |tx| {
        save_habit(tx, &draft(), None, WEDNESDAY, "Europe/London")
    })
    .unwrap();
    let (task_id, list_id, title, anchor, rule): (String, String, String, String, String) = connection
        .query_row(
            "SELECT d.taskId, t.listId, t.title, d.intervalAnchor, d.expiryRule FROM dailies d JOIN tasks t ON t.id = d.taskId WHERE d.id = ?1",
            [&daily_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    assert_eq!(list_id, habits_list_id("w"));
    assert_eq!(title, "Practise");
    assert_eq!(anchor, "2026-03-11 00:00:00.000");
    assert_eq!(rule, "source");
    assert_eq!(column(&connection, &task_id).as_deref(), Some("today"));

    // Moving the habit to another column takes its card along on save.
    let moved = HabitDraft {
        placement: "this-week".into(),
        ..draft()
    };
    journalled(&mut connection, "Edit Habit", |tx| {
        save_habit(tx, &moved, Some(&task_id), WEDNESDAY, "Europe/London")
    })
    .unwrap();
    assert_eq!(column(&connection, &task_id).as_deref(), Some("this-week"));

    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Edit Habit")
    );
    assert_eq!(column(&connection, &task_id).as_deref(), Some("today"));
}

#[test]
fn the_pass_archives_a_habit_whose_source_is_done_and_takes_its_card_out() {
    let mut connection = workspace();
    let daily_id = journalled(&mut connection, "New Habit", |tx| {
        save_habit(tx, &draft(), None, WEDNESDAY, "UTC")
    })
    .unwrap();
    let task_id: String = connection
        .query_row(
            "SELECT taskId FROM dailies WHERE id = ?1",
            [&daily_id],
            |row| row.get(0),
        )
        .unwrap();
    connection
        .execute(
            "UPDATE tasks SET status = 'completed' WHERE id = 'drums'",
            [],
        )
        .unwrap();
    let tx = connection.transaction().unwrap();
    assert!(reconcile_habits(&tx, WEDNESDAY + DAY, "UTC").unwrap());
    tx.commit().unwrap();
    let archived: Option<String> = connection
        .query_row(
            "SELECT archivedAt FROM dailies WHERE id = ?1",
            [&daily_id],
            |row| row.get(0),
        )
        .unwrap();
    assert!(archived.is_some());
    assert_eq!(column(&connection, &task_id), None);
    let tx = connection.transaction().unwrap();
    assert!(!reconcile_habits(&tx, WEDNESDAY + 2 * DAY, "UTC").unwrap());
}
