use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// 2026-03-08 23:30 UTC: still the 8th in London, already the 9th in Tokyo.
const LATE: i64 = 1_773_012_600_000;

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
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt) VALUES
               ('read', 'l', 'Read', 0, '{T}', '{T}'), ('walk', 'l', 'Walk', 1, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn daily(
    connection: &Connection,
    id: &str,
) -> (
    i64,
    Option<i64>,
    Option<String>,
    Option<i64>,
    Option<String>,
) {
    connection
        .query_row(
            "SELECT activeWeekdaysMask, intervalDays, intervalAnchor, targetSeconds, archivedAt FROM dailies WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap()
}

#[test]
fn days_are_masked_and_keyed_as_the_clients_did() {
    assert_eq!(weekday_mask(&[1, 2, 3, 4, 5, 6, 7]), 127);
    assert_eq!(weekday_mask(&[2, 6, 9]), 0b10_0010);
    assert_eq!(day_key(LATE, "Europe/London"), "2026-03-08");
    assert_eq!(day_key(LATE, "Asia/Tokyo"), "2026-03-09");
}

#[test]
fn making_a_daily_twice_gives_back_the_first_and_restores_it() {
    let mut connection = workspace();
    let id = journalled(&mut connection, "Make Daily", |tx| {
        make_daily(
            tx,
            "read",
            &[2, 3, 4, 5, 6],
            Some(2),
            Some(600),
            1_700_000_000_000,
        )
    })
    .unwrap();
    assert_eq!(
        daily(&connection, &id),
        (
            62,
            Some(2),
            Some("2023-11-14 22:13:20.000".into()),
            Some(600),
            None
        )
    );
    journalled(&mut connection, "Archive Daily", |tx| {
        archive_daily(tx, "read", 1_700_000_000_000)
    })
    .unwrap();
    assert!(daily(&connection, &id).4.is_some());
    let again = journalled(&mut connection, "Make Daily", |tx| {
        make_daily(tx, "read", &[1], None, None, 1)
    })
    .unwrap();
    assert_eq!(again, id);
    assert_eq!(daily(&connection, &id).3, Some(600));
    assert!(daily(&connection, &id).4.is_none());
    assert!(matches!(
        journalled(&mut connection, "Make Daily", |tx| make_daily(
            tx,
            "nope",
            &[1],
            None,
            None,
            1
        )),
        Err(CoreError::MissingTask { .. })
    ));
}

#[test]
fn editing_a_daily_clamps_the_interval_and_can_clear_it_and_the_target() {
    let mut connection = workspace();
    let id = journalled(&mut connection, "Make Daily", |tx| {
        make_daily(tx, "walk", &[1, 7], None, Some(300), 5)
    })
    .unwrap();
    let edit = DailyEdit {
        weekdays: Some(vec![]),
        set_interval: true,
        interval_days: Some(900),
        ..Default::default()
    };
    journalled(&mut connection, "Edit Daily", |tx| {
        update_daily(tx, &id, &edit, 1_700_000_000_000)
    })
    .unwrap();
    assert_eq!(
        daily(&connection, &id),
        (
            65,
            Some(366),
            Some("2023-11-14 22:13:20.000".into()),
            Some(300),
            None
        )
    );
    let clear = DailyEdit {
        set_interval: true,
        set_target: true,
        ..Default::default()
    };
    journalled(&mut connection, "Edit Daily", |tx| {
        update_daily(tx, &id, &clear, 9)
    })
    .unwrap();
    assert_eq!(daily(&connection, &id), (65, None, None, None, None));
    journalled(&mut connection, "Edit Daily", |tx| {
        update_daily(tx, "nope", &clear, 9)
    })
    .unwrap();
}

#[test]
fn logging_accumulates_on_the_local_day_and_clearing_keeps_the_time() {
    let mut connection = workspace();
    let id = journalled(&mut connection, "Make Daily", |tx| {
        make_daily(tx, "read", &[1, 2, 3, 4, 5, 6, 7], None, None, 1)
    })
    .unwrap();
    let first = journalled(&mut connection, "Log Daily", |tx| {
        log_contribution(tx, &id, 600, false, LATE, "Europe/London")
    })
    .unwrap();
    let second = journalled(&mut connection, "Log Daily", |tx| {
        log_contribution(tx, &id, -5, true, LATE + 60_000, "Europe/London")
    })
    .unwrap();
    assert_eq!(first, second);
    let row = |c: &Connection| -> (String, i64, Option<String>) {
        c.query_row(
            "SELECT dayKey, secondsLogged, completedAt FROM daily_contributions WHERE id = ?1",
            [&first],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap()
    };
    assert_eq!(
        row(&connection),
        (
            "2026-03-08".into(),
            600,
            Some("2026-03-08 23:31:00.000".into())
        )
    );

    journalled(&mut connection, "Clear Daily", |tx| {
        clear_contribution(tx, &id, LATE, "Europe/London")
    })
    .unwrap();
    assert_eq!(row(&connection), ("2026-03-08".into(), 600, None));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Clear Daily")
    );
    assert!(row(&connection).2.is_some());

    // The same moment is already the next day in Tokyo: a separate row.
    let tokyo = journalled(&mut connection, "Log Daily", |tx| {
        log_contribution(tx, &id, 0, true, LATE, "Asia/Tokyo")
    })
    .unwrap();
    assert_ne!(tokyo, first);
    assert!(matches!(
        journalled(&mut connection, "Log Daily", |tx| log_contribution(
            tx, "nope", 0, true, LATE, "UTC"
        )),
        Err(CoreError::MissingDaily { .. })
    ));
}
