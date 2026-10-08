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
        follow_up_title(" Contract signed ", Some("  Sam ")),
        "Follow up with Sam: Contract signed"
    );
    assert_eq!(
        follow_up_title("Contract signed", Some("  ")),
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
        set_waiting(tx, "b", None, Some(AT), AT - 60_000)
    })
    .unwrap();
    let tx = connection.transaction().unwrap();
    assert!(!make_due_follow_ups(&tx, None, AT - 1).unwrap());
    assert!(make_due_follow_ups(&tx, None, AT).unwrap());
    tx.commit().unwrap();
    assert!(matches!(
        journalled(&mut connection, "Waiting On", |tx| set_waiting(
            tx, "nope", None, None, AT
        )),
        Err(CoreError::MissingTask { .. })
    ));
}
