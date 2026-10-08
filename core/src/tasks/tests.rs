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

#[test]
fn a_board_move_writes_each_task_once_and_refuses_a_missing_one() {
    let mut connection = workspace();
    let ids = vec!["o".to_string(), "p".to_string(), "o".to_string()];
    journalled(&mut connection, "Move Task", |tx| {
        set_kanban_column(tx, &ids, Some(" doing "), NOW)
    })
    .unwrap();
    let columns: Vec<(String, Option<String>)> = {
        let mut statement = connection
            .prepare("SELECT taskId, kanbanColumn FROM task_metadata WHERE kanbanColumn IS NOT NULL ORDER BY taskId")
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(
        columns,
        [
            ("o".into(), Some("doing".into())),
            ("p".into(), Some("doing".into()))
        ]
    );
    let missing = vec!["o".to_string(), "nope".to_string()];
    assert!(matches!(
        journalled(&mut connection, "Move Task", |tx| set_kanban_column(tx, &missing, None, NOW)),
        Err(CoreError::MissingTask { ref id }) if id == "nope"
    ));
    journalled(&mut connection, "Move Task", |tx| {
        set_kanban_column(tx, &["o".to_string()], Some("  "), NOW)
    })
    .unwrap();
    let cleared: Option<String> = connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = 'o'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(cleared, None);
}

#[test]
fn a_matrix_placement_creates_or_updates_the_tasks_metadata() {
    let mut connection = workspace();
    journalled(&mut connection, "Move Task", |tx| {
        set_matrix_position(tx, "o", Some(2), Some(1), NOW)
    })
    .unwrap();
    journalled(&mut connection, "Move Task", |tx| {
        set_matrix_position(tx, "c", Some(1), None, NOW)
    })
    .unwrap();
    assert_eq!(matrix(&connection, "o"), (Some(2), Some(1)));
    assert_eq!(matrix(&connection, "c"), (Some(1), None));
    undo(&mut connection).unwrap();
    assert_eq!(matrix(&connection, "c"), (None, None));
}

fn matrix(connection: &Connection, id: &str) -> (Option<i64>, Option<i64>) {
    connection
        .query_row(
            "SELECT matrixUrgency, matrixImportance FROM task_metadata WHERE taskId = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
}

fn new_task(list: &str, title: &str) -> NewTask {
    NewTask {
        list_id: list.into(),
        title: title.into(),
        kind: "task".into(),
        ..NewTask::default()
    }
}

#[test]
fn a_new_task_goes_last_with_what_the_add_field_read_in_the_same_step() {
    let mut connection = workspace();
    let new = NewTask {
        tags: vec![" Home ".into(), "home".into(), "".into(), "Errand".into()],
        priority: Some(2),
        estimate_seconds: Some(1800),
        waiting_on: Some("  Sam  ".into()),
        kanban_column: Some("today".into()),
        ..new_task("l", "  Buy milk ")
    };
    let id = journalled(&mut connection, "New Task", |tx| create_task(tx, &new, NOW)).unwrap();
    assert_eq!(children(&connection, "l", None), ["p", "o", id.as_str()]);
    let (title, estimate, kind): (String, Option<i64>, String) = connection
        .query_row(
            "SELECT title, estimateSeconds, itemKind FROM tasks WHERE id = ?1",
            [&id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        (title.as_str(), estimate, kind.as_str()),
        ("Buy milk", Some(1800), "task")
    );
    let (tags, priority, column, waiting): (String, Option<i64>, Option<String>, Option<String>) = connection
        .query_row(
            "SELECT tagsJSON, priority, kanbanColumn, waitingOn FROM task_metadata WHERE taskId = ?1",
            [&id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(tags, r#"["Home","Errand"]"#);
    assert_eq!(priority, Some(2));
    assert_eq!(column.as_deref(), Some(WAITING_COLUMN));
    assert_eq!(waiting.as_deref(), Some("Sam"));

    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("New Task"));
    let left: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM task_metadata WHERE taskId = ?1",
            [&id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(left, 0);
}

#[test]
fn a_new_task_can_go_first_or_beside_a_sibling_and_needs_a_real_place() {
    let mut connection = workspace();
    let top = journalled(&mut connection, "New Task", |tx| {
        create_task(
            tx,
            &NewTask {
                at_top: true,
                ..new_task("l", "Top")
            },
            NOW,
        )
    })
    .unwrap();
    assert_eq!(children(&connection, "l", None), [top.as_str(), "p", "o"]);
    let above = journalled(&mut connection, "New Task", |tx| {
        create_task(
            tx,
            &NewTask {
                adjacent_task_id: Some("o".into()),
                above: true,
                ..new_task("l", "Above")
            },
            NOW,
        )
    })
    .unwrap();
    assert_eq!(
        children(&connection, "l", None),
        [top.as_str(), "p", above.as_str(), "o"]
    );

    assert!(matches!(
        journalled(&mut connection, "New Task", |tx| create_task(
            tx,
            &new_task("nope", "X"),
            NOW
        )),
        Err(CoreError::MissingList { .. })
    ));
    assert!(matches!(
        journalled(&mut connection, "New Task", |tx| create_task(
            tx,
            &new_task("l", "  "),
            NOW
        )),
        Err(CoreError::EmptyName)
    ));
    assert!(matches!(
        journalled(&mut connection, "New Task", |tx| {
            create_task(
                tx,
                &NewTask {
                    adjacent_task_id: Some("c".into()),
                    ..new_task("l", "X")
                },
                NOW,
            )
        }),
        Err(CoreError::InvalidTaskMove)
    ));
}

fn status_of(connection: &Connection, id: &str) -> (String, Option<String>) {
    connection
        .query_row(
            "SELECT status, completedAt FROM tasks WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
}

#[test]
fn closing_stamps_a_task_once_and_reopening_clears_it() {
    let mut connection = workspace();
    let first = 1_700_000_000_000;
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "completed", first, "UTC")
    })
    .unwrap();
    assert_eq!(
        status_of(&connection, "o"),
        ("completed".into(), Some("2023-11-14 22:13:20.000".into()))
    );
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "cancelled", first + 60_000, "UTC")
    })
    .unwrap();
    assert_eq!(
        status_of(&connection, "o").1.as_deref(),
        Some("2023-11-14 22:13:20.000")
    );
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "open", first, "UTC")
    })
    .unwrap();
    assert_eq!(status_of(&connection, "o"), ("open".into(), None));

    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "gone", "completed", first, "UTC")
    })
    .unwrap();
    assert!(matches!(
        journalled(&mut connection, "Change Status", |tx| set_status(
            tx, "o", "done", first, "UTC"
        )),
        Err(CoreError::InvalidStatus { .. })
    ));
}

