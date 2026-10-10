use rusqlite::{Connection, params};

use super::*;
use crate::schema::migrate;
use crate::time::stored;

/// Milliseconds from seconds, as the Kotlin port's fixture gave them.
fn at(seconds: f64) -> i64 {
    (seconds * 1000.0) as i64
}

fn migrated() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
}

#[allow(clippy::too_many_arguments)]
fn insert_task(
    connection: &Connection,
    id: &str,
    parent: Option<&str>,
    title: &str,
    notes: &str,
    status: &str,
    sort_order: i64,
    created: f64,
) {
    connection
        .execute(
            "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, createdAt, updatedAt)
             VALUES (?1, 'L1', ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                id,
                parent,
                title,
                notes,
                status,
                sort_order,
                stored(at(created)),
                stored(at(created + 1.0))
            ],
        )
        .unwrap();
}

/// The snapshot the Mac wrote `workspace.json` and `workspace.md` from:
/// every optional field present and absent, a `/` and quotes to escape, a
/// tab, a backslash, a blank line in notes, non-ASCII, an archived list with
/// no tasks, and fractions of a second to drop.
fn fixture_workspace() -> Connection {
    let connection = migrated();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('W', 'Adam''s workspace', '{0}', '{0}');
             INSERT INTO list_folders (id, workspaceId, name, sortOrder, createdAt, updatedAt) VALUES ('F1', 'W', 'Folder', 0, '{0}', '{0}');
             INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, systemRole, visibleRootTaskId, completedAt, createdAt, updatedAt) VALUES
               ('L1', 'W', 'F1', 'Inbox / \"main\"', '#007fff', 0, 0, 'inbox', 'T1', '{1}', '{2}', '{3}'),
               ('L2', 'W', NULL, 'Old', NULL, 1, 1, NULL, NULL, NULL, '{4}', '{5}');",
            stored(0),
            stored(at(1759700000.25)),
            stored(at(1759000000.999)),
            stored(at(1759100000.0)),
            stored(0),
            stored(1000),
        ))
        .unwrap();
    insert_task(
        &connection,
        "T1",
        None,
        "Plan the week",
        "First line\n\nSecond \\ line\ttab",
        "open",
        0,
        1759000001.0,
    );
    insert_task(
        &connection,
        "T2",
        Some("T1"),
        "Draft notes é😀",
        "",
        "completed",
        1,
        1759000003.0,
    );
    insert_task(
        &connection,
        "T3",
        Some("T2"),
        "Deep",
        "only",
        "cancelled",
        0,
        1759000005.0,
    );
    insert_task(
        &connection,
        "T4",
        None,
        "Second root",
        "",
        "open",
        1,
        1759000007.0,
    );
    connection
        .execute(
            "UPDATE tasks SET dueAt = ?1, estimateSeconds = 1800, sourceSystem = 'checkvist',
               sourceId = '123', itemKind = 'list', isPromoted = 0, archivedAt = ?2, completedAt = ?3
             WHERE id = 'T2'",
            params![
                stored(at(1759800000.0)),
                stored(at(1759900000.0)),
                stored(at(1759850000.5))
            ],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE tasks SET estimateSeconds = 0, itemKind = 'task', isPromoted = 1 WHERE id = 'T3'",
            [],
        )
        .unwrap();
    connection
}

const EXPORTED_AT: i64 = 1_759_752_000_750;

#[test]
fn json_matches_what_the_mac_writes() {
    let document = export(&fixture_workspace(), "W", ExportFormat::Json, EXPORTED_AT)
        .unwrap()
        .unwrap();
    assert_eq!(document, include_str!("workspace.json"));
}

#[test]
fn markdown_matches_what_the_mac_writes() {
    let document = export(
        &fixture_workspace(),
        "W",
        ExportFormat::Markdown,
        EXPORTED_AT,
    )
    .unwrap()
    .unwrap();
    assert_eq!(document, include_str!("workspace.md"));
}

#[test]
fn an_empty_workspace_is_written_as_foundation_writes_it() {
    let connection = migrated();
    connection
        .execute_batch(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt)
             VALUES ('w', 'w', '2025-01-01 00:00:00.000', '2025-01-01 00:00:00.000');",
        )
        .unwrap();
    assert_eq!(
        export(&connection, "w", ExportFormat::Json, 1_759_752_000_000)
            .unwrap()
            .unwrap(),
        "{\n  \"exportedAt\" : \"2025-10-06T12:00:00Z\",\n  \"lists\" : [\n\n  ],\n  \"workspace\" : \"w\"\n}"
    );
    assert_eq!(
        export(&connection, "w", ExportFormat::Markdown, 0)
            .unwrap()
            .unwrap(),
        "# w\n"
    );
}

#[test]
fn a_missing_workspace_has_no_document() {
    assert_eq!(
        export(&migrated(), "nope", ExportFormat::Json, 0).unwrap(),
        None
    );
}

#[test]
fn the_tree_is_walked_depth_first_in_sibling_order_and_every_list_is_read() {
    let connection = migrated();
    let t = "2025-01-01 00:00:00.000";
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'w', '{t}', '{t}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt) VALUES
               ('work', 'w', 'Work', 0, 0, '{t}', '{t}'),
               ('old', 'w', 'Old', 1, 1, '{t}', '{t}');
             INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, createdAt, updatedAt) VALUES
               ('d', 'work', NULL, 'd', 'open', 1, '{t}', '{t}'),
               ('c', 'work', 'a', 'c', 'open', 1, '{t}', '{t}'),
               ('a', 'work', NULL, 'a', 'open', 0, '{t}', '{t}'),
               ('b', 'work', 'a', 'b', 'open', 0, '{t}', '{t}'),
               ('stray', 'work', 'elsewhere', 'stray', 'open', 0, '{t}', '{t}'),
               ('gone', 'old', NULL, 'gone', 'completed', 0, '{t}', '{t}');"
        ))
        .unwrap();
    let document = export(&connection, "w", ExportFormat::Markdown, 0)
        .unwrap()
        .unwrap();
    assert_eq!(
        document,
        "# w\n\n## Work\n\n- [ ] a\n  - [ ] b\n  - [ ] c\n- [ ] d\n\n## Old (archived)\n\n- [x] gone\n"
    );
}

#[test]
fn notes_split_on_line_feeds_as_swift_splits_characters() {
    assert_eq!(note_lines("a\n\nb\n"), ["a", "b"]);
    assert_eq!(note_lines("\na"), ["a"]);
    // `\r\n` is one Character in Swift, and not `\n`.
    assert_eq!(note_lines("a\r\nb\nc"), ["a\r\nb", "c"]);
    assert!(note_lines("").is_empty());
}

#[test]
fn integers_are_written_whole_as_swift_writes_an_int() {
    let value = Json::object([
        ("big", Some(Json::Integer(i64::MAX))),
        ("negative", Some(Json::Integer(-1))),
    ]);
    assert_eq!(
        json::pretty_escaping_slashes(&value).unwrap(),
        "{\n  \"big\" : 9223372036854775807,\n  \"negative\" : -1\n}"
    );
}

#[test]
fn dates_drop_their_fraction_rather_than_round_it() {
    assert_eq!(date(-1500), Json::String("1969-12-31T23:59:58Z".into()));
    assert_eq!(
        date(1_759_000_000_999),
        Json::String("2025-09-27T19:06:40Z".into())
    );
}
