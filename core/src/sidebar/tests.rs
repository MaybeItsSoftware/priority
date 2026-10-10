use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

/// Nesting, a nested list inside a nested list, an archived nested list with
/// a list inside it, a finished list, a visible root that is itself a list,
/// a task whose parent is not in its list, and an empty list.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt) VALUES
               ('l', 'w', 'Work', 0, 0, '{T}', '{T}'),
               ('o', 'w', 'Home', 1, 0, '{T}', '{T}'),
               ('empty', 'w', 'Empty', 2, 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, itemKind, archivedAt, createdAt, updatedAt) VALUES
               ('project', 'l', NULL, 'Project', 'open', 0, 'task', NULL, '{T}', '{T}'),
               ('step', 'l', 'project', 'Step', 'completed', 0, 'task', NULL, '{T}', '{T}'),
               ('reading', 'l', NULL, 'Reading', 'open', 1, 'list', NULL, '{T}', '{T}'),
               ('papers', 'l', 'reading', 'Papers', 'open', 0, 'list', NULL, '{T}', '{T}'),
               ('paper', 'l', 'papers', 'Paper A', 'open', 0, 'task', NULL, '{T}', '{T}'),
               ('old', 'l', NULL, 'Old', 'open', 2, 'list', '{T}', '{T}', '{T}'),
               ('older', 'l', 'old', 'Older', 'open', 0, 'list', NULL, '{T}', '{T}'),
               ('closed', 'l', NULL, 'Closed', 'completed', 3, 'list', NULL, '{T}', '{T}'),
               ('root', 'o', NULL, 'Wrapper', 'open', 0, 'list', NULL, '{T}', '{T}'),
               ('inner', 'o', 'root', 'Inner', 'open', 0, 'list', NULL, '{T}', '{T}');
             UPDATE task_lists SET visibleRootTaskId = 'root' WHERE id = 'o';"
        ))
        .unwrap();
    connection
}

#[test]
fn nested_lists_count_only_lists_above_them_and_hide_beneath_an_archived_one() {
    let connection = workspace();
    let ids = ["l", "o", "empty"].map(str::to_string);
    let index = sidebar_index(&connection, &ids).unwrap();
    let nested: Vec<(&str, i64)> = index
        .nested_lists
        .iter()
        .map(|item| (item.task.id.as_str(), item.depth))
        .collect();
    // The visible root is not a nested list, and does not deepen its children.
    assert_eq!(
        nested,
        [("reading", 0), ("papers", 1), ("closed", 0), ("inner", 0)]
    );
    assert_eq!(index.nested_lists[0].task.title, "Reading");
    let archived: Vec<&str> = index
        .archived_nested_lists
        .iter()
        .map(|task| task.id.as_str())
        .collect();
    assert_eq!(archived, ["old"]);
    // Every task the walk reaches counts, finished or hidden.
    let counts: Vec<(&str, i64)> = index
        .task_counts
        .iter()
        .map(|c| (c.list_id.as_str(), c.count))
        .collect();
    assert_eq!(counts, [("l", 8), ("o", 2), ("empty", 0)]);
}

#[test]
fn counts_match_the_outline() {
    let connection = workspace();
    let index = sidebar_index(&connection, &["l".to_string()]).unwrap();
    assert_eq!(
        index.task_counts[0].count,
        records::outline(&connection, "l", None).unwrap().len() as i64
    );
}

#[test]
fn open_counts_take_only_open_doable_tasks_and_credit_every_nested_list_above() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, itemKind, archivedAt, createdAt, updatedAt) VALUES
               ('shut', 'l', 'closed', 'Under a finished list', 'open', 0, 'task', NULL, '{T}', '{T}'),
               ('stale', 'l', 'older', 'Under an archived list', 'open', 0, 'task', NULL, '{T}', '{T}'),
               ('loose', 'o', 'inner', 'Beneath the wrapper', 'open', 0, 'task', NULL, '{T}', '{T}');"
        ))
        .unwrap();
    let ids = ["l", "o", "empty"].map(str::to_string);
    assert!(
        sidebar_index(&connection, &ids)
            .unwrap()
            .open_counts
            .is_empty()
    );
    let index = sidebar_index_with_open_counts(&connection, &ids).unwrap();
    assert_eq!(
        index.nested_lists,
        sidebar_index(&connection, &ids).unwrap().nested_lists
    );
    let counts: Vec<(&str, i64)> = index
        .open_counts
        .iter()
        .map(|count| (count.list_id.as_str(), count.count))
        .collect();
    // `project` and `paper` in Work; `step` is finished, and the tasks under
    // the finished and the archived list are out. The wrapper is a list, so
    // it is credited with what lies beneath it, as Android counted.
    assert_eq!(
        counts,
        [
            ("l", 2),
            ("o", 1),
            ("empty", 0),
            ("reading", 1),
            ("papers", 1),
            ("root", 1),
            ("inner", 1),
        ]
    );
}
