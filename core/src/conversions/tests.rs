use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
const NOW: i64 = 1_700_000_000_000;

/// Inbox `in` (system). `work`: Project(p) > Step(s) > Detail(d); Other(o).
/// `side` is a standalone list with its wrapper `w` > Item(i), and a loose
/// task `x`.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w0', 'Mine', '{T}', '{T}');
             INSERT INTO list_folders (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('f', 'w0', 'Folder', 0, '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, colorHex, sortOrder, createdAt, updatedAt, systemRole) VALUES
               ('in', 'w0', 'Inbox', NULL, 0, '{T}', '{T}', 'inbox'),
               ('work', 'w0', 'Work', '#123456', 1, '{T}', '{T}', NULL),
               ('side', 'w0', 'Side', NULL, 2, '{T}', '{T}', NULL);
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('p', 'work', NULL, 'Project', 0, '{T}', '{T}'),
               ('s', 'work', 'p', 'Step', 0, '{T}', '{T}'),
               ('d', 'work', 's', 'Detail', 0, '{T}', '{T}'),
               ('o', 'work', NULL, 'Other', 1, '{T}', '{T}'),
               ('w', 'side', NULL, 'Side', 0, '{T}', '{T}'),
               ('i', 'side', 'w', 'Item', 0, '{T}', '{T}'),
               ('x', 'side', NULL, 'Loose', 1, '{T}', '{T}');
             UPDATE task_lists SET visibleRootTaskId = 'w' WHERE id = 'side';"
        ))
        .unwrap();
    connection
}

