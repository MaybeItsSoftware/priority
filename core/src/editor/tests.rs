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

#[test]
fn a_start_moved_off_today_moves_the_task_out_of_today() {
    // NOW is Tuesday 14 November 2023, 22:13 UTC.
    const DAY: i64 = 24 * HOUR;
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO task_metadata (taskId, kanbanColumn, focusRank, updatedAt) VALUES
               ('p', 'today', 2, '{T}'), ('c', 'in-progress', NULL, '{T}'), ('g', NULL, NULL, '{T}');"
        ))
        .unwrap();
    let column = |c: &Connection, id: &str| -> (Option<String>, Option<i64>) {
        c.query_row(
            "SELECT kanbanColumn, focusRank FROM task_metadata WHERE taskId = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap()
    };
    let schedule = |c: &mut Connection, id: &str, start: Option<i64>| {
        journalled(c, "Schedule Task", |tx| {
            schedule_task(tx, id, start, NOW, "UTC")
        })
        .unwrap();
    };

    // Later today keeps its place in the day.
    schedule(&mut connection, "p", Some(NOW + HOUR / 2));
    assert_eq!(column(&connection, "p"), (Some("today".into()), Some(2)));
    // Thursday is this week, and leaving Today drops the rank.
    schedule(&mut connection, "p", Some(NOW + 2 * DAY));
    assert_eq!(column(&connection, "p"), (Some("this-week".into()), None));
    // Back to today from This week.
    schedule(&mut connection, "p", Some(NOW - DAY));
    assert_eq!(column(&connection, "p"), (Some("today".into()), None));
    // Next Monday is beyond this week: filed nowhere.
    schedule(&mut connection, "p", Some(NOW + 6 * DAY));
    assert_eq!(column(&connection, "p"), (None, None));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Schedule Task")
    );
    assert_eq!(column(&connection, "p"), (Some("today".into()), None));

    // Other columns, and the backlog, are left where they are.
    schedule(&mut connection, "c", Some(NOW + 2 * DAY));
    assert_eq!(column(&connection, "c"), (Some("in-progress".into()), None));
    schedule(&mut connection, "g", Some(NOW));
    assert_eq!(column(&connection, "g"), (None, None));

    // A board with no This week column sends a later start to the backlog.
    connection
        .execute_batch(
            r#"INSERT INTO kanban_boards (id, columnsJSON)
               VALUES ('l/root', '[{"id":"backlog","title":"Backlog"},{"id":"today","title":"Today"}]');"#,
        )
        .unwrap();
    schedule(&mut connection, "p", Some(NOW + 2 * DAY));
    assert_eq!(column(&connection, "p"), (None, None));
}

/// "Keep the due date": the start moves and a deadline that would have
/// followed it stays put, pinned, so later moves leave it too.
#[test]
fn a_save_keeping_the_due_date_leaves_it_where_it_was() {
    const DAY: i64 = 24 * HOUR;
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "UPDATE tasks SET dueAt = '{}' WHERE id = 'p';
             INSERT INTO task_metadata (taskId, startAt, updatedAt) VALUES ('p', '{}', '{T}');",
            stored(NOW + 5 * DAY),
            stored(NOW + DAY)
        ))
        .unwrap();
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.planning.as_mut().unwrap().start_at_ms = Some(NOW + 2 * DAY);
    journalled(&mut connection, "Edit Task", |tx| {
        save_editor_with(tx, &edit, &baseline, NOW, "Europe/London", true)
    })
    .unwrap();
    assert_eq!(
        snapshot(&connection, "p").unwrap().due_at_ms,
        Some(NOW + 5 * DAY)
    );
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 3 * DAY), NOW, "Europe/London")
    })
    .unwrap();
    assert_eq!(
        snapshot(&connection, "p").unwrap().due_at_ms,
        Some(NOW + 5 * DAY)
    );
}

