use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// 2024-06-15 12:00:00 UTC, a Saturday.
const NOW: i64 = 1_718_452_800_000;
const DAY: i64 = 86_400_000;

/// Two lists, one in a folder inside another; an archived list; a wrapper
/// list whose visible root is a task; a list item holding a task; and tasks
/// carrying every fact a rule reads.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    let due = |offset_days: i64| crate::time::stored(NOW + offset_days * DAY);
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO list_folders (id, workspaceId, parentFolderId, name, sortOrder, createdAt, updatedAt) VALUES
               ('outer', 'w', NULL, 'Outer', 0, '{T}', '{T}'),
               ('inner', 'w', 'outer', 'Inner', 0, '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, folderId, name, sortOrder, isArchived, systemRole, createdAt, updatedAt) VALUES
               ('inbox', 'w', NULL, 'Inbox', 5, 0, 'inbox', '{T}', '{T}'),
               ('work', 'w', 'inner', 'Work', 0, 0, NULL, '{T}', '{T}'),
               ('home', 'w', NULL, 'Home', 1, 0, NULL, '{T}', '{T}'),
               ('gone', 'w', NULL, 'Gone', 2, 1, NULL, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds, itemKind, completedAt, createdAt, updatedAt) VALUES
               ('report', 'work', NULL, 'Write report', '', 'open', 0, '{late}', 3600, 'task', NULL, '{T}', '{T}'),
               ('call', 'work', NULL, 'Call Sam', 'about the invoice', 'open', 1, '{soon}', 600, 'task', NULL, '{T}', '{T}'),
               ('filed', 'work', NULL, 'Filed', '', 'completed', 2, NULL, NULL, 'task', '{T}', '{T}', '{T}'),
               ('shelf', 'home', NULL, 'Shelf', '', 'open', 0, NULL, NULL, 'task', NULL, '{T}', '{T}'),
               ('reading', 'home', NULL, 'Reading', '', 'open', 1, NULL, NULL, 'list', NULL, '{T}', '{T}'),
               ('paper', 'home', 'reading', 'Paper', '', 'open', 0, NULL, NULL, 'task', NULL, '{T}', '{T}'),
               ('old', 'home', NULL, 'Old', '', 'open', 2, NULL, NULL, 'list', NULL, '{T}', '{T}'),
               ('stale', 'home', 'old', 'Stale', '', 'open', 0, NULL, NULL, 'task', NULL, '{T}', '{T}'),
               ('lost', 'gone', NULL, 'Lost', '', 'open', 0, '{late}', NULL, 'task', NULL, '{T}', '{T}'),
               ('wrapper', 'inbox', NULL, 'Inbox', '', 'open', 0, NULL, NULL, 'task', NULL, '{T}', '{T}'),
               ('idea', 'inbox', 'wrapper', 'Idea', '', 'open', 0, NULL, NULL, 'task', NULL, '{T}', '{T}');
             UPDATE tasks SET archivedAt = '{T}' WHERE id = 'old';
             UPDATE task_lists SET visibleRootTaskId = 'wrapper' WHERE id = 'inbox';
             INSERT INTO task_metadata (taskId, priority, startAt, tagsJSON, kanbanColumn, planningJSON, waitingOn, updatedAt) VALUES
               ('report', 3, NULL, '[\"Work\",\"#urgent\"]', 'today', NULL, NULL, '{T}'),
               ('call', 1, '{future}', '[\"work\"]', 'waiting-on', NULL, 'Sam Jones', '{T}'),
               ('shelf', NULL, '{T}', '[]', NULL, '{{\"dueDate\":\"2024-06-15\"}}', NULL, '{T}'),
               ('paper', 2, NULL, '[\"reading\"]', 'doing', NULL, NULL, '{T}');
             INSERT INTO task_dependencies (id, taskId, blockedByTaskId, createdAt) VALUES ('d', 'paper', 'shelf', '{T}');",
            late = due(-2),
            soon = due(3),
            future = due(5),
        ))
        .unwrap();
    connection
}

