use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, redo, undo};
use crate::records::{children, tasks_in_lists};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

/// Inbox `l` with roots a, b, c, d (in that order) and a child `a1` of `a`;
/// list `m` holds `x`.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt) VALUES
               ('l', 'w', 'Inbox', 0, '{T}', '{T}'),
               ('m', 'w', 'Other', 1, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('a', 'l', NULL, 'A', 0, '{T}', '{T}'),
               ('a1', 'l', 'a', 'A1', 0, '{T}', '{T}'),
               ('b', 'l', NULL, 'B', 1, '{T}', '{T}'),
               ('c', 'l', NULL, 'C', 2, '{T}', '{T}'),
               ('d', 'l', NULL, 'D', 3, '{T}', '{T}'),
               ('x', 'm', NULL, 'X', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn add(connection: &mut Connection, task: &str, blocker: &str) -> Result<bool, CoreError> {
    journalled(connection, "Add Blocker", |tx| {
        add_blocker(tx, task, blocker, 1_000)
    })
}

fn roots(connection: &Connection) -> Vec<String> {
    children(connection, "l", None)
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect()
}

fn complete(connection: &Connection, id: &str) {
    connection
        .execute(
            "UPDATE tasks SET status = 'completed', completedAt = ?2 WHERE id = ?1",
            params![id, T],
        )
        .unwrap();
}

fn edges(connection: &Connection) -> i64 {
    connection
        .query_row("SELECT COUNT(*) FROM task_dependencies", [], |r| r.get(0))
        .unwrap()
}

#[test]
fn a_blocked_task_sinks_below_its_siblings_and_comes_back_when_the_blocker_is_done() {
    let mut connection = workspace();
    assert!(add(&mut connection, "a", "x").unwrap());
    assert_eq!(roots(&connection), ["b", "c", "d", "a"]);
    assert_eq!(blocked_task_ids(&connection).unwrap(), ["a"]);
    assert!(is_blocked(&connection, "a").unwrap());

    // Every list's rows carry the same order, so each client's tree does.
    let rows: Vec<String> = tasks_in_lists(&connection, &["l".into()])
        .unwrap()
        .into_iter()
        .filter(|t| t.parent_task_id.is_none())
        .map(|t| t.id)
        .collect();
    assert_eq!(rows, ["b", "c", "d", "a"]);

    complete(&connection, "x");
    assert_eq!(roots(&connection), ["a", "b", "c", "d"]);
    assert!(blocked_task_ids(&connection).unwrap().is_empty());
    assert!(!is_blocked(&connection, "a").unwrap());
}

#[test]
fn a_cancelled_blocker_does_not_block_and_a_finished_task_is_not_blocked() {
    let mut connection = workspace();
    add(&mut connection, "b", "c").unwrap();
    connection
        .execute("UPDATE tasks SET status = 'cancelled' WHERE id = 'c'", [])
        .unwrap();
    assert!(blocked_task_ids(&connection).unwrap().is_empty());
    connection
        .execute("UPDATE tasks SET status = 'open' WHERE id = 'c'", [])
        .unwrap();
    complete(&connection, "b");
    assert!(blocked_task_ids(&connection).unwrap().is_empty());
}

#[test]
fn several_blocked_siblings_keep_their_own_order_at_the_bottom() {
    let mut connection = workspace();
    add(&mut connection, "c", "x").unwrap();
    add(&mut connection, "a", "x").unwrap();
    assert_eq!(roots(&connection), ["b", "d", "a", "c"]);
}

#[test]
fn self_dependencies_and_cycles_are_refused() {
    let mut connection = workspace();
    assert!(matches!(
        add(&mut connection, "a", "a"),
        Err(CoreError::DependencyCycle)
    ));
    add(&mut connection, "a", "b").unwrap();
    add(&mut connection, "b", "c").unwrap();
    assert!(matches!(
        add(&mut connection, "c", "a"),
        Err(CoreError::DependencyCycle)
    ));
    assert!(matches!(
        add(&mut connection, "b", "a"),
        Err(CoreError::DependencyCycle)
    ));
    assert!(matches!(
        add(&mut connection, "a", "nope"),
        Err(CoreError::MissingTask { .. })
    ));
    assert_eq!(edges(&connection), 2);
}

#[test]
fn adding_the_same_blocker_twice_changes_nothing_and_removing_it_reports_whether_it_was_there() {
    let mut connection = workspace();
    assert!(add(&mut connection, "a", "b").unwrap());
    assert!(!add(&mut connection, "a", "b").unwrap());
    assert_eq!(edges(&connection), 1);
    let id: String = connection
        .query_row("SELECT id FROM task_dependencies", [], |r| r.get(0))
        .unwrap();
    assert_eq!(id, dependency_id("a", "b"));
    assert!(
        journalled(&mut connection, "Remove Blocker", |tx| remove_blocker(
            tx, "a", "b"
        ))
        .unwrap()
    );
    assert!(
        !journalled(&mut connection, "Remove Blocker", |tx| remove_blocker(
            tx, "a", "b"
        ))
        .unwrap()
    );
}

#[test]
fn the_id_is_the_same_on_every_device_and_differs_by_direction() {
    let forward = dependency_id("A", "B");
    assert_eq!(forward, dependency_id("A", "B"));
    assert_ne!(forward, dependency_id("B", "A"));
    assert_eq!(forward.len(), 36);
    assert_eq!(&forward[14..15], "5");
    assert_eq!(forward, forward.to_uppercase());
}

#[test]
fn blockers_and_blocked_tasks_are_listed_open_first() {
    let mut connection = workspace();
    add(&mut connection, "a", "b").unwrap();
    add(&mut connection, "a", "x").unwrap();
    add(&mut connection, "c", "x").unwrap();
    complete(&connection, "b");
    let ids = |rows: Vec<TaskRow>| rows.into_iter().map(|t| t.id).collect::<Vec<_>>();
    assert_eq!(ids(blockers(&connection, "a").unwrap()), ["x", "b"]);
    assert_eq!(ids(blocked_by(&connection, "x").unwrap()), ["a", "c"]);
    assert!(blockers(&connection, "d").unwrap().is_empty());
}

#[test]
fn adding_and_removing_a_blocker_are_undoable_steps() {
    let mut connection = workspace();
    add(&mut connection, "a", "b").unwrap();
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Add Blocker")
    );
    assert_eq!(edges(&connection), 0);
    assert_eq!(
        redo(&mut connection).unwrap().as_deref(),
        Some("Add Blocker")
    );
    assert_eq!(edges(&connection), 1);
    journalled(&mut connection, "Remove Blocker", |tx| {
        remove_blocker(tx, "a", "b")
    })
    .unwrap();
    assert_eq!(edges(&connection), 0);
    undo(&mut connection).unwrap();
    assert_eq!(edges(&connection), 1);
}

#[test]
fn deleting_either_task_removes_the_edge_and_undoing_the_delete_restores_it() {
    let mut connection = workspace();
    add(&mut connection, "b", "a1").unwrap();
    journalled(&mut connection, "Delete Task", |tx| {
        crate::tasks::delete_task(tx, "a")
    })
    .unwrap();
    assert_eq!(edges(&connection), 0);
    undo(&mut connection).unwrap();
    assert_eq!(edges(&connection), 1);
    assert_eq!(blocked_task_ids(&connection).unwrap(), ["b"]);

    journalled(&mut connection, "Delete Task", |tx| {
        crate::tasks::delete_task(tx, "b")
    })
    .unwrap();
    assert_eq!(edges(&connection), 0);
}

#[test]
fn moving_a_task_among_its_siblings_follows_the_order_drawn() {
    let mut connection = workspace();
    add(&mut connection, "b", "x").unwrap();
    // Drawn: a, c, d, b. Moving d up passes c, not the sunk b.
    journalled(&mut connection, "Reorder Task", |tx| {
        crate::tasks::move_task_within_siblings(tx, "d", -1, 2_000)
    })
    .unwrap();
    assert_eq!(roots(&connection), ["a", "d", "c", "b"]);
}

#[test]
fn a_blocked_task_is_not_a_next_up_candidate() {
    let mut connection = workspace();
    let ids = |connection: &Connection| -> Vec<String> {
        crate::focus::candidates(connection, 5_000, "UTC")
            .unwrap()
            .into_iter()
            .map(|c| c.id)
            .collect()
    };
    assert!(ids(&connection).contains(&"c".to_string()));
    add(&mut connection, "c", "d").unwrap();
    assert!(!ids(&connection).contains(&"c".to_string()));
    assert!(ids(&connection).contains(&"d".to_string()));
    complete(&connection, "d");
    assert!(ids(&connection).contains(&"c".to_string()));
}

#[test]
fn the_edges_are_recorded_for_sync() {
    let mut connection = workspace();
    connection
        .execute("UPDATE sync_control SET recording = 1 WHERE id = 0", [])
        .unwrap();
    add(&mut connection, "a", "b").unwrap();
    let id = dependency_id("a", "b");
    let outbox: Vec<(String, String, String)> = {
        let mut statement = connection
            .prepare("SELECT tableName, rowId, operation FROM sync_outbox ORDER BY seq")
            .unwrap();
        statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(
        outbox,
        [(
            "task_dependencies".to_string(),
            id.clone(),
            "insert".to_string()
        )]
    );
    journalled(&mut connection, "Delete Task", |tx| {
        crate::tasks::delete_task(tx, "b")
    })
    .unwrap();
    let deleted: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE tableName = 'task_dependencies' AND rowId = ?1 AND operation = 'delete')",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(deleted);
}

#[test]
fn a_database_without_the_table_reads_as_having_no_dependencies() {
    let mut connection = Connection::open_in_memory().unwrap();
    crate::schema::migrate_through(&mut connection, Some("v20_waiting_follow_ups")).unwrap();
    assert!(blocked_task_ids(&connection).unwrap().is_empty());
    assert!(!is_blocked(&connection, "a").unwrap());
    assert_eq!(blocked_last(&connection).unwrap(), NOT_BLOCKED);
    assert!(children(&connection, "l", None).unwrap().is_empty());
}