fn place(connection: &Connection, id: &str) -> (String, Option<String>, Option<String>) {
    connection
        .query_row(
            "SELECT listId, parentTaskId, itemKind FROM tasks WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap()
}

fn lists(connection: &Connection) -> i64 {
    connection
        .query_row("SELECT COUNT(*) FROM task_lists", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn a_task_dropped_on_a_folder_becomes_a_list_with_its_subtree() {
    let mut connection = workspace();
    let list = journalled(&mut connection, "Move Item to Folder", |tx| {
        move_task_to_folder(tx, "s", Some("f"), NOW)
    })
    .unwrap();
    let (name, folder, colour, root): (String, Option<String>, Option<String>, Option<String>) =
        connection
            .query_row(
                "SELECT name, folderId, colorHex, visibleRootTaskId FROM task_lists WHERE id = ?1",
                [&list],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
    assert_eq!(
        (
            name.as_str(),
            folder.as_deref(),
            colour.as_deref(),
            root.as_deref()
        ),
        ("Step", Some("f"), Some("#123456"), Some("s"))
    );
    assert_eq!(
        place(&connection, "s"),
        (list.clone(), None, Some("list".into()))
    );
    assert_eq!(place(&connection, "d"), (list, Some("s".into()), None));
    undo(&mut connection).unwrap();
    assert_eq!(
        place(&connection, "s"),
        ("work".into(), Some("p".into()), None)
    );
    assert_eq!(lists(&connection), 3);

    // A list's wrapper cannot leave it, and the folder must be the workspace's.
    assert!(matches!(
        journalled(&mut connection, "Move Item to Folder", |tx| {
            move_task_to_folder(tx, "w", None, NOW)
        }),
        Err(CoreError::InvalidTaskMove)
    ));
    assert!(matches!(
        journalled(&mut connection, "Move Item to Folder", |tx| {
            move_task_to_folder(tx, "o", Some("nope"), NOW)
        }),
        Err(CoreError::MissingFolder { .. })
    ));
}

#[test]
fn a_list_turned_into_a_task_lands_in_the_inbox_under_its_wrapper() {
    let mut connection = workspace();
    let root = journalled(&mut connection, "Convert List to Task", |tx| {
        convert_list_to_task(tx, "side", NOW)
    })
    .unwrap();
    assert_eq!(root, "w");
    assert_eq!(
        place(&connection, "w"),
        ("in".into(), None, Some("task".into()))
    );
    assert_eq!(
        place(&connection, "i"),
        ("in".into(), Some("w".into()), None)
    );
    assert_eq!(
        place(&connection, "x"),
        ("in".into(), Some("w".into()), None)
    );
    assert_eq!(lists(&connection), 2);
    undo(&mut connection).unwrap();
    assert_eq!(place(&connection, "x"), ("side".into(), None, None));
    assert!(matches!(
        journalled(&mut connection, "Convert List to Task", |tx| {
            convert_list_to_task(tx, "in", NOW)
        }),
        Err(CoreError::SystemListIsPermanent)
    ));
}

#[test]
fn a_list_without_a_wrapper_nests_under_a_new_task_named_for_it() {
    let mut connection = workspace();
    let root = journalled(&mut connection, "Move List into List", |tx| {
        nest_list(tx, "work", "side", None, NOW)
    })
    .unwrap();
    let (title, kind, parent): (String, Option<String>, Option<String>) = connection
        .query_row(
            "SELECT title, itemKind, parentTaskId FROM tasks WHERE id = ?1",
            [&root],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    // `side` still shows its wrapper's children, so the nested list goes under it.
    assert_eq!(
        (title.as_str(), kind.as_deref(), parent.as_deref()),
        ("Work", Some("list"), None)
    );
    assert_eq!(
        place(&connection, "p"),
        ("side".into(), Some(root.clone()), None)
    );
    assert_eq!(
        place(&connection, "d"),
        ("side".into(), Some("s".into()), None)
    );
    assert!(matches!(
        journalled(&mut connection, "Move List into List", |tx| nest_list(
            tx, "side", "side", None, NOW
        )),
        Err(CoreError::InvalidTaskMove)
    ));
}

#[test]
fn kinds_and_nested_list_flags_change_once() {
    let mut connection = workspace();
    journalled(&mut connection, "Convert to List", |tx| {
        set_item_kind(tx, "o", "list", NOW)
    })
    .unwrap();
    journalled(&mut connection, "Promote List", |tx| {
        set_nested_list_promoted(tx, "o", true, NOW)
    })
    .unwrap();
    journalled(&mut connection, "Archive Nested List", |tx| {
        set_nested_list_archived(tx, "o", true, NOW)
    })
    .unwrap();
    let flags = |c: &Connection| -> (Option<bool>, Option<String>) {
        c.query_row(
            "SELECT isPromoted, archivedAt FROM tasks WHERE id = 'o'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
    };
    assert_eq!(
        flags(&connection),
        (Some(true), Some("2023-11-14 22:13:20.000".into()))
    );
    let steps = |c: &Connection| -> i64 {
        c.query_row(
            "SELECT COUNT(DISTINCT groupId) FROM change_log",
            [],
            |row| row.get(0),
        )
        .unwrap()
    };
    let before = steps(&connection);
    journalled(&mut connection, "Promote List", |tx| {
        set_nested_list_promoted(tx, "o", true, NOW)
    })
    .unwrap();
    assert_eq!(steps(&connection), before);
    // Back to a task clears both flags.
    journalled(&mut connection, "Convert to Task", |tx| {
        set_item_kind(tx, "o", "task", NOW)
    })
    .unwrap();
    assert_eq!(flags(&connection), (None, None));
    assert!(matches!(
        journalled(&mut connection, "Promote List", |tx| {
            set_nested_list_promoted(tx, "o", true, NOW)
        }),
        Err(CoreError::MissingList { .. })
    ));
    // A wrapper keeps its kind.
    assert!(matches!(
        journalled(&mut connection, "Convert to List", |tx| set_item_kind(
            tx, "w", "list", NOW
        )),
        Err(CoreError::InvalidTaskMove)
    ));
}

#[test]
fn completing_a_list_and_saving_a_board() {
    let mut connection = workspace();
    journalled(&mut connection, "Complete List", |tx| {
        set_list_completed(tx, "work", true, NOW)
    })
    .unwrap();
    let completed: Option<String> = connection
        .query_row(
            "SELECT completedAt FROM task_lists WHERE id = 'work'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(completed.is_some());
    assert!(matches!(
        journalled(&mut connection, "Complete List", |tx| set_list_completed(
            tx, "in", true, NOW
        )),
        Err(CoreError::SystemListIsPermanent)
    ));

    let columns = [
        BoardColumn {
            id: "todo".into(),
            title: "To do".into(),
        },
        BoardColumn {
            id: "done".into(),
            title: "Done / shipped".into(),
        },
    ];
    let moving = ["o".to_string(), "p".to_string()];
    journalled(&mut connection, "Edit Board", |tx| {
        set_board_columns(tx, "work", &columns, &moving, Some("todo"), NOW)
    })
    .unwrap();
    let json: String = connection
        .query_row(
            "SELECT columnsJSON FROM kanban_boards WHERE id = 'work'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        json,
        r#"[{"id":"todo","title":"To do"},{"id":"done","title":"Done \/ shipped"}]"#
    );
    let column: Option<String> = connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = 'p'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(column.as_deref(), Some("todo"));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Edit Board")
    );
    let boards: i64 = connection
        .query_row("SELECT COUNT(*) FROM kanban_boards", [], |row| row.get(0))
        .unwrap();
    assert_eq!(boards, 0);
}