fn rule(field: &str, op: &str, value: &str) -> FilterRule {
    FilterRule {
        field: field.into(),
        op: op.into(),
        value: value.into(),
    }
}

fn definition(match_mode: &str, show: &str, rules: Vec<FilterRule>) -> FilterDefinition {
    FilterDefinition {
        match_mode: match_mode.into(),
        show: show.into(),
        rules,
    }
}

/// The ids `rules` (all of them, open tasks) show, in board order.
fn shown(connection: &Connection, rules: Vec<FilterRule>) -> Vec<String> {
    shown_by(connection, &definition("all", "open", rules))
}

fn shown_by(connection: &Connection, definition: &FilterDefinition) -> Vec<String> {
    tasks(connection, "w", definition, NOW, "UTC")
        .unwrap()
        .into_iter()
        .map(|task| task.id)
        .collect()
}

#[test]
fn no_rules_shows_every_open_task_a_board_could_draw() {
    let connection = workspace();
    // Not the finished task, not inside the archived list item, not in the
    // archived list, not the inbox's wrapper or a list item; the inbox first.
    assert_eq!(
        shown(&connection, vec![]),
        ["idea", "report", "call", "shelf", "paper"]
    );
}

#[test]
fn everything_built_in_is_the_combined_boards_cards() {
    let connection = workspace();
    let everything = builtin_filter_lists()
        .into_iter()
        .find(|row| row.id == BUILTIN_EVERYTHING_ID)
        .unwrap();
    let lists = scope_list_ids(&connection, "w").unwrap();
    let cards: Vec<String> = board::cards_of(&connection, &lists, None)
        .unwrap()
        .into_iter()
        .map(|task| task.id)
        .collect();
    assert_eq!(shown_by(&connection, &everything.definition), cards);
}

#[test]
fn today_built_in_is_planned_for_today_or_due_by_today() {
    let connection = workspace();
    let today = builtin_filter_lists().remove(0);
    assert_eq!(today.id, BUILTIN_TODAY_ID);
    // `report` is planned and late; `shelf` has a due date of today.
    assert_eq!(
        shown_by(&connection, &today.definition),
        ["report", "shelf"]
    );
}

#[test]
fn tags_compare_without_case_or_hash() {
    let connection = workspace();
    assert_eq!(
        shown(&connection, vec![rule("tag", "has", "#WORK")]),
        ["report", "call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("tag", "has", "urgent")]),
        ["report"]
    );
    assert_eq!(
        shown(&connection, vec![rule("tag", "lacks", "work")]),
        ["idea", "shelf", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("tag", "none", "")]),
        ["idea", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("tag", "any", "")]),
        ["report", "call", "paper"]
    );
}

#[test]
fn due_dates_read_the_deadline_or_the_planned_day() {
    let connection = workspace();
    assert_eq!(
        shown(&connection, vec![rule("due", "overdue", "")]),
        ["report"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "today", "")]),
        ["shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "within", "3")]),
        ["report", "call", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "within", "0")]),
        ["report", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "before", "2024-06-15")]),
        ["report"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "on", "2024-06-18")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "after", "2024-06-15")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("due", "none", "")]),
        ["idea", "paper"]
    );
}

