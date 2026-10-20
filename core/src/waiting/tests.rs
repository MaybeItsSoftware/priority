use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// 2023-11-14 22:14:00 UTC, on the minute.
const AT: i64 = 1_700_000_040_000;

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
               ('SOURCE-1', 'l', '  Contract signed ', 0, '{T}', '{T}'), ('b', 'l', 'B', 1, '{T}', '{T}');
             INSERT INTO task_metadata (taskId, kanbanColumn, focusRank, updatedAt) VALUES ('SOURCE-1', 'today', 2, '{T}');"
        ))
        .unwrap();
    connection
}

#[test]
fn the_follow_up_id_and_title_match_the_clients() {
    assert_eq!(
        follow_up_task_id("SOURCE-1", AT + 999),
        "20C595E6-139E-5FB7-95C1-7BF5D5A6FAE5"
    );
    assert_eq!(
        follow_up_title(" Contract signed ", Some("  Sam "), 1),
        "Follow up with Sam: Contract signed"
    );
    assert_eq!(
        follow_up_title("Contract signed", Some("  "), 1),
        "Follow up: Contract signed"
    );
    assert_eq!(normalized_tag(Some(&"x".repeat(50))).unwrap().len(), 40);
}

#[test]
fn waiting_files_the_task_and_a_passed_time_makes_its_follow_up_in_the_same_step() {
    let mut connection = workspace();
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(
            tx,
            "SOURCE-1",
            Some(" Sam "),
            Some(AT + 25_000),
            None,
            AT + 60_000,
        )
    })
    .unwrap();
    type Waiting = (String, Option<i64>, String, String, String);
    let (column, rank, tag, at, made): Waiting = connection
        .query_row(
            "SELECT kanbanColumn, focusRank, waitingOn, waitingFollowUpAt, waitingFollowUpTaskId
             FROM task_metadata WHERE taskId = 'SOURCE-1'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(
        (column.as_str(), rank, tag.as_str(), at.as_str()),
        ("waiting-on", None, "Sam", "2023-11-14 22:14:00.000")
    );
    assert_eq!(made, "20C595E6-139E-5FB7-95C1-7BF5D5A6FAE5");
    let follow_up: (String, String, Option<String>, String) = connection
        .query_row(
            "SELECT t.title, t.dueAt, m.kanbanColumn, m.followUpOfTaskId FROM tasks t
             JOIN task_metadata m ON m.taskId = t.id WHERE t.id = ?1",
            [&made],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(
        follow_up,
        (
            "Follow up with Sam: Contract signed".into(),
            "2023-11-14 22:14:00.000".into(),
            Some("today".into()),
            "SOURCE-1".into()
        )
    );
    // Making it again finds it made.
    let tx = connection.transaction().unwrap();
    assert!(!make_due_follow_ups(&tx, None, AT + 120_000).unwrap());
    drop(tx);

    undo(&mut connection).unwrap();
    let left: i64 = connection
        .query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get(0))
        .unwrap();
    assert_eq!(left, 2);
}

#[test]
fn a_future_follow_up_waits_for_its_time() {
    let mut connection = workspace();
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "b", None, Some(AT), None, AT - 60_000)
    })
    .unwrap();
    let tx = connection.transaction().unwrap();
    assert!(!make_due_follow_ups(&tx, None, AT - 1).unwrap());
    assert!(make_due_follow_ups(&tx, None, AT).unwrap());
    tx.commit().unwrap();
    assert!(matches!(
        journalled(&mut connection, "Waiting On", |tx| set_waiting(
            tx, "nope", None, None, None, AT
        )),
        Err(CoreError::MissingTask { .. })
    ));
}

// MARK: - Repeating follow-ups

const LONDON: &str = "Europe/London";

/// A wall-clock time in London, as milliseconds.
fn london(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
    use chrono::TimeZone;
    chrono_tz::Europe::London
        .with_ymd_and_hms(year, month, day, hour, minute, 0)
        .single()
        .unwrap()
        .timestamp_millis()
}

/// Waits on `tag` from Thursday 8 October 2026 14:00, repeating every
/// `every` days, a minute after that time, so the first follow-up is made in
/// the same step. Returns its id.
fn waiting_since_thursday(
    connection: &mut Connection,
    tag: Option<&str>,
    every: Option<u32>,
) -> String {
    let at = london(2026, 10, 8, 14, 0);
    journalled(connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", tag, Some(at), every, at + 60_000)
    })
    .unwrap();
    follow_up_task_id("SOURCE-1", at)
}

fn complete(connection: &mut Connection, id: &str, at: i64) {
    journalled(connection, "Change Status", |tx| {
        crate::tasks::set_status(tx, id, "completed", at, LONDON)
    })
    .unwrap();
}

