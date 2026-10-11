use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// 2024-06-15 12:00:00 UTC.
const NOW: i64 = 1_718_452_800_000;

/// A list, `comp`, whose card `week` is in This week. Beneath it: `a` filed
/// in Backlog, `b` filed nowhere, `c` in This week, `d` waiting, and `sub`
/// filed in In progress, which holds `deep` filed in Backlog. `other` is a
/// second card, in Backlog.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, folderId, name, sortOrder, isArchived, systemRole, createdAt, updatedAt) VALUES
               ('comp', 'w', NULL, 'COMP0169', 0, 0, NULL, '{T}', '{T}'),
               ('home', 'w', NULL, 'Home', 1, 0, NULL, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, itemKind, createdAt, updatedAt) VALUES
               ('week', 'comp', NULL, 'Week 1: viva drills', '', 'open', 0, 'task', '{T}', '{T}'),
               ('a', 'comp', 'week', 'A', '', 'open', 0, 'task', '{T}', '{T}'),
               ('b', 'comp', 'week', 'B', '', 'open', 1, 'task', '{T}', '{T}'),
               ('c', 'comp', 'week', 'C', '', 'open', 2, 'task', '{T}', '{T}'),
               ('d', 'comp', 'week', 'D', '', 'open', 3, 'task', '{T}', '{T}'),
               ('sub', 'comp', 'week', 'Sub', '', 'open', 4, 'task', '{T}', '{T}'),
               ('deep', 'comp', 'sub', 'Deep', '', 'open', 0, 'task', '{T}', '{T}'),
               ('other', 'comp', NULL, 'Other', 'notes', 'open', 1, 'task', '{T}', '{T}'),
               ('chair', 'home', NULL, 'Chair', '', 'open', 0, 'task', '{T}', '{T}');
             INSERT INTO task_metadata (taskId, priority, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt) VALUES
               ('week', NULL, '[]', '[]', 'this-week', '{T}'),
               ('a', NULL, '[\"Urgent\"]', '[]', 'backlog', '{T}'),
               ('c', NULL, '[]', '[]', 'this-week', '{T}'),
               ('d', NULL, '[]', '[]', 'waiting-on', '{T}'),
               ('sub', NULL, '[]', '[]', 'in-progress', '{T}'),
               ('deep', NULL, '[]', '[]', 'backlog', '{T}'),
               ('other', 2, '[]', '[]', 'backlog', '{T}');"
        ))
        .unwrap();
    connection
}

fn ids(columns: &[BoardColumn]) -> Vec<&str> {
    columns.iter().map(|column| column.id.as_str()).collect()
}

fn read(connection: &Connection, key: &str, lists: &[&str]) -> BoardColumns {
    let lists: Vec<String> = lists.iter().map(|id| id.to_string()).collect();
    board_columns(connection, key, &lists, NOW, "UTC").unwrap()
}

fn placed(board: &BoardColumns, task: &str) -> Option<String> {
    board
        .placements
        .iter()
        .find(|placement| placement.task_id == task)
        .map(|placement| placement.column_id.clone())
}

/// Where a client draws `task`: placed, or by its filed column alone.
fn at(connection: &Connection, board: &BoardColumns, task: &str) -> String {
    placed(board, task).unwrap_or_else(|| {
        let wanted = filed(connection, task).unwrap_or_else(|| FIRST_STOCK_COLUMN_ID.into());
        if board.columns.iter().any(|column| column.id == wanted) {
            wanted
        } else {
            board.columns[0].id.clone()
        }
    })
}

fn column(id: &str, title: &str) -> BoardColumn {
    BoardColumn {
        id: id.into(),
        title: title.into(),
        rules: None,
    }
}

fn rule_column(id: &str, title: &str, rules: &[(&str, &str, &str)]) -> BoardColumn {
    BoardColumn {
        id: id.into(),
        title: title.into(),
        rules: Some(FilterDefinition {
            rules: rules
                .iter()
                .map(|(field, op, value)| FilterRule {
                    field: (*field).into(),
                    op: (*op).into(),
                    value: (*value).into(),
                })
                .collect(),
            ..FilterDefinition::default()
        }),
    }
}

fn set_layout(connection: &mut Connection, key: &str, columns: &[BoardColumn]) {
    journalled(connection, "Edit Board", |tx| {
        set_board_columns(tx, key, columns, &[], None, NOW)
    })
    .unwrap();
}

fn filed(connection: &Connection, task: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
            [task],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
        .flatten()
}

