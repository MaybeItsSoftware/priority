use rusqlite::Connection;

use super::*;
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
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt, systemRole)
               VALUES ('inbox', 'w', 'Inbox', 0, '{T}', '{T}', 'inbox');
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt)
               VALUES ('a', 'inbox', 'Alpha', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn outbox(connection: &Connection) -> i64 {
    connection
        .query_row("SELECT COUNT(*) FROM sync_outbox", [], |row| row.get(0))
        .unwrap()
}

fn text(value: &str) -> SyncValue {
    SyncValue::Text {
        value: value.into(),
    }
}

#[test]
fn pairing_snapshots_every_row_and_edits_coalesce_per_row() {
    let mut connection = workspace();
    let tx = connection.transaction().unwrap();
    begin(&tx, "device-1", "https://sync.example").unwrap();
    enqueue_snapshot(&tx, 1_000).unwrap();
    tx.commit().unwrap();
    let state = state(&connection).unwrap().unwrap();
    assert_eq!(
        (
            state.device_id.as_str(),
            state.needs_snapshot,
            state.is_recording
        ),
        ("device-1", false, true)
    );

    let snapshot = pending_changes(&connection, 500).unwrap();
    let tables: Vec<&str> = snapshot.changes.iter().map(|c| c.table.as_str()).collect();
    assert_eq!(tables, ["workspaces", "task_lists", "tasks"]);
    assert!(snapshot.changes.iter().all(|c| c.operation == "upsert"));
    let tx = connection.transaction().unwrap();
    acknowledge(&tx, snapshot.through_seq.unwrap()).unwrap();
    tx.commit().unwrap();
    assert_eq!(outbox(&connection), 0);

    connection
        .execute_batch("UPDATE tasks SET title = 'Beta' WHERE id = 'a'; UPDATE tasks SET notes = 'n' WHERE id = 'a';")
        .unwrap();
    let edits = pending_changes(&connection, 500).unwrap();
    assert_eq!(edits.changes.len(), 1);
    let values = &edits.changes[0].values;
    assert_eq!(values.get("title"), Some(&text("Beta")));
    assert_eq!(values.get("notes"), Some(&text("n")));
    assert_eq!(values.get("id"), Some(&text("a")));
    assert!(!values.contains_key("sortOrder"));

    connection
        .execute("DELETE FROM tasks WHERE id = 'a'", [])
        .unwrap();
    let gone = pending_changes(&connection, 500).unwrap();
    assert_eq!(
        (
            gone.changes[0].operation.as_str(),
            gone.changes[0].values.len()
        ),
        ("delete", 0)
    );
}

#[test]
fn a_pull_applies_without_echoing_and_leaves_rows_with_local_edits() {
    let mut connection = workspace();
    let tx = connection.transaction().unwrap();
    begin(&tx, "d", "s").unwrap();
    enqueue_snapshot(&tx, 1).unwrap();
    let through = pending_changes(&tx, 500).unwrap().through_seq.unwrap();
    acknowledge(&tx, through).unwrap();
    tx.commit().unwrap();

    connection
        .execute("UPDATE tasks SET title = 'Mine' WHERE id = 'a'", [])
        .unwrap();
    let rows = vec![
        IncomingRow {
            table: "tasks".into(),
            id: "a".into(),
            deleted: false,
            values: HashMap::from([("title".into(), text("Theirs"))]),
            hlc: None,
        },
        IncomingRow {
            table: "tasks".into(),
            id: "b".into(),
            deleted: false,
            values: HashMap::from([
                ("listId".into(), text("inbox")),
                ("title".into(), text("From the phone")),
                ("sortOrder".into(), SyncValue::Integer { value: 1 }),
                ("createdAt".into(), text(T)),
                ("updatedAt".into(), text(T)),
                ("unknownColumn".into(), text("ignored")),
            ]),
            hlc: Some("h1".into()),
        },
    ];
    let before = outbox(&connection);
    let tx = connection.transaction().unwrap();
    assert!(apply_remote_rows(&tx, &rows, 7, Some("h1"), 2_000).unwrap());
    tx.commit().unwrap();
    let title = |id: &str| -> String {
        connection
            .query_row("SELECT title FROM tasks WHERE id = ?1", [id], |r| r.get(0))
            .unwrap()
    };
    assert_eq!(title("a"), "Mine");
    assert_eq!(title("b"), "From the phone");
    assert_eq!(outbox(&connection), before);
    let state = state(&connection).unwrap().unwrap();
    assert_eq!((state.cursor, state.hlc.as_deref()), (7, Some("h1")));

    let delete = vec![IncomingRow {
        table: "tasks".into(),
        id: "b".into(),
        deleted: true,
        values: HashMap::new(),
        hlc: None,
    }];
    let tx = connection.transaction().unwrap();
    assert!(apply_remote_rows(&tx, &delete, 8, None, 3_000).unwrap());
    tx.commit().unwrap();
    let left: i64 = connection
        .query_row("SELECT COUNT(*) FROM tasks WHERE id = 'b'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(left, 0);
}

#[test]
fn two_ticks_of_one_daily_keep_the_smaller_id_and_the_most_time() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO dailies (id, taskId, sortOrder, createdAt, updatedAt) VALUES ('d', 'a', 0, '{T}', '{T}');
             INSERT INTO daily_contributions (id, dailyId, taskId, dayKey, secondsLogged, completedAt, createdAt)
               VALUES ('B-LOCAL', 'd', 'a', '2026-03-11', 300, NULL, '{T}');"
        ))
        .unwrap();
    let tx = connection.transaction().unwrap();
    begin(&tx, "d", "s").unwrap();
    enqueue_snapshot(&tx, 1).unwrap();
    let through = pending_changes(&tx, 500).unwrap().through_seq.unwrap();
    acknowledge(&tx, through).unwrap();
    let incoming = vec![IncomingRow {
        table: "daily_contributions".into(),
        id: "A-REMOTE".into(),
        deleted: false,
        values: HashMap::from([
            ("dailyId".into(), text("d")),
            ("taskId".into(), text("a")),
            ("dayKey".into(), text("2026-03-11")),
            ("secondsLogged".into(), SyncValue::Integer { value: 900 }),
            ("completedAt".into(), text("2026-03-11 09:00:00.000")),
            ("createdAt".into(), text(T)),
        ]),
        hlc: None,
    }];
    apply_remote_rows(&tx, &incoming, 1, None, 2).unwrap();
    tx.commit().unwrap();
    let rows: Vec<(String, i64, Option<String>)> = {
        let mut statement = connection
            .prepare("SELECT id, secondsLogged, completedAt FROM daily_contributions")
            .unwrap();
        statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(
        rows,
        [(
            "A-REMOTE".into(),
            900,
            Some("2026-03-11 09:00:00.000".into())
        )]
    );
    let tombstoned: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sync_outbox WHERE rowId = 'B-LOCAL' AND operation = 'delete'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(tombstoned, 1);
}

