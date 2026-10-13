use rusqlite::{Connection, TransactionBehavior, params};

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
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

/// One journalled step, as a client's write wrapper runs it.
fn step(connection: &mut Connection, label: &str, sql: &str) -> bool {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let group = begin(&transaction, label).unwrap();
    transaction.execute_batch(sql).unwrap();
    let changed = finish(&transaction, &group).unwrap();
    transaction.commit().unwrap();
    changed
}

fn add_task(id: &str, parent: Option<&str>, title: &str) -> String {
    let parent = parent.map_or("NULL".to_string(), |p| format!("'{p}'"));
    format!(
        "INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt)
         VALUES ('{id}', 'l', {parent}, '{title}', 0, '{T}', '{T}');"
    )
}

fn titles(connection: &Connection) -> Vec<String> {
    let mut statement = connection
        .prepare("SELECT title FROM tasks ORDER BY id")
        .unwrap();
    statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn a_step_is_undone_and_redone_by_its_label() {
    let mut connection = workspace();
    assert!(step(
        &mut connection,
        "New Task",
        &add_task("a", None, "Write")
    ));
    assert_eq!(
        undoable_label(&connection).unwrap().as_deref(),
        Some("New Task")
    );
    assert_eq!(redoable_label(&connection).unwrap(), None);

    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("New Task"));
    assert!(titles(&connection).is_empty());
    assert_eq!(undoable_label(&connection).unwrap(), None);
    assert_eq!(
        redoable_label(&connection).unwrap().as_deref(),
        Some("New Task")
    );

    assert_eq!(redo(&mut connection).unwrap().as_deref(), Some("New Task"));
    assert_eq!(titles(&connection), ["Write"]);
    assert_eq!(undo(&mut connection).unwrap().as_deref(), Some("New Task"));
    assert_eq!(undo(&mut connection).unwrap(), None);
}

