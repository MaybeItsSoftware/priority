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

const NOW: i64 = 1_700_000_000_123;

/// Inbox `l`: Parent(p) > Child(c) > Grandchild(g); Other(o).
fn children(connection: &Connection, list: &str, parent: Option<&str>) -> Vec<String> {
    let mut statement = connection
        .prepare(
            "SELECT id FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2 ORDER BY sortOrder, createdAt, id",
        )
        .unwrap();
    statement
        .query_map(rusqlite::params![list, parent], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn second_list(connection: &Connection) {
    connection
        .execute_batch(&format!(
            "INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('m', 'w', 'Work', 1, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('x', 'm', NULL, 'Existing', 0, '{T}', '{T}');"
        ))
        .unwrap();
}

#[test]
fn moving_a_task_to_another_list_carries_its_subtree_and_goes_last() {
    let mut connection = workspace();
    second_list(&connection);
    journalled(&mut connection, "Move Task", |tx| {
        move_task(tx, "p", "m", None, false, NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "m", None), ["x", "p"]);
    let moved: i64 = connection
        .query_row("SELECT COUNT(*) FROM tasks WHERE listId = 'm'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(moved, 4);
    undo(&mut connection).unwrap();
    assert_eq!(children(&connection, "l", None), ["p", "o"]);
}

#[test]
fn a_task_cannot_move_into_itself_below_itself_or_under_another_lists_task() {
    let mut connection = workspace();
    second_list(&connection);
    for parent in ["p", "c", "g", "x"] {
        let list = if parent == "x" { "m" } else { "l" };
        let wrong_list = if parent == "x" { "l" } else { list };
        assert!(matches!(
            journalled(&mut connection, "Move Task", |tx| move_task(
                tx,
                "p",
                wrong_list,
                Some(parent),
                false,
                NOW
            )),
            Err(CoreError::InvalidTaskMove)
        ));
    }
    assert!(matches!(
        journalled(&mut connection, "Move Task", |tx| move_task(
            tx, "p", "nope", None, false, NOW
        )),
        Err(CoreError::MissingList { .. })
    ));
}

#[test]
fn moving_to_a_lists_visible_root_puts_the_task_under_the_wrapper() {
    let mut connection = workspace();
    second_list(&connection);
    connection
        .execute(
            "UPDATE task_lists SET visibleRootTaskId = 'x' WHERE id = 'm'",
            [],
        )
        .unwrap();
    journalled(&mut connection, "Move Task", |tx| {
        move_task(tx, "o", "m", None, true, NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "m", Some("x")), ["o"]);
}

#[test]
fn indenting_and_outdenting_walk_a_task_down_a_level_and_back() {
    let mut connection = workspace();
    journalled(&mut connection, "Indent Task", |tx| {
        indent_task(tx, "o", NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["p"]);
    assert_eq!(children(&connection, "l", Some("p")), ["c", "o"]);

    journalled(&mut connection, "Outdent Task", |tx| {
        outdent_task(tx, "o", NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["p", "o"]);
    // One change for the outdented task, and one for each sibling renumbered.
    let changes: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM change_log WHERE label = 'Outdent Task' AND rowId = 'o'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(changes, 1);

    let before: i64 = connection
        .query_row(
            "SELECT COUNT(DISTINCT groupId) FROM change_log",
            [],
            |row| row.get(0),
        )
        .unwrap();
    journalled(&mut connection, "Indent Task", |tx| {
        indent_task(tx, "p", NOW)
    })
    .unwrap();
    journalled(&mut connection, "Outdent Task", |tx| {
        outdent_task(tx, "p", NOW)
    })
    .unwrap();
    let after: i64 = connection
        .query_row(
            "SELECT COUNT(DISTINCT groupId) FROM change_log",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(after, before);
}

#[test]
fn nudging_dropping_and_placing_reorder_siblings() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt)
               VALUES ('z', 'l', 'Last', 2, '{T}', '{T}');"
        ))
        .unwrap();
    journalled(&mut connection, "Reorder Task", |tx| {
        move_task_within_siblings(tx, "z", -1, NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["p", "z", "o"]);
    journalled(&mut connection, "Reorder Task", |tx| {
        move_task_to_start(tx, "o", NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["o", "p", "z"]);
    journalled(&mut connection, "Reorder Task", |tx| {
        move_task_before(tx, "z", "o", Some("today"), NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["z", "o", "p"]);
    let column: Option<String> = connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = 'z'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(column.as_deref(), Some("today"));
    journalled(&mut connection, "Reorder Task", |tx| {
        place_task_at(tx, "z", 99, NOW)
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), ["o", "p", "z"]);
    assert!(matches!(
        journalled(&mut connection, "Reorder Task", |tx| move_task_before(
            tx, "z", "c", None, NOW
        )),
        Err(CoreError::InvalidTaskMove)
    ));
}