#[test]
fn a_board_without_its_own_columns_follows_its_list_then_the_default_then_the_stock() {
    let mut connection = workspace();
    let board = read(&connection, "comp/root", &["comp"]);
    assert_eq!(board.source, "builtin");
    assert_eq!(board.layout, board_stock_columns());

    set_layout(
        &mut connection,
        DEFAULT_BOARD_KEY,
        &[column("todo", "To do"), column("done", "Done")],
    );
    let board = read(&connection, "home/root", &["home"]);
    assert_eq!(board.source, "default");
    assert_eq!(ids(&board.layout), ["todo", "done"]);
    assert_eq!(
        read(&connection, EVERYTHING_BOARD_KEY, &[]).source,
        "default"
    );

    set_layout(
        &mut connection,
        "comp/root",
        &[column("x", "X"), column("this-week", "This week")],
    );
    assert_eq!(read(&connection, "comp/root", &["comp"]).source, "own");
    // A board entered on a task uses its list's.
    let entered = read(&connection, "comp/other", &["comp"]);
    assert_eq!(entered.source, "list");
    assert_eq!(ids(&entered.layout), ["x", "this-week"]);
    // Home still follows the default.
    assert_eq!(read(&connection, "home/root", &["home"]).source, "default");
}

#[test]
fn a_card_filed_in_a_column_the_layout_lacks_keeps_a_column_of_its_own() {
    let mut connection = workspace();
    set_layout(
        &mut connection,
        "comp/root",
        &[column("backlog", "Backlog")],
    );
    let board = read(&connection, "comp/root", &["comp"]);
    // `this-week`, `waiting-on` and `in-progress` are filed here and in the stock set.
    assert_eq!(
        ids(&board.columns),
        ["backlog", "in-progress", "this-week", "waiting-on"]
    );
    assert_eq!(ids(&board.layout), ["backlog"]);
}

#[test]
fn entering_a_card_hides_the_columns_before_its_own_and_clamps_its_children() {
    let connection = workspace();
    let board = read(&connection, "comp/week", &["comp"]);
    assert_eq!(board.hidden_column_ids, ["backlog", "in-progress"]);
    assert_eq!(board.floor_column_id.as_deref(), Some("this-week"));
    assert_eq!(ids(&board.columns), ["this-week", "waiting-on", "today"]);
    // Filed in a hidden column, or nowhere: drawn in the card's column.
    assert_eq!(at(&connection, &board, "a"), "this-week");
    assert_eq!(at(&connection, &board, "b"), "this-week");
    assert_eq!(at(&connection, &board, "sub"), "this-week");
    // Already somewhere drawn: where it is filed.
    assert_eq!(placed(&board, "c"), None);
    assert_eq!(placed(&board, "d"), None);
    // Nothing is rewritten.
    assert_eq!(filed(&connection, "a").as_deref(), Some("backlog"));
    // The list's own board is untouched.
    let list = read(&connection, "comp/root", &["comp"]);
    assert!(list.hidden_column_ids.is_empty());
    assert_eq!(list.columns, board_stock_columns());
}

#[test]
fn moving_the_entered_card_moves_what_it_hides() {
    let mut connection = workspace();
    journalled(&mut connection, "Move Task", |tx| {
        crate::tasks::set_kanban_column(tx, &["week".into()], Some("today"), NOW)
    })
    .unwrap();
    let board = read(&connection, "comp/week", &["comp"]);
    // Waiting on is not a stage, so it stays.
    assert_eq!(ids(&board.columns), ["waiting-on", "today"]);
    assert_eq!(placed(&board, "c").as_deref(), Some("today"));
    assert_eq!(placed(&board, "b").as_deref(), Some("today"));
    assert_eq!(placed(&board, "d"), None);

    // In Waiting on or in Backlog, it hides nothing.
    for at in ["waiting-on", "backlog"] {
        journalled(&mut connection, "Move Task", |tx| {
            crate::tasks::set_kanban_column(tx, &["week".into()], Some(at), NOW)
        })
        .unwrap();
        let board = read(&connection, "comp/week", &["comp"]);
        assert!(board.hidden_column_ids.is_empty(), "{at}");
        assert_eq!(board.floor_column_id, None);
        assert!(board.placements.is_empty(), "{at}");
    }
}