#[test]
fn start_dates_and_the_rest_of_the_fields() {
    let connection = workspace();
    assert_eq!(
        shown(&connection, vec![rule("start", "started", "")]),
        ["shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("start", "later", "")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("start", "within", "5")]),
        ["call", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("priority", "at-least", "2")]),
        ["report", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("priority", "at-most", "1")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("priority", "is", "2")]),
        ["paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("priority", "none", "")]),
        ["idea", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("list", "in", "home, inbox")]),
        ["idea", "shelf", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("list", "not-in", "home,inbox")]),
        ["report", "call"]
    );
    // `work` is in `inner`, inside `outer`.
    assert_eq!(
        shown(&connection, vec![rule("folder", "in", "outer")]),
        ["report", "call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("folder", "not-in", "inner")]),
        ["idea", "shelf", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("today", "is", "")]),
        ["report"]
    );
    assert_eq!(
        shown(&connection, vec![rule("blocked", "is", "")]),
        ["paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("blocked", "is-not", "")]),
        ["idea", "report", "call", "shelf"]
    );
    assert_eq!(
        shown(&connection, vec![rule("waiting", "is", "")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("waiting", "on", "sam")]),
        ["call"]
    );
    assert!(shown(&connection, vec![rule("waiting", "on", "alex")]).is_empty());
    assert_eq!(
        shown(&connection, vec![rule("estimate", "at-least", "30")]),
        ["report"]
    );
    assert_eq!(
        shown(&connection, vec![rule("estimate", "at-most", "10")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("estimate", "none", "")]),
        ["idea", "shelf", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("text", "contains", "INVOICE")]),
        ["call"]
    );
    assert_eq!(
        shown(&connection, vec![rule("text", "lacks", "invoice")]),
        ["idea", "report", "shelf", "paper"]
    );
    assert_eq!(
        shown(&connection, vec![rule("column", "is", "doing")]),
        ["paper"]
    );
}

#[test]
fn rules_combine_by_all_or_any_and_show_picks_the_status() {
    let connection = workspace();
    let both = vec![
        rule("tag", "has", "work"),
        rule("priority", "at-least", "2"),
    ];
    assert_eq!(
        shown_by(&connection, &definition("all", "open", both.clone())),
        ["report"]
    );
    assert_eq!(
        shown_by(&connection, &definition("any", "open", both)),
        ["report", "call", "paper"]
    );
    assert_eq!(
        shown_by(
            &connection,
            &definition("all", "done", vec![rule("list", "in", "work")])
        ),
        ["filed"]
    );
    assert_eq!(
        shown_by(
            &connection,
            &definition("all", "all", vec![rule("list", "in", "work")])
        ),
        ["report", "call", "filed"]
    );
}

#[test]
fn an_unknown_rule_is_skipped_and_an_unreadable_definition_shows_nothing() {
    let mut connection = workspace();
    assert_eq!(
        shown(
            &connection,
            vec![rule("mood", "is", "sunny"), rule("tag", "has", "urgent")]
        ),
        ["report"]
    );
    connection
        .execute(
            "INSERT INTO filter_lists (id, workspaceId, name, rulesJSON, sortOrder, createdAt, updatedAt)
             VALUES ('bad', 'w', 'Bad', 'not json', 0, ?1, ?1)",
            [T],
        )
        .unwrap();
    let bad = filter_list(&connection, "bad").unwrap().unwrap();
    assert!(shown_by(&connection, &bad.definition).is_empty());
    // And it can be repaired.
    journalled(&mut connection, "Edit Filter List", |tx| {
        update(
            tx,
            "bad",
            "Fixed",
            None,
            None,
            &FilterDefinition::default(),
            NOW,
        )
    })
    .unwrap();
    assert_eq!(
        shown_by(
            &connection,
            &filter_list(&connection, "bad").unwrap().unwrap().definition
        )
        .len(),
        5
    );
}

#[test]
fn validation_tidies_values_and_refuses_what_cannot_be_evaluated() {
    let tidy = validate(&definition(
        "any",
        "all",
        vec![
            rule("tag", "has", "  #Work "),
            rule("list", "in", " a, ,b "),
            rule("due", "within", " 7 "),
            rule("blocked", "is", "ignored"),
        ],
    ))
    .unwrap();
    assert_eq!(
        tidy.rules,
        [
            rule("tag", "has", "work"),
            rule("list", "in", "a,b"),
            rule("due", "within", "7"),
            rule("blocked", "is", ""),
        ]
    );
    for bad in [
        definition("most", "open", vec![]),
        definition("all", "some", vec![]),
        definition("all", "open", vec![rule("mood", "is", "x")]),
        definition("all", "open", vec![rule("tag", "is", "x")]),
        definition("all", "open", vec![rule("tag", "has", " # ")]),
        definition("all", "open", vec![rule("due", "within", "-1")]),
        definition("all", "open", vec![rule("due", "before", "15/06/2024")]),
        definition("all", "open", vec![rule("priority", "at-least", "high")]),
        definition("all", "open", vec![rule("list", "in", " , ")]),
        definition("all", "open", vec![rule("text", "contains", "  ")]),
    ] {
        assert!(
            matches!(validate(&bad), Err(CoreError::InvalidFilter { .. })),
            "{bad:?}"
        );
    }
}