/// The source's follow-up time, its repeat and its count.
fn source(connection: &Connection) -> (Option<i64>, Option<u32>, u32) {
    connection
        .query_row(
            "SELECT waitingFollowUpAt, waitingFollowUpEveryDays, waitingFollowUpCount
             FROM task_metadata WHERE taskId = 'SOURCE-1'",
            [],
            |row| {
                let at: Option<String> = row.get(0)?;
                Ok((
                    at.as_deref()
                        .and_then(parse_stored)
                        .map(|at| at.timestamp_millis()),
                    row.get(1)?,
                    row.get(2)?,
                ))
            },
        )
        .unwrap()
}

fn title(connection: &Connection, id: &str) -> String {
    connection
        .query_row("SELECT title FROM tasks WHERE id = ?1", [id], |row| {
            row.get(0)
        })
        .unwrap()
}

fn make_due(connection: &mut Connection, now: i64) -> bool {
    let tx = connection.transaction().unwrap();
    let made = make_due_follow_ups(&tx, None, now).unwrap();
    tx.commit().unwrap();
    made
}

#[test]
fn completing_a_follow_up_late_sets_the_next_from_the_completion_at_the_same_time_of_day() {
    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    assert_eq!(
        title(&connection, &first),
        "Follow up with Sam: Contract signed"
    );
    assert_eq!(source(&connection).2, 1);
    // Done on Saturday evening: the next is Tuesday, at two.
    complete(&mut connection, &first, london(2026, 10, 10, 18, 30));
    let next = london(2026, 10, 13, 14, 0);
    assert_eq!(source(&connection), (Some(next), Some(3), 1));
    assert!(!make_due(&mut connection, next - 60_000));
    assert!(make_due(&mut connection, next));
    let second = follow_up_task_id("SOURCE-1", next);
    assert_eq!(
        title(&connection, &second),
        "Follow up #2 with Sam: Contract signed"
    );
    assert_eq!(source(&connection).2, 2);
}

#[test]
fn completing_a_follow_up_before_its_time_steps_from_the_time() {
    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    // A clock behind the one that made it: the time it was for is later.
    complete(&mut connection, &first, london(2026, 10, 8, 9, 0));
    assert_eq!(source(&connection).0, Some(london(2026, 10, 11, 14, 0)));
}

#[test]
fn the_time_of_day_is_kept_across_the_clocks_going_back() {
    let mut connection = workspace();
    let at = london(2026, 10, 24, 14, 0);
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", None, Some(at), Some(2), at)
    })
    .unwrap();
    complete(
        &mut connection,
        &follow_up_task_id("SOURCE-1", at),
        at + 3_600_000,
    );
    // British Summer Time ends on the 25th; 14:00 is still 14:00.
    assert_eq!(source(&connection).0, Some(london(2026, 10, 26, 14, 0)));
    assert_eq!(
        next_follow_up_ms(at, at, 2, chrono_tz::Europe::London) - at,
        2 * 86_400_000 + 3_600_000
    );
}

#[test]
fn a_follow_up_never_done_makes_no_more() {
    let mut connection = workspace();
    waiting_since_thursday(&mut connection, Some("Sam"), Some(1));
    assert!(!make_due(&mut connection, london(2026, 12, 1, 9, 0)));
    let follow_ups: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM task_metadata WHERE followUpOfTaskId = 'SOURCE-1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(follow_ups, 1);
    assert_eq!(source(&connection).2, 1);
}

#[test]
fn a_follow_up_done_once_or_cancelled_sets_nothing() {
    let mut connection = workspace();
    let at = london(2026, 10, 8, 14, 0);
    let first = waiting_since_thursday(&mut connection, Some("Sam"), None);
    complete(&mut connection, &first, at + 3_600_000);
    assert_eq!(source(&connection), (Some(at), None, 1));

    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    journalled(&mut connection, "Change Status", |tx| {
        crate::tasks::set_status(tx, &first, "cancelled", at + 3_600_000, LONDON)
    })
    .unwrap();
    assert_eq!(source(&connection).0, Some(at));
}

#[test]
fn the_chain_stops_when_the_source_is_done_or_stops_waiting() {
    let at = london(2026, 10, 8, 14, 0);
    let later = london(2026, 10, 9, 10, 0);

    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    complete(&mut connection, "SOURCE-1", later);
    complete(&mut connection, &first, later + 60_000);
    assert_eq!(source(&connection).0, Some(at));

    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", None, None, Some(3), later)
    })
    .unwrap();
    assert_eq!(source(&connection), (None, None, 0));
    complete(&mut connection, &first, later + 60_000);
    assert_eq!(source(&connection).0, None);

    // Moved off the board's Waiting on column.
    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    connection
        .execute(
            "UPDATE task_metadata SET kanbanColumn = 'backlog' WHERE taskId = 'SOURCE-1'",
            [],
        )
        .unwrap();
    complete(&mut connection, &first, later);
    assert_eq!(source(&connection).0, Some(at));
}

