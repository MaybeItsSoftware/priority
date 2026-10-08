use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, systemRole, createdAt, updatedAt) VALUES
               ('inbox', 'w', 'Inbox', 0, 0, 'inbox', '{T}', '{T}'),
               ('l', 'w', 'Work', 1, 0, NULL, '{T}', '{T}'),
               ('gone', 'w', 'Gone', 2, 1, NULL, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, dueAt, createdAt, updatedAt) VALUES
               ('b', 'l', NULL, 'B', 1, NULL, '{T}', '{T}'),
               ('a', 'l', NULL, 'A', 0, '2026-03-11 09:30:00.250', '{T}', '{T}'),
               ('a2', 'l', 'a', 'A2', 1, NULL, '{T}', '{T}'),
               ('a1', 'l', 'a', 'A1', 0, NULL, '{T}', '{T}'),
               ('a1x', 'l', 'a1', 'A1x', 0, NULL, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

#[test]
fn the_outline_is_depth_first_in_sort_order() {
    let connection = workspace();
    let items: Vec<(String, i64)> = outline(&connection, "l", None)
        .unwrap()
        .into_iter()
        .map(|item| (item.task.id, item.depth))
        .collect();
    let expected = [("a", 0), ("a1", 1), ("a1x", 2), ("a2", 1), ("b", 0)];
    assert_eq!(items, expected.map(|(id, depth)| (id.to_string(), depth)));
    let under: Vec<String> = outline(&connection, "l", Some("a"))
        .unwrap()
        .into_iter()
        .map(|item| item.task.id)
        .collect();
    assert_eq!(under, ["a1", "a1x", "a2"]);
}

#[test]
fn a_cycle_in_the_rows_shows_each_task_once() {
    let connection = workspace();
    connection
        .execute("UPDATE tasks SET parentTaskId = 'a1x' WHERE id = 'a'", [])
        .unwrap();
    // 'a' now hangs under its own grandchild, so nothing reaches it from the root.
    let roots: Vec<String> = outline(&connection, "l", None)
        .unwrap()
        .into_iter()
        .map(|item| item.task.id)
        .collect();
    assert_eq!(roots, ["b"]);
    // Under 'a' the walk meets 'a' again beneath its grandchild, shows it
    // once, and does not repeat what it has already shown, as Swift does.
    let under: Vec<String> = outline(&connection, "l", Some("a"))
        .unwrap()
        .into_iter()
        .map(|item| item.task.id)
        .collect();
    assert_eq!(under, ["a1", "a1x", "a", "a2"]);
}

#[test]
fn rows_carry_dates_as_milliseconds_and_lists_hide_archived() {
    let connection = workspace();
    let a = task(&connection, "a").unwrap().unwrap();
    assert_eq!(a.due_at_ms, Some(1_773_221_400_250));
    assert_eq!(a.notes, "");
    assert_eq!(a.status, "open");
    assert_eq!(
        lists(&connection, "w", false)
            .unwrap()
            .iter()
            .map(|l| l.id.as_str())
            .collect::<Vec<_>>(),
        ["inbox", "l"]
    );
    assert_eq!(lists(&connection, "w", true).unwrap().len(), 3);
    assert_eq!(inbox(&connection, "w").unwrap().unwrap().id, "inbox");
    let found = tasks_by_id(&connection, &["a".into(), "missing".into()]).unwrap();
    assert_eq!(found.len(), 1);
    let roots: Vec<String> = children(&connection, "l", None)
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(roots, ["a", "b"]);
}

#[test]
fn a_lone_imported_root_with_children_stands_in_for_the_list() {
    let connection = workspace();
    // 'l' has two roots, so neither is a candidate.
    assert!(
        visible_root_candidates(&connection, "l")
            .unwrap()
            .is_empty()
    );
    connection
        .execute_batch(&format!(
            "INSERT INTO task_lists (id, workspaceId, name, sortOrder, visibleRootTaskId, createdAt, updatedAt)
               VALUES ('imp', 'w', 'Imported', 3, 'wrap', '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, sourceSystem, createdAt, updatedAt) VALUES
               ('wrap', 'imp', NULL, 'Wrapper', 0, 'checkvist', '{T}', '{T}'),
               ('kid', 'imp', 'wrap', 'Kid', 0, NULL, '{T}', '{T}');"
        ))
        .unwrap();
    let candidates: Vec<String> = visible_root_candidates(&connection, "imp")
        .unwrap()
        .into_iter()
        .map(|t| t.id)
        .collect();
    assert_eq!(candidates, ["wrap"]);
    assert_eq!(
        visible_root_parent(&connection, "imp").unwrap().as_deref(),
        Some("wrap")
    );
    connection
        .execute("DELETE FROM tasks WHERE id = 'kid'", [])
        .unwrap();
    assert!(
        visible_root_candidates(&connection, "imp")
            .unwrap()
            .is_empty()
    );
    assert_eq!(visible_root_parent(&connection, "l").unwrap(), None);
}

#[test]
fn a_folder_cannot_move_into_itself_or_below() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO list_folders (id, workspaceId, parentFolderId, name, sortOrder, createdAt, updatedAt) VALUES
               ('top', 'w', NULL, 'Top', 0, '{T}', '{T}'),
               ('mid', 'w', 'top', 'Mid', 0, '{T}', '{T}'),
               ('low', 'w', 'mid', 'Low', 0, '{T}', '{T}'),
               ('other', 'w', NULL, 'Other', 1, '{T}', '{T}');"
        ))
        .unwrap();
    let ids: Vec<String> = valid_parent_folders(&connection, "mid")
        .unwrap()
        .into_iter()
        .map(|f| f.id)
        .collect();
    assert_eq!(ids, ["top", "other"]);
    assert!(matches!(
        valid_parent_folders(&connection, "missing"),
        Err(CoreError::MissingFolder { .. })
    ));
}