#[test]
fn the_json_is_stable_and_tolerant() {
    let definition = definition(
        "any",
        "open",
        vec![rule("tag", "has", "work"), rule("blocked", "is", "")],
    );
    let json = filter_definition_json(definition.clone());
    assert_eq!(
        json,
        r#"{"match":"any","show":"open","rules":[{"field":"tag","op":"has","value":"work"},{"field":"blocked","op":"is"}]}"#
    );
    assert_eq!(parse_filter_definition(json).unwrap(), definition);
    // Missing keys take their defaults; unknown ones are ignored.
    assert_eq!(
        parse_filter_definition(r#"{"rules":[],"later":1}"#.into()).unwrap(),
        FilterDefinition::default()
    );
    assert!(parse_filter_definition("[]".into()).is_err());
}

#[test]
fn a_definition_reads_as_a_sentence() {
    assert_eq!(
        describe_filter_definition(FilterDefinition::default()),
        "Open tasks"
    );
    assert_eq!(
        describe_filter_definition(definition(
            "all",
            "done",
            vec![rule("tag", "has", "work"), rule("due", "within", "7")]
        )),
        "Finished tasks where tag has work and due date is within 7 days"
    );
    assert_eq!(
        describe_filter_definition(definition("any", "all", vec![rule("blocked", "is", "")])),
        "All tasks where blocked yes"
    );
}

#[test]
fn creating_editing_moving_and_deleting_are_undoable_steps() {
    let mut connection = workspace();
    let made = journalled(&mut connection, "New Filter List", |tx| {
        create(
            tx,
            "w",
            "  Urgent ",
            Some("flame"),
            Some(" "),
            &definition("all", "open", vec![rule("tag", "has", "#Urgent")]),
            NOW,
        )
    })
    .unwrap();
    assert_eq!(made.name, "Urgent");
    assert_eq!(made.icon.as_deref(), Some("flame"));
    assert_eq!(made.color_hex, None);
    assert_eq!(made.definition.rules, [rule("tag", "has", "urgent")]);
    assert_eq!(made.sort_order, 0);
    let second = journalled(&mut connection, "New Filter List", |tx| {
        create(
            tx,
            "w",
            "All",
            None,
            None,
            &FilterDefinition::default(),
            NOW,
        )
    })
    .unwrap();
    assert_eq!(second.sort_order, 1);

    journalled(&mut connection, "Move Filter List", |tx| {
        move_to(tx, &second.id, 0, NOW)
    })
    .unwrap();
    let names: Vec<String> = filter_lists(&connection, "w")
        .unwrap()
        .into_iter()
        .map(|row| row.name)
        .collect();
    assert_eq!(names, ["All", "Urgent"]);

    journalled(&mut connection, "Rename Filter List", |tx| {
        rename(tx, &made.id, "Hot", NOW)
    })
    .unwrap();
    assert_eq!(
        filter_list(&connection, &made.id).unwrap().unwrap().name,
        "Hot"
    );
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Rename Filter List")
    );
    assert_eq!(
        filter_list(&connection, &made.id).unwrap().unwrap().name,
        "Urgent"
    );

    journalled(&mut connection, "Delete Filter List", |tx| {
        delete(tx, &made.id)
    })
    .unwrap();
    assert!(filter_list(&connection, &made.id).unwrap().is_none());
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Delete Filter List")
    );
    assert_eq!(
        filter_list(&connection, &made.id)
            .unwrap()
            .unwrap()
            .definition,
        made.definition
    );

    assert!(matches!(
        journalled(&mut connection, "Delete Filter List", |tx| delete(
            tx,
            BUILTIN_TODAY_ID
        )),
        Err(CoreError::MissingFilterList { .. })
    ));
    assert!(matches!(
        journalled(&mut connection, "New Filter List", |tx| create(
            tx,
            "w",
            " ",
            None,
            None,
            &FilterDefinition::default(),
            NOW
        )),
        Err(CoreError::EmptyName)
    ));
    assert!(matches!(
        journalled(&mut connection, "New Filter List", |tx| create(
            tx,
            "nowhere",
            "X",
            None,
            None,
            &FilterDefinition::default(),
            NOW
        )),
        Err(CoreError::InvalidFilter { .. })
    ));
}