#[test]
fn an_older_follow_up_or_one_for_a_time_since_changed_sets_nothing() {
    let mut connection = workspace();
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    let moved = london(2026, 10, 20, 9, 0);
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(
            tx,
            "SOURCE-1",
            Some("Sam"),
            Some(moved),
            Some(3),
            london(2026, 10, 9, 8, 0),
        )
    })
    .unwrap();
    complete(&mut connection, &first, london(2026, 10, 9, 10, 0));
    assert_eq!(source(&connection), (Some(moved), Some(3), 1));
}

#[test]
fn naming_someone_else_or_clearing_starts_the_count_again() {
    let at = london(2026, 10, 8, 14, 0);
    let mut connection = workspace();
    waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    let set = |connection: &mut Connection, tag: Option<&str>, at: Option<i64>| {
        journalled(connection, "Waiting On", |tx| {
            set_waiting(tx, "SOURCE-1", tag, at, Some(3), AT)
        })
        .unwrap();
    };
    // The same person, written differently, and a new time: the same spell.
    set(&mut connection, Some(" Sam "), Some(at + 86_400_000));
    assert_eq!(source(&connection).2, 1);
    set(&mut connection, Some("Alex"), Some(at + 86_400_000));
    assert_eq!(source(&connection).2, 0);

    // Naming someone where nobody was named keeps the count.
    let mut connection = workspace();
    waiting_since_thursday(&mut connection, None, Some(3));
    set(&mut connection, Some("Sam"), Some(at + 86_400_000));
    assert_eq!(source(&connection).2, 1);
    // A repeat without a time is dropped.
    set(&mut connection, Some("Sam"), None);
    assert_eq!(source(&connection), (None, None, 1));
}

#[test]
fn undo_takes_back_the_completion_and_the_next_time_together() {
    let mut connection = workspace();
    let at = london(2026, 10, 8, 14, 0);
    let first = waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    complete(&mut connection, &first, london(2026, 10, 10, 18, 30));
    assert_ne!(source(&connection).0, Some(at));
    undo(&mut connection).unwrap();
    assert_eq!(source(&connection).0, Some(at));
    let status: String = connection
        .query_row("SELECT status FROM tasks WHERE id = ?1", [&first], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(status, "open");
}

#[test]
fn a_repeat_outside_a_day_to_a_year_is_refused() {
    let mut connection = workspace();
    for days in [0, 366] {
        assert!(matches!(
            journalled(&mut connection, "Waiting On", |tx| set_waiting(
                tx,
                "SOURCE-1",
                None,
                Some(AT),
                Some(days),
                AT
            )),
            Err(CoreError::InvalidFollowUpRepeat { .. })
        ));
    }
}

#[test]
fn the_chase_label_numbers_the_follow_up_at_the_time_shown() {
    let made = follow_up_task_id("S", AT);
    // Nothing made yet, once: nothing to add.
    assert_eq!(chase_label("S", AT, None, 0, None), None);
    assert_eq!(
        chase_label("S", AT, None, 0, Some(1)).as_deref(),
        Some("every day")
    );
    // The first is made and its time is still shown.
    assert_eq!(
        chase_label("S", AT, Some(&made), 1, Some(3)).as_deref(),
        Some("every 3d")
    );
    // Two made, the third to come.
    assert_eq!(
        chase_label("S", AT, Some("older"), 2, Some(3)).as_deref(),
        Some("#3 · every 3d")
    );
    assert_eq!(
        chase_label("S", AT, Some(&made), 2, None).as_deref(),
        Some("#2")
    );
}

#[test]
fn clearing_only_the_name_keeps_the_spell_and_its_count() {
    let at = london(2026, 10, 8, 14, 0);
    let mut connection = workspace();
    waiting_since_thursday(&mut connection, Some("Sam"), Some(3));
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", None, Some(at), Some(3), AT)
    })
    .unwrap();
    assert_eq!(source(&connection), (Some(at), Some(3), 1));
}

fn placement(connection: &Connection) -> (Option<String>, Option<i64>) {
    connection
        .query_row(
            "SELECT kanbanColumn, focusRank FROM task_metadata WHERE taskId = 'SOURCE-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
}

#[test]
fn clearing_who_and_when_takes_it_out_of_waiting_on() {
    let mut connection = workspace();
    waiting_since_thursday(&mut connection, Some("Sam"), None);
    assert_eq!(placement(&connection).0.as_deref(), Some(WAITING_COLUMN));
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", None, None, None, AT)
    })
    .unwrap();
    assert_eq!(placement(&connection), (None, None));

    // A task that was never waiting stays where it is, its place in the day
    // too, and a repeat on its own files nothing.
    let mut connection = workspace();
    journalled(&mut connection, "Waiting On", |tx| {
        set_waiting(tx, "SOURCE-1", None, None, Some(3), AT)
    })
    .unwrap();
    assert_eq!(placement(&connection), (Some("today".into()), Some(2)));
    assert_eq!(source(&connection), (None, None, 0));
}
