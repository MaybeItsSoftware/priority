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