#[test]
fn an_edit_that_changes_nothing_writes_nothing() {
    let mut connection = workspace();
    let made = journalled(&mut connection, "New Filter List", |tx| {
        create(
            tx,
            "w",
            "Mine",
            None,
            None,
            &FilterDefinition::default(),
            NOW,
        )
    })
    .unwrap();
    let entries = |c: &Connection| -> i64 {
        c.query_row("SELECT COUNT(*) FROM change_log", [], |row| row.get(0))
            .unwrap()
    };
    let before = entries(&connection);
    journalled(&mut connection, "Edit Filter List", |tx| {
        update(
            tx,
            &made.id,
            "Mine ",
            None,
            Some(""),
            &FilterDefinition::default(),
            NOW + 1,
        )
    })
    .unwrap();
    assert_eq!(entries(&connection), before);
}

#[test]
fn rows_are_queued_for_sync() {
    let mut connection = workspace();
    connection
        .execute("UPDATE sync_control SET recording = 1 WHERE id = 0", [])
        .unwrap();
    let made = journalled(&mut connection, "New Filter List", |tx| {
        create(
            tx,
            "w",
            "Mine",
            None,
            None,
            &FilterDefinition::default(),
            NOW,
        )
    })
    .unwrap();
    let queued: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sync_outbox WHERE tableName = 'filter_lists' AND rowId = ?1",
            [&made.id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(queued, 1);
}

#[test]
fn a_filter_lists_board_draws_only_its_matches_as_cards() {
    let connection = workspace();
    let lists = scope_list_ids(&connection, "w").unwrap();
    assert_eq!(lists, ["inbox", "work", "home"]);
    let read = board(
        &connection,
        &definition("all", "open", vec![rule("tag", "has", "work")]),
        &lists,
        None,
        NOW,
        "UTC",
    )
    .unwrap();
    let rows = crate::packed_rows::unpack_task_rows(&read.rows).unwrap();
    let cards: Vec<&str> = read
        .cards
        .chunks(4)
        .map(|bytes| {
            rows[u32::from_le_bytes(bytes.try_into().unwrap()) as usize]
                .id
                .as_str()
        })
        .collect();
    assert_eq!(cards, ["report", "call"]);
    // A filter that shows finished work draws it as a card too.
    let done = board(
        &connection,
        &definition("all", "done", vec![]),
        &lists,
        None,
        NOW,
        "UTC",
    )
    .unwrap();
    assert_eq!(done.cards.len(), 4);
}

#[test]
fn a_database_before_v23_has_no_filter_lists() {
    let mut connection = Connection::open_in_memory().unwrap();
    crate::schema::migrate_through(&mut connection, Some("v22_matrix_order")).unwrap();
    assert!(filter_lists(&connection, "w").unwrap().is_empty());
    assert!(filter_list(&connection, "x").unwrap().is_none());
    assert!(
        filter_list(&connection, BUILTIN_EVERYTHING_ID)
            .unwrap()
            .is_some()
    );
}