#[test]
fn entering_twice_takes_the_floor_the_middle_card_is_drawn_at() {
    let mut connection = workspace();
    // `sub` is filed in In progress, but on Week 1's board it is drawn in
    // This week, so its own board starts at This week.
    let board = read(&connection, "comp/sub", &["comp"]);
    assert_eq!(board.floor_column_id.as_deref(), Some("this-week"));
    assert_eq!(at(&connection, &board, "deep"), "this-week");

    // Filed in Today, it starts at Today.
    journalled(&mut connection, "Move Task", |tx| {
        crate::tasks::set_kanban_column(tx, &["sub".into()], Some("today"), NOW)
    })
    .unwrap();
    let board = read(&connection, "comp/sub", &["comp"]);
    assert_eq!(board.floor_column_id.as_deref(), Some("today"));
    assert_eq!(placed(&board, "deep").as_deref(), Some("today"));

    // And when Week 1 moves to Backlog, `sub` is drawn where it is filed.
    journalled(&mut connection, "Move Task", |tx| {
        crate::tasks::set_kanban_column(
            tx,
            &["week".into(), "sub".into()],
            Some("in-progress"),
            NOW,
        )
    })
    .unwrap();
    let board = read(&connection, "comp/sub", &["comp"]);
    assert_eq!(board.floor_column_id.as_deref(), Some("in-progress"));
    assert_eq!(board.hidden_column_ids, ["backlog"]);
}