/// "Move it with the start", answered on the Mac, writes the deadline where
/// following would have put it. That is still following, so a later move of
/// the start carries the deadline along again.
#[test]
fn a_deadline_moved_exactly_with_its_start_keeps_following() {
    const DAY: i64 = 24 * HOUR;
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "UPDATE tasks SET dueAt = '{}' WHERE id = 'p';
             INSERT INTO task_metadata (taskId, startAt, updatedAt) VALUES ('p', '{}', '{T}');",
            stored(NOW + 3 * DAY),
            stored(NOW + DAY)
        ))
        .unwrap();
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.planning.as_mut().unwrap().start_at_ms = Some(NOW + 2 * DAY);
    edit.due_at_ms = Some(NOW + 4 * DAY);
    journalled(&mut connection, "Edit Task", |tx| {
        save_editor(tx, &edit, &baseline, NOW, "Europe/London")
    })
    .unwrap();
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 3 * DAY), NOW, "Europe/London")
    })
    .unwrap();
    assert_eq!(
        snapshot(&connection, "p").unwrap().due_at_ms,
        Some(NOW + 5 * DAY)
    );
}

#[test]
fn a_deadline_follows_its_start_until_it_is_changed_on_its_own() {
    const DAY: i64 = 24 * HOUR;
    let mut connection = workspace();
    let due = |c: &Connection| -> (Option<i64>, Option<String>) {
        let saved = snapshot(c, "p").unwrap();
        (saved.due_at_ms, saved.planning.and_then(|p| p.due_date))
    };
    // A start and a due time set when the task was made: the deadline follows.
    connection
        .execute_batch(&format!(
            "UPDATE tasks SET dueAt = '{}' WHERE id = 'p';
             INSERT INTO task_metadata (taskId, startAt, updatedAt) VALUES ('p', '{}', '{T}');",
            stored(NOW + 3 * DAY),
            stored(NOW + DAY)
        ))
        .unwrap();
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 2 * DAY), NOW, "Europe/London")
    })
    .unwrap();
    assert_eq!(due(&connection).0, Some(NOW + 4 * DAY));

    // Moving the deadline itself pins it: the next start move leaves it.
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.due_at_ms = Some(NOW + 6 * DAY);
    save(&mut connection, &edit, &baseline).unwrap();
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 3 * DAY), NOW, "Europe/London")
    })
    .unwrap();
    assert_eq!(due(&connection).0, Some(NOW + 6 * DAY));
    // And the pin survives a save that does not know about it.
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.title = "Plan it".into();
    save(&mut connection, &edit, &baseline).unwrap();
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 4 * DAY), NOW, "Europe/London")
    })
    .unwrap();
    assert_eq!(due(&connection).0, Some(NOW + 6 * DAY));

    // Clearing the deadline drops the pin; a due day then set by hand pins
    // again, so only a deadline set with the task follows.
    let baseline = snapshot(&connection, "p").unwrap();
    let mut edit = baseline.clone();
    edit.due_at_ms = None;
    save(&mut connection, &edit, &baseline).unwrap();
    assert!(
        !planning_json(&connection, "p")
            .unwrap_or_default()
            .contains("duePinned")
    );
}

#[test]
fn a_due_day_moves_by_whole_days_with_its_start() {
    const DAY: i64 = 24 * HOUR;
    let mut connection = workspace();
    // NOW is Tuesday 14 November 2023, 22:13 UTC; due Friday the 17th.
    connection
        .execute_batch(&format!(
            "INSERT INTO task_metadata (taskId, startAt, planningJSON, updatedAt)
               VALUES ('p', '{}', '{{\"dueDate\":\"2023-11-17\"}}', '{T}');",
            stored(NOW + DAY)
        ))
        .unwrap();
    journalled(&mut connection, "Schedule", |tx| {
        schedule_task(tx, "p", Some(NOW + 3 * DAY), NOW, "UTC")
    })
    .unwrap();
    let saved = snapshot(&connection, "p").unwrap();
    assert_eq!(
        saved.planning.and_then(|p| p.due_date).as_deref(),
        Some("2023-11-19")
    );
}

