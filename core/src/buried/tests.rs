use std::collections::HashSet;

use rusqlite::{Connection, params};

use super::*;
use crate::journal::journalled;
use crate::records::{children, tasks_in_lists};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// Long after any clock this runs under: a start that is still to come.
const LATER: &str = "2999-01-01 09:00:00.000";
/// Long before: a start that has arrived.
const EARLIER: &str = "2000-01-01 09:00:00.000";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Inbox `l` with roots a, b, c, d, e (in that order) and a child `a1` of
/// `a`; list `m` holds `x`, which nothing finishes.
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
               ('e', 'l', NULL, 'E', 4, '{T}', '{T}'),
               ('x', 'm', NULL, 'X', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn start(connection: &Connection, id: &str, at: &str) {
    connection
        .execute(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, startAt, updatedAt)
             VALUES (?1, '[]', '[]', ?2, ?3)
             ON CONFLICT(taskId) DO UPDATE SET startAt = excluded.startAt",
            params![id, at, T],
        )
        .unwrap();
}

fn block(connection: &mut Connection, id: &str) {
    journalled(connection, "Add Blocker", |tx| {
        crate::dependencies::add_blocker(tx, id, "x", 1_000)
    })
    .unwrap();
}

fn roots(connection: &Connection) -> Vec<String> {
    children(connection, "l", None)
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect()
}

fn step(connection: &mut Connection, id: &str, offset: i32) {
    journalled(connection, "Move", |tx| {
        crate::tasks::move_task_within_siblings(tx, id, offset, now_ms())
    })
    .unwrap();
}

#[test]
fn a_buried_task_sinks_below_its_blocked_siblings_and_keeps_its_subtasks() {
    let mut connection = workspace();
    start(&connection, "a", LATER);
    block(&mut connection, "c");
    assert_eq!(roots(&connection), ["b", "d", "e", "c", "a"]);
    // Its subtasks are still beneath it, and every list read agrees.
    let rows: Vec<(String, Option<String>)> = tasks_in_lists(&connection, &["l".into()])
        .unwrap()
        .into_iter()
        .map(|t| (t.id, t.parent_task_id))
        .collect();
    let top: Vec<&str> = rows
        .iter()
        .filter(|(_, parent)| parent.is_none())
        .map(|(id, _)| id.as_str())
        .collect();
    assert_eq!(top, ["b", "d", "e", "c", "a"]);
    assert!(rows.contains(&("a1".to_string(), Some("a".to_string()))));
    assert_eq!(buried_task_ids(&connection, now_ms()).unwrap(), ["a"]);
}

#[test]
fn a_buried_task_that_is_also_blocked_is_in_the_buried_section() {
    let mut connection = workspace();
    block(&mut connection, "a");
    block(&mut connection, "c");
    start(&connection, "a", LATER);
    start(&connection, "b", LATER);
    // Open d, e; blocked c; buried a and b, in their own order.
    assert_eq!(roots(&connection), ["d", "e", "c", "a", "b"]);
}

#[test]
fn a_start_that_has_arrived_puts_the_task_back_in_its_place() {
    let connection = workspace();
    start(&connection, "b", LATER);
    assert_eq!(roots(&connection), ["a", "c", "d", "e", "b"]);
    start(&connection, "b", EARLIER);
    assert_eq!(roots(&connection), ["a", "b", "c", "d", "e"]);
    assert!(buried_task_ids(&connection, now_ms()).unwrap().is_empty());
}

#[test]
fn a_finished_task_with_a_start_to_come_is_not_buried() {
    let connection = workspace();
    start(&connection, "b", LATER);
    connection
        .execute("UPDATE tasks SET status = 'completed' WHERE id = 'b'", [])
        .unwrap();
    assert_eq!(roots(&connection), ["a", "b", "c", "d", "e"]);
    assert!(buried_task_ids(&connection, now_ms()).unwrap().is_empty());
}

#[test]
fn a_start_written_with_a_t_is_read_too() {
    let connection = workspace();
    start(&connection, "b", "2999-01-01T09:00:00.000Z");
    assert_eq!(roots(&connection), ["a", "c", "d", "e", "b"]);
}

#[test]
fn a_step_counts_only_the_siblings_in_the_same_section() {
    let mut connection = workspace();
    // Drawn: a, c, e, then blocked d, then buried b.
    block(&mut connection, "d");
    start(&connection, "b", LATER);
    assert_eq!(roots(&connection), ["a", "c", "e", "d", "b"]);

    // e is the last open task: down passes neither the blocked nor the buried.
    step(&mut connection, "e", 1);
    assert_eq!(roots(&connection), ["a", "c", "e", "d", "b"]);
    // a down passes c, the open task drawn beside it, not the buried b.
    step(&mut connection, "a", 1);
    assert_eq!(roots(&connection), ["c", "a", "e", "d", "b"]);
    // The buried task has no peer: up does nothing.
    step(&mut connection, "b", -1);
    assert_eq!(roots(&connection), ["c", "a", "e", "d", "b"]);

    // Burying changed no number, and no move renumbered it last: when it
    // starts it is back where it was among the tasks nobody moved, before c.
    start(&connection, "b", EARLIER);
    assert_eq!(roots(&connection), ["b", "c", "a", "e", "d"]);
}

#[test]
fn an_indent_goes_under_the_sibling_drawn_above() {
    let mut connection = workspace();
    // Drawn: a, c, d, e, then buried b. c's neighbour above is a, not b.
    start(&connection, "b", LATER);
    journalled(&mut connection, "Indent", |tx| {
        crate::tasks::indent_task(tx, "c", now_ms())
    })
    .unwrap();
    let under_a: HashSet<String> = children(&connection, "l", Some("a"))
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect();
    assert!(under_a.contains("c"));
    assert_eq!(roots(&connection), ["a", "d", "e", "b"]);
}

#[test]
fn the_combined_board_draws_buried_cards_last() {
    let connection = workspace();
    start(&connection, "a", LATER);
    let cards: Vec<String> =
        crate::board::cards_of(&connection, &["l".into()], None, &HashSet::new())
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
    // A combined board's cards are every open task, subtasks too, in
    // outline order: the buried one's subtask goes down with it.
    assert_eq!(cards, ["b", "c", "d", "e", "a", "a1"]);
}