#[test]
fn a_rule_column_holds_what_its_rules_match_and_the_first_match_wins() {
    let mut connection = workspace();
    set_layout(
        &mut connection,
        "comp/root",
        &[
            column("backlog", "Backlog"),
            rule_column("urgent", "Urgent", &[("tag", "has", "urgent")]),
            rule_column("important", "Important", &[("priority", "at-least", "2")]),
            rule_column("tagged", "Tagged", &[("tag", "any", "")]),
            column("done", "Done"),
        ],
    );
    let board = read(&connection, "comp/root", &["comp"]);
    assert_eq!(placed(&board, "a").as_deref(), Some("urgent"));
    assert_eq!(placed(&board, "other").as_deref(), Some("important"));
    // Filed in a column this layout lacks, it keeps one of its own.
    assert!(ids(&board.columns).contains(&"this-week"));
    assert_eq!(placed(&board, "c"), None);
    let rules = board.layout[1].rules.as_ref().unwrap();
    assert_eq!(rules.rules[0].value, "urgent");

    // The rules survive the round trip through the stored JSON.
    let json: String = connection
        .query_row(
            "SELECT columnsJSON FROM kanban_boards WHERE id = 'comp/root'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(parse_columns(&json).unwrap(), board.layout);
}

#[test]
fn a_task_filed_in_a_column_that_became_a_rule_column_falls_back() {
    let mut connection = workspace();
    set_layout(
        &mut connection,
        "comp/root",
        &[
            column("this-week", "This week"),
            rule_column("backlog", "Backlog", &[("text", "contains", "zzz")]),
        ],
    );
    let board = read(&connection, "comp/root", &["comp"]);
    assert_eq!(placed(&board, "other").as_deref(), Some("this-week"));
}

#[test]
fn dropping_into_a_rule_column_edits_the_task_to_match() {
    let mut connection = workspace();
    set_layout(
        &mut connection,
        "comp/root",
        &[
            column("backlog", "Backlog"),
            rule_column("urgent", "Urgent", &[("tag", "has", "urgent")]),
            rule_column(
                "soon",
                "Soon",
                &[("priority", "at-least", "3"), ("due", "within", "2")],
            ),
            rule_column("plan", "Planned", &[("today", "is", "")]),
            rule_column("text", "Mentions", &[("text", "contains", "viva")]),
        ],
    );
    let drop = |connection: &mut Connection, task: &str, column: &str| {
        journalled(connection, "Move Task", |tx| {
            move_to_board_column(tx, "comp/root", &[task.to_string()], column, NOW, "UTC")
        })
    };

    drop(&mut connection, "chair", "urgent").unwrap();
    let tags: String = connection
        .query_row(
            "SELECT tagsJSON FROM task_metadata WHERE taskId = 'chair'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tags, "[\"urgent\"]");
    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("Move Task"));

    drop(&mut connection, "c", "soon").unwrap();
    let (priority, planning): (Option<i64>, Option<String>) = connection
        .query_row(
            "SELECT priority, planningJSON FROM task_metadata WHERE taskId = 'c'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(priority, Some(3));
    assert!(planning.unwrap().contains("2024-06-15"));
    assert_eq!(
        placed(&read(&connection, "comp/root", &["comp"]), "c").as_deref(),
        Some("soon")
    );

    drop(&mut connection, "b", "plan").unwrap();
    assert_eq!(filed(&connection, "b").as_deref(), Some("today"));

    // No edit makes "title contains viva" true.
    let refused = drop(&mut connection, "other", "text").unwrap_err();
    assert!(
        matches!(refused, CoreError::ColumnRefused { .. }),
        "{refused:?}"
    );
    assert!(refused.to_string().contains("Mentions"));

    // Into Planned, `a` would still be caught by Urgent first: refused, and
    // nothing saved.
    let refused = drop(&mut connection, "a", "plan").unwrap_err();
    assert!(refused.to_string().contains("Urgent"), "{refused}");
    assert_eq!(filed(&connection, "a").as_deref(), Some("backlog"));

    // Nor can it be filed in Backlog while it matches Urgent.
    journalled(&mut connection, "Move Task", |tx| {
        crate::tasks::set_kanban_column(tx, &["a".into()], Some("this-week"), NOW)
    })
    .unwrap();
    assert!(drop(&mut connection, "a", "backlog").is_err());
    assert_eq!(filed(&connection, "a").as_deref(), Some("this-week"));
    // An ordinary drop of a task no rule column holds is just filed.
    drop(&mut connection, "d", "backlog").unwrap();
    assert_eq!(filed(&connection, "d").as_deref(), Some("backlog"));
}

#[test]
fn deleting_a_column_moves_its_tasks_in_one_step() {
    let mut connection = workspace();
    let lists = vec!["comp".to_string()];
    journalled(&mut connection, "Delete Column", |tx| {
        delete_board_column(tx, "comp/root", &lists, "backlog", Some("in-progress"), NOW)
    })
    .unwrap();
    let board = read(&connection, "comp/root", &["comp"]);
    assert_eq!(board.source, "own");
    assert!(!ids(&board.layout).contains(&"backlog"));
    for task in ["a", "deep", "other"] {
        assert_eq!(
            filed(&connection, task).as_deref(),
            Some("in-progress"),
            "{task}"
        );
    }
    // Home follows the default still.
    assert_eq!(read(&connection, "home/root", &["home"]).source, "builtin");
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Delete Column")
    );
    assert_eq!(filed(&connection, "a").as_deref(), Some("backlog"));
    assert_eq!(read(&connection, "comp/root", &["comp"]).source, "builtin");

    // Today and Waiting on keep their tasks planned or waiting.
    journalled(&mut connection, "Delete Column", |tx| {
        delete_board_column(tx, "comp/root", &lists, "waiting-on", Some("backlog"), NOW)
    })
    .unwrap();
    assert_eq!(filed(&connection, "d").as_deref(), Some("waiting-on"));

    // On an entered board, only what is beneath the entered card moves.
    journalled(&mut connection, "Delete Column", |tx| {
        delete_board_column(tx, "comp/week", &lists, "backlog", Some("this-week"), NOW)
    })
    .unwrap();
    assert_eq!(filed(&connection, "a").as_deref(), Some("this-week"));
    assert_eq!(filed(&connection, "other").as_deref(), Some("backlog"));

    // The last column stays.
    set_layout(&mut connection, "home/root", &[column("only", "Only")]);
    let refused = journalled(&mut connection, "Delete Column", |tx| {
        delete_board_column(tx, "home/root", &[], "only", None, NOW)
    });
    assert!(matches!(refused, Err(CoreError::ColumnRefused { .. })));
}

#[test]
fn a_board_can_set_the_default_and_go_back_to_following_it() {
    let mut connection = workspace();
    set_layout(
        &mut connection,
        "comp/root",
        &[column("todo", "To do"), column("done", "Done")],
    );
    journalled(&mut connection, "Make Default Columns", |tx| {
        make_default_board_columns(tx, "comp/root")
    })
    .unwrap();
    assert_eq!(read(&connection, "comp/root", &["comp"]).source, "default");
    let home = read(&connection, "home/root", &["home"]);
    assert_eq!(
        (home.source.as_str(), ids(&home.layout)),
        ("default", vec!["todo", "done"])
    );

    set_layout(&mut connection, "home/root", &[column("x", "X")]);
    journalled(&mut connection, "Reset Columns", |tx| {
        reset_board_columns(tx, "home/root")
    })
    .unwrap();
    assert_eq!(read(&connection, "home/root", &["home"]).source, "default");
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Reset Columns")
    );
    assert_eq!(read(&connection, "home/root", &["home"]).source, "own");
}

#[test]
fn saving_refuses_bad_layouts_and_drops_empty_rules() {
    let mut connection = workspace();
    let bad = journalled(&mut connection, "Edit Board", |tx| {
        set_board_columns(
            tx,
            "comp/root",
            &[column("a", "A"), column("a", "B")],
            &[],
            None,
            NOW,
        )
    });
    assert!(matches!(bad, Err(CoreError::ColumnRefused { .. })));
    let bad = journalled(&mut connection, "Edit Board", |tx| {
        set_board_columns(
            tx,
            "comp/root",
            &[rule_column("r", "R", &[("nonsense", "is", "")])],
            &[],
            None,
            NOW,
        )
    });
    assert!(matches!(bad, Err(CoreError::InvalidFilter { .. })));
    set_layout(&mut connection, "comp/root", &[rule_column("r", "R", &[])]);
    assert_eq!(
        read(&connection, "comp/root", &["comp"]).layout[0].rules,
        None
    );
}
