use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
const NOW: i64 = 1_700_000_000_000;
const HOUR: i64 = 3_600_000;

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}'),
                                                                          ('other', 'Theirs', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('p', 'l', NULL, 'Plan', 0, '{T}', '{T}'),
               ('c', 'l', 'p', 'Draft', 0, '{T}', '{T}'),
               ('g', 'l', 'c', 'Outline', 0, '{T}', '{T}');
             INSERT INTO task_conditions (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt) VALUES
               ('home', 'w', 'Home', 1, 0, '{T}', '{T}'),
               ('desk', 'w', 'Desk', 0, 0, '{T}', '{T}'),
               ('old', 'w', 'Old', 0, 1, '{T}', '{T}'),
               ('away', 'other', 'Away', 1, 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn save(
    connection: &mut Connection,
    edit: &EditorSnapshot,
    baseline: &EditorSnapshot,
) -> Result<EditorSnapshot, CoreError> {
    journalled(connection, "Edit Task", |tx| {
        save_editor(tx, edit, baseline, NOW, "Europe/London")
    })
}

fn planning_json(connection: &Connection, id: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT planningJSON FROM task_metadata WHERE taskId = ?1",
            [id],
            |row| row.get(0),
        )
        .unwrap()
}

#[test]
fn saving_the_editor_writes_every_part_in_one_step() {
    let mut connection = workspace();
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.title = "Plan the launch".into();
    edit.notes = "Agenda first".into();
    edit.estimate_seconds = Some(1_800);
    edit.metadata = EditorMetadata {
        priority: Some(9),
        tags: vec![" work ".into(), "Work".into(), "launch".into()],
        recurrence_rule: Some("  ".into()),
        external_links: vec!["https://example.com/a".into()],
    };
    edit.daily_progress = true;
    edit.planning = Some(Planning {
        due_date: Some("2026-03-29".into()),
        requirement_groups: Some(vec![vec!["home".into(), "desk".into()]]),
        minimum_block_seconds: Some(900),
        requires_single_sitting: Some(true),
        ..Default::default()
    });
    let saved = save(&mut connection, &edit, &baseline).unwrap();

    assert_eq!(saved.title, "Plan the launch");
    assert_eq!(saved.metadata.priority, None);
    assert_eq!(saved.metadata.tags, ["work", "launch"]);
    assert_eq!(saved.metadata.recurrence_rule, None);
    assert!(saved.daily_progress);
    assert_eq!(saved.planning, edit.planning);
    assert_eq!(
        planning_json(&connection, "p").as_deref(),
        Some(
            r#"{"dueDate":"2026-03-29","requirementGroups":[["home","desk"]],"minimumBlockSeconds":900,"requiresSingleSitting":true}"#
        )
    );
    let links: String = connection
        .query_row(
            "SELECT externalLinksJSON FROM task_metadata WHERE taskId = 'p'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(links, r#"["https:\/\/example.com\/a"]"#);

    let groups: i64 = connection
        .query_row(
            "SELECT COUNT(DISTINCT groupId) FROM change_log",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(groups, 1);
    undo(&mut connection).unwrap();
    assert_eq!(snapshot(&connection, "p").unwrap(), baseline);
}

#[test]
fn a_save_over_a_change_made_meanwhile_is_refused() {
    let mut connection = workspace();
    let baseline = snapshot(&connection, "p").unwrap();
    connection
        .execute(
            "UPDATE tasks SET title = 'Changed elsewhere' WHERE id = 'p'",
            [],
        )
        .unwrap();
    let mut edit = baseline.clone();
    edit.title = "Mine".into();
    assert!(matches!(
        save(&mut connection, &edit, &baseline),
        Err(CoreError::EditorConflict)
    ));
}

#[test]
fn the_planning_rules_refuse_what_both_clients_refused() {
    let mut connection = workspace();
    let baseline = snapshot(&connection, "p").unwrap();
    let attempt = |connection: &mut Connection, planning: Planning, estimate: Option<i64>| {
        let mut edit = baseline.clone();
        edit.estimate_seconds = estimate;
        edit.planning = planning.normalized();
        save(connection, &edit, &baseline)
    };
    type Case = (Planning, Option<i64>, fn(&CoreError) -> bool);
    let cases: Vec<Case> = vec![
        (
            Planning {
                due_date: Some("2026-3-29".into()),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidDate),
        ),
        (
            Planning {
                due_date: Some("2026-02-30".into()),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidDate),
        ),
        // Due by the end of the 29th, local time: a start then is too late.
        (
            Planning {
                start_at_ms: Some(1_774_825_200_000),
                due_date: Some("2026-03-29".into()),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidSchedule),
        ),
        (
            Planning {
                minimum_block_seconds: Some(30),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidMinimum),
        ),
        (
            Planning {
                requires_single_sitting: Some(true),
                minimum_block_seconds: Some(900),
                ..Default::default()
            },
            Some(600),
            |e| matches!(e, CoreError::EstimateRequired),
        ),
        (
            Planning {
                requirement_groups: Some(vec![vec!["away".into()]]),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidCondition),
        ),
        (
            Planning {
                requirement_groups: Some(vec![vec!["old".into()]]),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidCondition),
        ),
        (
            Planning {
                requirement_groups: Some(vec![vec!["home".into(), "home".into()]]),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidCondition),
        ),
        (
            Planning {
                requirement_groups: Some(vec![
                    vec!["home".into(), "desk".into()],
                    vec!["desk".into(), "home".into()],
                ]),
                ..Default::default()
            },
            None,
            |e| matches!(e, CoreError::InvalidCondition),
        ),
    ];
    for (planning, estimate, expected) in cases {
        let error = attempt(&mut connection, planning.clone(), estimate).unwrap_err();
        assert!(expected(&error), "{planning:?} gave {error:?}");
    }
    // A start just inside the deadline is fine.
    attempt(
        &mut connection,
        Planning {
            start_at_ms: Some(1_774_825_200_000 - HOUR),
            due_date: Some("2026-03-29".into()),
            ..Default::default()
        },
        None,
    )
    .unwrap();
}

#[test]
fn a_due_time_replaces_a_due_date_and_scheduling_moves_only_the_start() {
    let mut connection = workspace();
    let baseline = snapshot(&connection, "c").unwrap();
    let mut edit = baseline.clone();
    edit.planning = Some(Planning {
        due_date: Some("2026-04-01".into()),
        ..Default::default()
    });
    save(&mut connection, &edit, &baseline).unwrap();

    journalled(&mut connection, "Schedule Task", |tx| {
        schedule_task(tx, "c", Some(NOW), NOW, "UTC")
    })
    .unwrap();
    let scheduled = snapshot(&connection, "c").unwrap().planning.unwrap();
    assert_eq!(
        (scheduled.start_at_ms, scheduled.due_date.as_deref()),
        (Some(NOW), Some("2026-04-01"))
    );

    journalled(&mut connection, "Edit Task", |tx| {
        update_task(
            tx,
            "c",
            " Draft v2 ",
            "",
            Some(NOW + HOUR),
            Some(600),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    let edited = snapshot(&connection, "c").unwrap();
    assert_eq!(edited.title, "Draft v2");
    assert_eq!(edited.due_at_ms, Some(NOW + HOUR));
    assert_eq!(edited.planning.unwrap().due_date, None);
    assert!(matches!(
        journalled(&mut connection, "Edit Task", |tx| update_task(
            tx, "c", "  ", "", None, None, NOW, "UTC"
        )),
        Err(CoreError::EmptyName)
    ));
}

#[test]
fn planning_copies_to_subtasks_but_each_keeps_its_own_due_date() {
    let mut connection = workspace();
    let parent = snapshot(&connection, "p").unwrap();
    let mut edit = parent.clone();
    edit.planning = Some(Planning {
        requirement_groups: Some(vec![vec!["home".into()]]),
        minimum_block_seconds: Some(1_200),
        ..Default::default()
    });
    save(&mut connection, &edit, &parent).unwrap();
    let child = snapshot(&connection, "g").unwrap();
    let mut own = child.clone();
    own.planning = Some(Planning {
        due_date: Some("2026-05-01".into()),
        ..Default::default()
    });
    save(&mut connection, &own, &child).unwrap();

    journalled(&mut connection, "Apply Planning to Subtasks", |tx| {
        apply_planning_to_descendants(tx, "p", NOW, "UTC")
    })
    .unwrap();
    for id in ["c", "g"] {
        let planning = snapshot(&connection, id).unwrap().planning.unwrap();
        assert_eq!(
            planning.requirement_groups,
            Some(vec![vec!["home".to_string()]])
        );
        assert_eq!(planning.minimum_block_seconds, Some(1_200));
    }
    assert_eq!(
        snapshot(&connection, "g")
            .unwrap()
            .planning
            .unwrap()
            .due_date
            .as_deref(),
        Some("2026-05-01")
    );
    assert_eq!(
        snapshot(&connection, "c")
            .unwrap()
            .planning
            .unwrap()
            .due_date,
        None
    );
}

#[test]
fn saving_nothing_onto_a_task_without_metadata_writes_nothing() {
    let mut connection = workspace();
    journalled(&mut connection, "Edit Task Details", |tx| {
        update_editor_metadata(tx, "g", &EditorMetadata::default(), NOW)
    })
    .unwrap();
    let rows: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM task_metadata WHERE taskId = 'g'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(rows, 0);
}