#[test]
fn closing_a_task_closes_its_open_subtree_and_one_undo_reopens_it() {
    let mut connection = workspace();
    let earlier = 1_699_000_000_000;
    let first = 1_700_000_000_000;
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "g", "cancelled", earlier, "UTC")
    })
    .unwrap();
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "p", "completed", first, "UTC")
    })
    .unwrap();
    let stamp = Some("2023-11-14 22:13:20.000".to_string());
    assert_eq!(
        status_of(&connection, "c"),
        ("completed".into(), stamp.clone())
    );
    // Already closed: its own status and stamp stand.
    assert_eq!(status_of(&connection, "g").0, "cancelled");
    assert_ne!(status_of(&connection, "g").1, stamp);
    assert_eq!(status_of(&connection, "o"), ("open".into(), None));

    undo(&mut connection).unwrap();
    assert_eq!(status_of(&connection, "p"), ("open".into(), None));
    assert_eq!(status_of(&connection, "c"), ("open".into(), None));
    assert_eq!(status_of(&connection, "g").0, "cancelled");

    // Reopening does not cascade.
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "p", "completed", first, "UTC")
    })
    .unwrap();
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "p", "open", first, "UTC")
    })
    .unwrap();
    assert_eq!(status_of(&connection, "c").0, "completed");
}

#[test]
fn closing_a_repeating_task_writes_the_next_one_just_after_it() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "UPDATE tasks SET dueAt = '2026-03-02 09:00:00.000', estimateSeconds = 900 WHERE id = 'o';
             INSERT INTO task_metadata (taskId, priority, tagsJSON, recurrenceRule, kanbanColumn, focusRank, updatedAt)
               VALUES ('o', 2, '[\"home\"]', 'every 3 days', 'today', 0, '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt)
               VALUES ('z', 'l', 'Last', 2, '{T}', '{T}');"
        ))
        .unwrap();
    // Finished late, on 8 March: every third day from the 2nd lands on the 11th.
    let finished = 1_772_971_200_000; // 2026-03-08 12:00:00 UTC
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "completed", finished, "Europe/London")
    })
    .unwrap();

    let next: (String, String, Option<String>, Option<i64>, Option<String>) = connection
        .query_row(
            "SELECT id, status, dueAt, estimateSeconds, completedAt FROM tasks WHERE title = 'Other' AND id <> 'o'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        (next.1.as_str(), next.2.as_deref(), next.3, next.4),
        ("open", Some("2026-03-11 09:00:00.000"), Some(900), None)
    );
    let carried: (Option<i64>, String, Option<String>, Option<String>, Option<i64>) = connection
        .query_row(
            "SELECT priority, tagsJSON, recurrenceRule, kanbanColumn, focusRank FROM task_metadata WHERE taskId = ?1",
            [&next.0],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        carried,
        (
            Some(2),
            "[\"home\"]".into(),
            Some("every 3 days".into()),
            None,
            None
        )
    );
    assert_eq!(
        children(&connection, "l", None),
        ["p", "o", next.0.as_str(), "z"]
    );

    // Closing it again is not newly closed, so nothing more is written.
    let count = |c: &Connection| -> i64 {
        c.query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get(0))
            .unwrap()
    };
    let before = count(&connection);
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "completed", finished, "UTC")
    })
    .unwrap();
    assert_eq!(count(&connection), before);

    // Closing it again was its own step; the one before it took back the
    // close and the occurrence it wrote together.
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Change Status")
    );
    assert_eq!(count(&connection), before);
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Change Status")
    );
    assert_eq!(count(&connection), before - 1);
    assert_eq!(status_of(&connection, "o"), ("open".into(), None));
}

#[test]
fn closing_a_habits_source_ends_the_habit_and_clears_its_placement() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO dailies (id, taskId, sortOrder, createdAt, updatedAt, sourceTaskId, placementColumn, expiryRule)
               VALUES ('h', 'c', 0, '{T}', '{T}', 'o', 'today', 'source'),
                      ('keep', 'g', 1, '{T}', '{T}', 'o', NULL, 'never');
             UPDATE task_metadata SET kanbanColumn = 'today', focusRank = 3 WHERE taskId = 'c';"
        ))
        .unwrap();
    journalled(&mut connection, "Change Status", |tx| {
        set_status(tx, "o", "completed", 1_700_000_000_000, "UTC")
    })
    .unwrap();
    let archived = |id: &str| -> Option<String> {
        connection
            .query_row(
                "SELECT archivedAt FROM dailies WHERE id = ?1",
                [id],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert!(archived("h").is_some());
    assert!(archived("keep").is_none());
    let placement: (Option<String>, Option<i64>) = connection
        .query_row(
            "SELECT kanbanColumn, focusRank FROM task_metadata WHERE taskId = 'c'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(placement, (None, None));
}
