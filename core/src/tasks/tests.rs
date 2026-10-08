use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

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
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('p', 'l', NULL, 'Parent', 0, '{T}', '{T}'),
               ('c', 'l', 'p', 'Child', 0, '{T}', '{T}'),
               ('g', 'l', 'c', 'Grandchild', 0, '{T}', '{T}'),
               ('o', 'l', NULL, 'Other', 1, '{T}', '{T}');
             INSERT INTO task_metadata (taskId, updatedAt) VALUES ('c', '{T}');"
        ))
        .unwrap();
    connection
}

fn ids(connection: &Connection) -> Vec<String> {
    let mut statement = connection
        .prepare("SELECT id FROM tasks ORDER BY id")
        .unwrap();
    statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn deleting_a_task_takes_its_subtree_and_one_undo_brings_it_all_back() {
    let mut connection = workspace();
    let deleted = journalled(&mut connection, "Delete Task", |tx| delete_task(tx, "p")).unwrap();
    assert_eq!(
        deleted,
        DeletedTask {
            id: "p".into(),
            title: "Parent".into(),
            subtasks_deleted: 2
        }
    );
    assert_eq!(ids(&connection), ["o"]);
    let metadata: i64 = connection
        .query_row("SELECT COUNT(*) FROM task_metadata", [], |row| row.get(0))
        .unwrap();
    assert_eq!(metadata, 0);

    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Delete Task")
    );
    assert_eq!(ids(&connection), ["c", "g", "o", "p"]);
}

#[test]
fn deleting_a_missing_task_changes_nothing_and_records_no_step() {
    let mut connection = workspace();
    let error =
        journalled(&mut connection, "Delete Task", |tx| delete_task(tx, "nope")).unwrap_err();
    assert!(matches!(error, CoreError::MissingTask { ref id } if id == "nope"));
    assert_eq!(ids(&connection).len(), 4);
    let steps: i64 = connection
        .query_row("SELECT COUNT(*) FROM change_log", [], |row| row.get(0))
        .unwrap();
    assert_eq!(steps, 0);
}
