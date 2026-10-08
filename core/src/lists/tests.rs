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
             INSERT INTO list_folders (id, workspaceId, parentFolderId, name, sortOrder, createdAt, updatedAt) VALUES
               ('f', 'w', NULL, 'Work', 0, '{T}', '{T}'),
               ('sub', 'w', 'f', 'Clients', 0, '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, folderId, name, sortOrder, createdAt, updatedAt, systemRole) VALUES
               ('inbox', 'w', NULL, 'Inbox', 0, '{T}', '{T}', 'inbox'),
               ('l', 'w', 'f', 'Proposals', 1, '{T}', '{T}', NULL),
               ('deep', 'w', 'sub', 'Acme', 2, '{T}', '{T}', NULL);
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt) VALUES
               ('a', 'l', 'Draft', 0, '{T}', '{T}'),
               ('b', 'l', 'Send', 1, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn count(connection: &Connection, sql: &str) -> i64 {
    connection.query_row(sql, [], |row| row.get(0)).unwrap()
}

#[test]
fn deleting_a_list_takes_its_tasks_and_one_undo_brings_them_back() {
    let mut connection = workspace();
    let deleted = journalled(&mut connection, "Delete List", |tx| delete_list(tx, "l")).unwrap();
    assert_eq!(
        deleted,
        DeletedList {
            id: "l".into(),
            name: "Proposals".into(),
            tasks_deleted: 2
        }
    );
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM tasks"), 0);
    undo(&mut connection).unwrap();
    assert_eq!(
        count(&connection, "SELECT COUNT(*) FROM tasks WHERE listId = 'l'"),
        2
    );
}

#[test]
fn the_inbox_cannot_be_deleted_and_a_missing_list_is_named() {
    let mut connection = workspace();
    assert!(matches!(
        journalled(&mut connection, "Delete List", |tx| delete_list(
            tx, "inbox"
        )),
        Err(CoreError::SystemListIsPermanent)
    ));
    assert!(matches!(
        journalled(&mut connection, "Delete List", |tx| delete_list(tx, "nope")),
        Err(CoreError::MissingList { ref id }) if id == "nope"
    ));
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM change_log"), 0);
}

#[test]
fn deleting_a_folder_keeps_its_lists_and_takes_its_folders() {
    let mut connection = workspace();
    journalled(&mut connection, "Delete Folder", |tx| {
        delete_folder(tx, "f")
    })
    .unwrap();
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM list_folders"), 0);
    assert_eq!(
        count(
            &connection,
            "SELECT COUNT(*) FROM task_lists WHERE folderId IS NULL"
        ),
        3
    );
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM tasks"), 2);

    undo(&mut connection).unwrap();
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM list_folders"), 2);
    assert_eq!(
        connection
            .query_row(
                "SELECT folderId FROM task_lists WHERE id = 'deep'",
                [],
                |row| row.get::<_, Option<String>>(0)
            )
            .unwrap()
            .as_deref(),
        Some("sub")
    );
}

#[test]
fn deleting_a_missing_folder_is_named() {
    let mut connection = workspace();
    assert!(matches!(
        journalled(&mut connection, "Delete Folder", |tx| delete_folder(tx, "nope")),
        Err(CoreError::MissingFolder { ref id }) if id == "nope"
    ));
}

const NOW: i64 = 1_700_000_000_123;
const NOW_TEXT: &str = "2023-11-14 22:13:20.123";

fn steps(connection: &Connection) -> i64 {
    count(connection, "SELECT COUNT(DISTINCT groupId) FROM change_log")
}

#[test]
fn renaming_a_folder_trims_stamps_and_ignores_its_own_name() {
    let mut connection = workspace();
    journalled(&mut connection, "Rename Folder", |tx| {
        rename_folder(tx, "f", "  Office ", NOW)
    })
    .unwrap();
    let (name, updated): (String, String) = connection
        .query_row(
            "SELECT name, updatedAt FROM list_folders WHERE id = 'f'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((name.as_str(), updated.as_str()), ("Office", NOW_TEXT));
    assert_eq!(steps(&connection), 1);

    journalled(&mut connection, "Rename Folder", |tx| {
        rename_folder(tx, "f", "Office", NOW)
    })
    .unwrap();
    assert_eq!(steps(&connection), 1);
    assert!(matches!(
        journalled(&mut connection, "Rename Folder", |tx| rename_folder(
            tx, "f", "   ", NOW
        )),
        Err(CoreError::EmptyName)
    ));
}

#[test]
fn renaming_a_list_leaves_its_colour_and_editing_sets_both() {
    let mut connection = workspace();
    journalled(&mut connection, "Edit List", |tx| {
        update_list(tx, "l", "Bids", Some(" #ABCDEF "), NOW)
    })
    .unwrap();
    journalled(&mut connection, "Rename List", |tx| {
        rename_list(tx, "l", "Tenders", NOW)
    })
    .unwrap();
    let (name, colour): (String, Option<String>) = connection
        .query_row(
            "SELECT name, colorHex FROM task_lists WHERE id = 'l'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        (name.as_str(), colour.as_deref()),
        ("Tenders", Some("#ABCDEF"))
    );

    journalled(&mut connection, "Edit List", |tx| {
        update_list(tx, "l", "Tenders", Some("  "), NOW)
    })
    .unwrap();
    let colour: Option<String> = connection
        .query_row(
            "SELECT colorHex FROM task_lists WHERE id = 'l'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(colour, None);
    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("Edit List"));
}

#[test]
fn the_inbox_cannot_be_archived_but_can_be_restored() {
    let mut connection = workspace();
    assert!(matches!(
        journalled(&mut connection, "Archive List", |tx| set_list_archived(
            tx, "inbox", true, NOW
        )),
        Err(CoreError::SystemListIsPermanent)
    ));
    journalled(&mut connection, "Archive List", |tx| {
        set_list_archived(tx, "inbox", false, NOW)
    })
    .unwrap();
    journalled(&mut connection, "Archive List", |tx| {
        set_list_archived(tx, "l", true, NOW)
    })
    .unwrap();
    assert_eq!(
        count(
            &connection,
            "SELECT isArchived FROM task_lists WHERE id = 'l'"
        ),
        1
    );
    assert!(matches!(
        journalled(&mut connection, "Archive List", |tx| set_list_archived(
            tx, "nope", true, NOW
        )),
        Err(CoreError::MissingList { .. })
    ));
}

#[test]
fn a_new_folder_and_list_go_after_their_siblings_and_undo_as_one_step_each() {
    let mut connection = workspace();
    let folder = journalled(&mut connection, "New Folder", |tx| {
        create_folder(tx, "w", "  Clients ", Some("f"), NOW)
    })
    .unwrap();
    assert_eq!((folder.name.as_str(), folder.sort_order), ("Clients", 1));
    assert_eq!(folder.id, folder.id.to_uppercase());
    assert_eq!(folder.id.len(), 36);

    let list = journalled(&mut connection, "New List", |tx| {
        create_list(tx, "w", "Acme", None, NOW)
    })
    .unwrap();
    assert_eq!((list.name.as_str(), list.sort_order), ("Acme", 1));
    let (archived, created): (bool, String) = connection
        .query_row(
            "SELECT isArchived, createdAt FROM task_lists WHERE id = ?1",
            [&list.id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((archived, created.as_str()), (false, NOW_TEXT));

    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("New List"));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("New Folder")
    );
    assert_eq!(count(&connection, "SELECT COUNT(*) FROM list_folders"), 2);
}

#[test]
fn a_new_item_in_a_folder_from_another_workspace_or_none_is_refused() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w2', 'Theirs', '{T}', '{T}');
             INSERT INTO list_folders (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('elsewhere', 'w2', 'Away', 0, '{T}', '{T}');"
        ))
        .unwrap();
    for folder in ["elsewhere", "nope"] {
        assert!(matches!(
            journalled(&mut connection, "New List", |tx| create_list(
                tx,
                "w",
                "X",
                Some(folder),
                NOW
            )),
            Err(CoreError::MissingFolder { .. })
        ));
        assert!(matches!(
            journalled(&mut connection, "New Folder", |tx| create_folder(
                tx,
                "w",
                "X",
                Some(folder),
                NOW
            )),
            Err(CoreError::MissingFolder { .. })
        ));
    }
    assert!(matches!(
        journalled(&mut connection, "New List", |tx| create_list(
            tx, "w", " ", None, NOW
        )),
        Err(CoreError::EmptyName)
    ));
}