fn root_order(connection: &Connection) -> Vec<String> {
    connection
        .prepare("SELECT id FROM tasks WHERE parentTaskId IS NULL ORDER BY sortOrder, id")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn set_priority(connection: &mut Connection, id: &str, priority: Option<i64>) {
    journalled(connection, "Edit Task Details", |tx| {
        update_editor_metadata(
            tx,
            id,
            &EditorMetadata {
                priority,
                ..Default::default()
            },
            NOW,
        )
    })
    .unwrap();
}

#[test]
fn a_negative_priority_moves_the_task_to_the_bottom_of_its_list() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('q', 'l', NULL, 'Second', 1, '{T}', '{T}'),
               ('r', 'l', NULL, 'Third', 2, '{T}', '{T}');"
        ))
        .unwrap();
    set_priority(&mut connection, "p", Some(-1));
    assert_eq!(root_order(&connection), ["q", "r", "p"]);
    // From negative to positive is a change: to the top.
    set_priority(&mut connection, "p", Some(2));
    assert_eq!(root_order(&connection), ["p", "q", "r"]);
    // And back to the bottom; the same one again does not move it.
    set_priority(&mut connection, "p", Some(-3));
    assert_eq!(root_order(&connection), ["q", "r", "p"]);
    set_priority(&mut connection, "r", Some(-2));
    assert_eq!(root_order(&connection), ["q", "p", "r"]);
    // Sending r behind p's level moved p forward, to -4; setting that again
    // is no change.
    set_priority(&mut connection, "p", Some(-4));
    assert_eq!(root_order(&connection), ["q", "p", "r"]);
    // Out of range is no priority, and clearing does not move it.
    set_priority(&mut connection, "r", Some(-5));
    assert_eq!(root_order(&connection), ["q", "p", "r"]);
    let stored: Option<i64> = connection
        .query_row(
            "SELECT priority FROM task_metadata WHERE taskId = 'r'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(stored, None);
}

#[test]
fn setting_a_priority_moves_the_task_to_the_top_of_its_list() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt) VALUES
               ('q', 'l', NULL, 'Second', 1, '{T}', '{T}'),
               ('r', 'l', NULL, 'Third', 2, '{T}', '{T}');"
        ))
        .unwrap();
    set_priority(&mut connection, "r", Some(2));
    assert_eq!(root_order(&connection), ["r", "p", "q"]);
    // Changing it moves it again; setting the same one does not.
    set_priority(&mut connection, "q", Some(3));
    assert_eq!(root_order(&connection), ["q", "r", "p"]);
    set_priority(&mut connection, "r", Some(2));
    assert_eq!(root_order(&connection), ["q", "r", "p"]);
    set_priority(&mut connection, "r", Some(1));
    assert_eq!(root_order(&connection), ["r", "q", "p"]);
    // Clearing leaves it where it is.
    set_priority(&mut connection, "r", None);
    assert_eq!(root_order(&connection), ["r", "q", "p"]);
    // One undo takes back the priority and the move together.
    set_priority(&mut connection, "p", Some(4));
    assert_eq!(root_order(&connection), ["p", "r", "q"]);
    undo(&mut connection).unwrap();
    assert_eq!(root_order(&connection), ["r", "q", "p"]);
}

/// Sending a task behind the back takes the very back: the one sent there
/// before moves a step forward, and so on down to -4.
#[test]
fn a_task_sent_to_the_back_supersedes_the_one_already_there() {
    let mut connection = workspace();
    for id in ["first", "second", "third"] {
        connection
            .execute_batch(&format!(
                "INSERT INTO tasks (id, listId, title, status, sortOrder, itemKind, createdAt, updatedAt)
                   VALUES ('{id}', 'l', '{id}', 'open', 0, 'task', '{T}', '{T}');"
            ))
            .unwrap();
    }
    let priority = |c: &Connection, id: &str| snapshot(c, id).unwrap().metadata.priority;
    set_priority(&mut connection, "first", Some(-1));
    set_priority(&mut connection, "second", Some(-1));
    assert_eq!(priority(&connection, "first"), Some(-2));
    assert_eq!(priority(&connection, "second"), Some(-1));
    set_priority(&mut connection, "third", Some(-1));
    assert_eq!(
        ["first", "second", "third"].map(|id| priority(&connection, id)),
        [Some(-3), Some(-2), Some(-1)]
    );
    // Setting one again at its own level moves nothing.
    set_priority(&mut connection, "third", Some(-1));
    assert_eq!(priority(&connection, "second"), Some(-2));
}
