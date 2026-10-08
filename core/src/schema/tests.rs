use rusqlite::{Connection, params};

use super::data::{grdb_timestamp, normalized_visible_root_name};
use super::*;

const FIXTURE: &str = include_str!("../../../cli/src/fixtures/workspace_schema.sql");

fn migrated() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
}

fn migrated_through(last: &str) -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate_through(&mut connection, Some(last)).unwrap();
    connection
}

fn ledger(connection: &Connection) -> Vec<String> {
    let mut statement = connection
        .prepare("SELECT identifier FROM grdb_migrations ORDER BY rowid")
        .unwrap();
    statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

/// The proof that the core and the app agree: a new database the core
/// migrates has, statement for statement, the schema the Mac's GRDB migrator
/// produced, as dumped into the fixture the CLI and Android are held to.
#[test]
fn a_new_database_has_exactly_the_fixtures_schema() {
    let dumped = dump_schema(&migrated()).unwrap();
    if dumped != FIXTURE {
        let first = dumped
            .lines()
            .zip(FIXTURE.lines())
            .position(|(a, b)| a != b)
            .unwrap_or(dumped.lines().count().min(FIXTURE.lines().count()));
        panic!(
            "schema differs from the fixture at line {}:\n core:    {:?}\n fixture: {:?}",
            first + 1,
            dumped.lines().nth(first),
            FIXTURE.lines().nth(first)
        );
    }
}

#[test]
fn every_migration_is_recorded_in_order_under_grdbs_identifiers() {
    let connection = migrated();
    assert_eq!(ledger(&connection), workspace_migrations());
    assert_eq!(workspace_migrations().len(), 20);
    assert_eq!(
        workspace_migrations().last().map(String::as_str),
        Some("v20_waiting_follow_ups")
    );
}

#[test]
fn migrating_again_applies_nothing_and_keeps_the_work() {
    let mut connection = migrated();
    connection
        .execute_batch(
            "INSERT INTO workspaces VALUES ('w', 'Mine', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');",
        )
        .unwrap();
    let before = dump_schema(&connection).unwrap();
    assert_eq!(migrate(&mut connection).unwrap(), "v20_waiting_follow_ups");
    assert_eq!(dump_schema(&connection).unwrap(), before);
    let count: i64 = connection
        .query_row("SELECT COUNT(*) FROM workspaces", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn foreign_keys_are_restored_to_how_the_caller_had_them() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    let on: bool = connection
        .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
        .unwrap();
    assert!(on);
}

#[test]
fn a_file_database_is_created_and_closed_again() {
    let directory = std::env::temp_dir().join(format!("takt-core-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("workspace.sqlite");
    let latest = migrate_workspace(path.to_string_lossy().into_owned()).unwrap();
    assert_eq!(latest, "v20_waiting_follow_ups");
    let reopened = Connection::open(&path).unwrap();
    assert_eq!(ledger(&reopened).len(), 20);
    std::fs::remove_dir_all(directory).unwrap();
}

const T0: &str = "2023-11-14 22:13:20.000";
const T1: &str = "2023-11-15 09:00:00.000";

fn seed_workspace(connection: &Connection) {
    connection
        .execute(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', ?1, ?1)",
            [T0],
        )
        .unwrap();
}

fn seed_list(connection: &Connection, id: &str, name: &str, created_at: &str) {
    connection
        .execute(
            "INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
             VALUES (?1, 'w', ?2, 0, ?3, ?3)",
            params![id, name, created_at],
        )
        .unwrap();
}

fn seed_task(
    connection: &Connection,
    id: &str,
    list: &str,
    parent: Option<&str>,
    title: &str,
    source: Option<&str>,
    created_at: &str,
) {
    connection
        .execute(
            "INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt, sourceSystem)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5, ?6)",
            params![id, list, parent, title, created_at, source],
        )
        .unwrap();
}

fn visible_root(connection: &Connection, list: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT visibleRootTaskId FROM task_lists WHERE id = ?1",
            [list],
            |row| row.get(0),
        )
        .unwrap()
}

/// v11: an imported list whose single root is a wrapper named like the list
/// shows the wrapper's children; an unimported one, or one whose wrapper has
/// no children, does not.
#[test]
fn v11_recognises_an_imported_wrapper_and_nothing_else() {
    let mut connection = migrated_through("v10_focus_points");
    seed_workspace(&connection);
    seed_list(&connection, "imported", "Café Work", T0);
    seed_task(
        &connection,
        "root",
        "imported",
        None,
        "cafe — work",
        Some("checkvist"),
        T0,
    );
    seed_task(
        &connection,
        "child",
        "imported",
        Some("root"),
        "Proposal",
        Some("checkvist"),
        T0,
    );
    seed_list(&connection, "typed", "Home", T0);
    seed_task(&connection, "home", "typed", None, "Home", None, T1);
    seed_task(
        &connection,
        "chore",
        "typed",
        Some("home"),
        "Dishes",
        None,
        T1,
    );
    seed_list(&connection, "bare", "Bare", T0);
    seed_task(
        &connection,
        "bare-root",
        "bare",
        None,
        "Bare",
        Some("checkvist"),
        T0,
    );

    migrate_through(&mut connection, Some("v11_stable_visible_roots")).unwrap();

    assert_eq!(
        visible_root(&connection, "imported").as_deref(),
        Some("root")
    );
    assert_eq!(visible_root(&connection, "typed"), None);
    assert_eq!(visible_root(&connection, "bare"), None);
}

/// v11 also writes the new field into older undo snapshots of the list, so
/// undoing an old edit does not unhide the wrapper. That only works if the
/// row step runs before the snapshot update reads it.
#[test]
fn v11_carries_the_wrapper_into_older_undo_snapshots() {
    let mut connection = migrated_through("v10_focus_points");
    seed_workspace(&connection);
    seed_list(&connection, "imported", "Work", T0);
    seed_task(
        &connection,
        "root",
        "imported",
        None,
        "Work",
        Some("checkvist"),
        T0,
    );
    seed_task(
        &connection,
        "child",
        "imported",
        Some("root"),
        "Proposal",
        Some("checkvist"),
        T0,
    );
    connection
        .execute(
            "INSERT INTO change_log (groupId, label, tableName, rowId, operation, beforeJSON, afterJSON)
             VALUES ('g', 'Edit List', 'task_lists', 'imported', 'update', '{\"name\":\"Old\"}', '{\"name\":\"Work\"}')",
            [],
        )
        .unwrap();

    migrate_through(&mut connection, Some("v11_stable_visible_roots")).unwrap();

    let (before, after): (String, String) = connection
        .query_row(
            "SELECT json_extract(beforeJSON, '$.visibleRootTaskId'), json_extract(afterJSON, '$.visibleRootTaskId')
             FROM change_log WHERE rowId = 'imported'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((before.as_str(), after.as_str()), ("root", "root"));
}

/// v12: each existing workspace gets the four starting conditions.
#[test]
fn v12_gives_every_existing_workspace_its_starting_conditions() {
    let mut connection = migrated_through("v11_stable_visible_roots");
    seed_workspace(&connection);

    migrate_through(&mut connection, Some("v12_task_conditions_and_work")).unwrap();

    let mut statement = connection
        .prepare("SELECT name, isLocation, isArchived, length(id), id = upper(id) FROM task_conditions WHERE workspaceId = 'w' ORDER BY rowid")
        .unwrap();
    let rows: Vec<(String, bool, bool, i64, bool)> = statement
        .query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let names: Vec<(&str, bool)> = rows.iter().map(|r| (r.0.as_str(), r.1)).collect();
    assert_eq!(
        names,
        [
            ("Home", true),
            ("Campus", true),
            ("Private", false),
            ("Floor space", false)
        ]
    );
    assert!(rows.iter().all(|r| !r.2 && r.3 == 36 && r.4));
}

/// v13: an early bulk import (no source system) is recognised only when the
/// wrapper and one of its children were created in the same batch as the
/// list.
#[test]
fn v13_recognises_a_same_batch_wrapper_from_before_source_identity() {
    let mut connection = migrated_through("v12_task_conditions_and_work");
    seed_workspace(&connection);
    seed_list(&connection, "batch", "Work", T0);
    seed_task(&connection, "root", "batch", None, "Work", None, T0);
    seed_task(
        &connection,
        "child",
        "batch",
        Some("root"),
        "Proposal",
        None,
        T0,
    );
    seed_list(&connection, "later", "Home", T0);
    seed_task(&connection, "home", "later", None, "Home", None, T1);
    seed_task(
        &connection,
        "chore",
        "later",
        Some("home"),
        "Dishes",
        None,
        T1,
    );

    migrate_through(&mut connection, Some("v13_legacy_visible_roots")).unwrap();

    assert_eq!(visible_root(&connection, "batch").as_deref(), Some("root"));
    assert_eq!(visible_root(&connection, "later"), None);
}

#[test]
fn a_list_name_folds_case_diacritics_and_punctuation_away() {
    assert_eq!(normalized_visible_root_name("Café — Work!"), "cafework");
    assert_eq!(normalized_visible_root_name("  ÉCOLE 2  "), "ecole2");
    assert_eq!(normalized_visible_root_name("— ."), "");
}

#[test]
fn a_timestamp_is_written_as_grdb_writes_one() {
    let time = std::time::UNIX_EPOCH + std::time::Duration::from_millis(1_700_000_000_123);
    assert_eq!(grdb_timestamp(time), "2023-11-14 22:13:20.123");
    assert_eq!(
        grdb_timestamp(std::time::UNIX_EPOCH),
        "1970-01-01 00:00:00.000"
    );
}

/// The generator a new migration uses to reinstall the journal and outbox
/// triggers writes, on today's schema, exactly the triggers the captured
/// migrations left behind.
#[test]
fn triggers_match_the_fixture() {
    let connection = migrated();
    let stored = |name: &str| -> String {
        connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
                [name],
                |row| row.get(0),
            )
            .unwrap()
    };
    let mut checked = 0;
    for statement in super::triggers::change_log_statements(&connection)
        .unwrap()
        .into_iter()
        .chain(super::triggers::sync_statements(&connection).unwrap())
        .filter(|s| s.starts_with("CREATE TRIGGER"))
    {
        let name = statement.split_whitespace().nth(2).unwrap().to_string();
        assert_eq!(statement, stored(&name), "trigger {name}");
        checked += 1;
    }
    assert_eq!(checked, 8 * 3 + 15 * 3);
    let before = dump_schema(&connection).unwrap();
    super::triggers::reinstall(&connection).unwrap();
    let after = dump_schema(&connection).unwrap();
    // Reinstalling moves each trigger to the end of sqlite_master, so compare
    // the set of statements rather than their order.
    let mut a: Vec<&str> = before.lines().collect();
    let mut b: Vec<&str> = after.lines().collect();
    a.sort_unstable();
    b.sort_unstable();
    assert_eq!(a, b);
}