#[test]
fn a_second_workspace_folds_into_the_canonical_one() {
    let mut connection = workspace();
    let tx = connection.transaction().unwrap();
    begin(&tx, "d", "s").unwrap();
    let remote = vec![
        IncomingRow {
            table: "workspaces".into(),
            id: "server".into(),
            deleted: false,
            values: HashMap::from([
                ("name".into(), text("Theirs")),
                ("createdAt".into(), text("2023-01-01 00:00:00.000")),
                ("updatedAt".into(), text(T)),
            ]),
            hlc: None,
        },
        IncomingRow {
            table: "task_lists".into(),
            id: "server-inbox".into(),
            deleted: false,
            values: HashMap::from([
                ("workspaceId".into(), text("server")),
                ("name".into(), text("Inbox")),
                ("sortOrder".into(), SyncValue::Integer { value: 0 }),
                ("isArchived".into(), SyncValue::Integer { value: 0 }),
                ("systemRole".into(), text("inbox")),
                ("createdAt".into(), text(T)),
                ("updatedAt".into(), text(T)),
            ]),
            hlc: None,
        },
    ];
    assert!(apply_remote_rows(&tx, &remote, 1, None, 5).unwrap());
    tx.commit().unwrap();
    let workspaces: Vec<String> = {
        let mut s = connection.prepare("SELECT id FROM workspaces").unwrap();
        s.query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(workspaces, ["server"]);
    let list: String = connection
        .query_row("SELECT listId FROM tasks WHERE id = 'a'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(list, "server-inbox");
}

#[test]
fn base64_matches_the_standard_alphabet() {
    assert_eq!(base64(b"Man"), "TWFu");
    assert_eq!(base64(b"Ma"), "TWE=");
    assert_eq!(base64(b"M"), "TQ==");
}

#[test]
fn the_clock_is_the_servers() {
    assert_eq!(
        hlc_tick(None, "MAC".into(), 1_000).as_deref(),
        Some("0000000001000-0000-MAC")
    );
    assert_eq!(
        hlc_tick(Some("0000000001000-0000-MAC".into()), "MAC".into(), 900).as_deref(),
        Some("0000000001000-0001-MAC")
    );
    assert_eq!(
        hlc_receive(
            "0000000001000-0001-MAC".into(),
            "0000000002000-0005-PHONE".into(),
            1_500
        )
        .as_deref(),
        Some("0000000002000-0006-MAC")
    );
    assert_eq!(hlc_tick(Some("junk".into()), "MAC".into(), 1), None);
}