/// Deleting a parent cascades to its child; undo has to put both back, which
/// briefly leaves one pointing at a row that is not there yet.
#[test]
fn a_deleted_subtree_comes_back_whole() {
    let mut connection = workspace();
    step(
        &mut connection,
        "New Tasks",
        &(add_task("p", None, "Parent") + &add_task("c", Some("p"), "Child")),
    );
    step(
        &mut connection,
        "Delete Task",
        "DELETE FROM tasks WHERE id = 'p';",
    );
    assert!(titles(&connection).is_empty());

    undo(&mut connection).unwrap();
    assert_eq!(titles(&connection), ["Child", "Parent"]);
    let parent: Option<String> = connection
        .query_row("SELECT parentTaskId FROM tasks WHERE id = 'c'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(parent.as_deref(), Some("p"));
}

/// Undoing a rename must not take the task's children with it, which an
/// INSERT OR REPLACE would, through the cascade.
#[test]
fn undoing_an_edit_keeps_the_subtree() {
    let mut connection = workspace();
    step(
        &mut connection,
        "New Tasks",
        &(add_task("p", None, "Parent") + &add_task("c", Some("p"), "Child")),
    );
    step(
        &mut connection,
        "Rename Task",
        "UPDATE tasks SET title = 'Renamed' WHERE id = 'p';",
    );
    undo(&mut connection).unwrap();
    assert_eq!(titles(&connection), ["Child", "Parent"]);
}

#[test]
fn a_step_that_changes_nothing_keeps_the_redo_stack() {
    let mut connection = workspace();
    step(&mut connection, "New Task", &add_task("a", None, "Write"));
    undo(&mut connection).unwrap();
    assert!(!step(
        &mut connection,
        "Move Task",
        "UPDATE tasks SET sortOrder = 1 WHERE id = 'missing';"
    ));
    assert_eq!(
        redoable_label(&connection).unwrap().as_deref(),
        Some("New Task")
    );

    assert!(step(
        &mut connection,
        "New Task",
        &add_task("b", None, "Other")
    ));
    assert_eq!(redoable_label(&connection).unwrap(), None);
}

#[test]
fn replaying_records_nothing_new() {
    let mut connection = workspace();
    step(&mut connection, "New Task", &add_task("a", None, "Write"));
    let count = |c: &Connection| -> i64 {
        c.query_row("SELECT COUNT(*) FROM change_log", [], |row| row.get(0))
            .unwrap()
    };
    let before = count(&connection);
    undo(&mut connection).unwrap();
    redo(&mut connection).unwrap();
    assert_eq!(count(&connection), before);
}

#[test]
fn the_journal_keeps_a_hundred_whole_steps() {
    let mut connection = workspace();
    for n in 0..(JOURNAL_DEPTH + 5) {
        step(
            &mut connection,
            &format!("Step {n}"),
            &add_task(&format!("t{n}"), None, "x"),
        );
    }
    let groups: i64 = connection
        .query_row(
            "SELECT COUNT(DISTINCT groupId) FROM change_log",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(groups, JOURNAL_DEPTH);
    let oldest = history(&connection, 1000)
        .unwrap()
        .last()
        .unwrap()
        .label
        .clone();
    assert_eq!(oldest, "Step 5");
}

#[test]
fn history_lists_redo_steps_first_and_names_the_target() {
    let mut connection = workspace();
    step(&mut connection, "New Task", &add_task("a", None, "Write"));
    step(
        &mut connection,
        "Delete Task",
        "DELETE FROM tasks WHERE id = 'a';",
    );
    undo(&mut connection).unwrap();

    let steps = history(&connection, 10).unwrap();
    let summary: Vec<(&str, bool, u32)> = steps
        .iter()
        .map(|s| (s.label.as_str(), s.is_undone, s.change_count))
        .collect();
    assert_eq!(summary, [("Delete Task", true, 1), ("New Task", false, 1)]);

    // The next redo deletes the task again; the next undo deletes the one
    // "New Task" inserted. Either way it is task "a" to reveal.
    assert_eq!(
        history_target(&connection, false)
            .unwrap()
            .task_id
            .as_deref(),
        Some("a")
    );
    assert_eq!(
        history_target(&connection, true)
            .unwrap()
            .task_id
            .as_deref(),
        Some("a")
    );
}

#[test]
fn a_database_without_the_journal_row_refuses_to_record() {
    let mut connection = workspace();
    connection.execute("DELETE FROM undo_control", []).unwrap();
    let transaction = connection.transaction().unwrap();
    assert!(matches!(
        begin(&transaction, "New Task"),
        Err(CoreError::NoJournal)
    ));
}

#[test]
fn a_step_holds_whatever_its_writes_touched() {
    let mut connection = workspace();
    step(
        &mut connection,
        "Edit",
        &(add_task("a", None, "One")
            + "INSERT INTO task_metadata (taskId, updatedAt) VALUES ('a', '2024-01-01 00:00:00.000');"),
    );
    let tables: Vec<String> = {
        let mut statement = connection
            .prepare("SELECT DISTINCT tableName FROM change_log ORDER BY tableName")
            .unwrap();
        statement
            .query_map(params![], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(tables, ["task_metadata", "tasks"]);
    undo(&mut connection).unwrap();
    let left: i64 = connection
        .query_row("SELECT COUNT(*) FROM task_metadata", [], |row| row.get(0))
        .unwrap();
    assert_eq!(left, 0);
}

fn group_of(connection: &Connection, label: &str) -> String {
    connection
        .query_row(
            "SELECT groupId FROM change_log WHERE label = ?1 ORDER BY id DESC LIMIT 1",
            [label],
            |row| row.get(0),
        )
        .unwrap()
}

#[test]
fn an_earlier_step_is_taken_back_alone_when_later_ones_do_not_depend_on_it() {
    let mut connection = workspace();
    step(&mut connection, "Add A", &add_task("a", None, "A"));
    step(&mut connection, "Add B", &add_task("b", None, "B"));
    step(
        &mut connection,
        "Rename B",
        "UPDATE tasks SET title = 'B2' WHERE id = 'b'",
    );
    let a = group_of(&connection, "Add A");

    let plan = step_undo_plan(&mut connection, &a).unwrap();
    assert!(plan.available && !plan.is_undone);
    assert!(plan.later_steps.is_empty());
    // The plan wrote nothing.
    assert_eq!(titles(&connection), ["A", "B2"]);

    assert_eq!(undo_step(&mut connection, &a).unwrap(), ["Add A"]);
    assert_eq!(titles(&connection), ["B2"]);
    // The menu's undo still takes back the newest step.
    assert_eq!(
        undoable_label(&connection).unwrap().as_deref(),
        Some("Rename B")
    );
    // Again is nothing: it is undone already.
    assert!(undo_step(&mut connection, &a).unwrap().is_empty());

    let plan = step_undo_plan(&mut connection, &a).unwrap();
    assert!(plan.is_undone && plan.can_redo);
    assert!(redo_step(&mut connection, &a).unwrap());
    assert_eq!(titles(&connection), ["A", "B2"]);
}

#[test]
fn a_step_a_later_one_built_on_is_taken_back_with_it() {
    let mut connection = workspace();
    step(&mut connection, "Add A", &add_task("a", None, "A"));
    step(
        &mut connection,
        "Rename A",
        "UPDATE tasks SET title = 'A2' WHERE id = 'a'",
    );
    let a = group_of(&connection, "Add A");
    let plan = step_undo_plan(&mut connection, &a).unwrap();
    assert_eq!(
        plan.later_steps
            .iter()
            .map(|s| s.label.as_str())
            .collect::<Vec<_>>(),
        ["Rename A"]
    );
    assert_eq!(
        undo_step(&mut connection, &a).unwrap(),
        ["Rename A", "Add A"]
    );
    assert!(titles(&connection).is_empty());
}

#[test]
fn a_subtask_added_later_keeps_its_parent_from_being_taken_back_alone() {
    // The rows differ, but deleting the parent would cascade to the subtask.
    let mut connection = workspace();
    step(&mut connection, "Add A", &add_task("a", None, "A"));
    step(&mut connection, "Add B", &add_task("b", None, "B"));
    step(&mut connection, "Add Child", &add_task("c", Some("a"), "C"));
    let a = group_of(&connection, "Add A");
    let plan = step_undo_plan(&mut connection, &a).unwrap();
    assert_eq!(
        plan.later_steps
            .iter()
            .map(|s| s.label.as_str())
            .collect::<Vec<_>>(),
        ["Add Child", "Add B"],
        "every later step, newest first, as the menu would"
    );
    undo_step(&mut connection, &a).unwrap();
    assert!(titles(&connection).is_empty());
}

#[test]
fn a_step_that_is_gone_has_no_plan_and_undoes_nothing() {
    let mut connection = workspace();
    assert_eq!(
        step_undo_plan(&mut connection, "NOPE").unwrap(),
        StepUndoPlan::default()
    );
    assert!(undo_step(&mut connection, "NOPE").unwrap().is_empty());
    assert!(!redo_step(&mut connection, "NOPE").unwrap());
    // A redo a newer change dropped is gone too.
    step(&mut connection, "Add A", &add_task("a", None, "A"));
    let a = group_of(&connection, "Add A");
    undo_step(&mut connection, &a).unwrap();
    step(&mut connection, "Add B", &add_task("b", None, "B"));
    assert!(!step_undo_plan(&mut connection, &a).unwrap().available);
}

#[test]
fn only_the_later_steps_that_built_on_it_go_back_with_it() {
    let mut connection = workspace();
    step(&mut connection, "Add A", &add_task("a", None, "A"));
    step(&mut connection, "Add B", &add_task("b", None, "B"));
    step(
        &mut connection,
        "Rename A",
        "UPDATE tasks SET title = 'A2' WHERE id = 'a'",
    );
    let a = group_of(&connection, "Add A");
    let plan = step_undo_plan(&mut connection, &a).unwrap();
    assert_eq!(
        plan.later_steps
            .iter()
            .map(|s| s.label.as_str())
            .collect::<Vec<_>>(),
        ["Rename A"]
    );
    assert_eq!(
        undo_step(&mut connection, &a).unwrap(),
        ["Rename A", "Add A"]
    );
    assert_eq!(titles(&connection), ["B"]);
}
