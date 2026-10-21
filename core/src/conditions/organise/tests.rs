use rusqlite::Connection;

use super::*;
use crate::conditions::{create_condition_in_category, set_condition_category};
use crate::journal::{journalled, undo};
use crate::schema::migrate;

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt)
             VALUES ('w', 'Mine', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
             VALUES ('l', 'w', 'Inbox', 0, '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');",
        )
        .unwrap();
    connection
}

fn make(connection: &mut Connection, name: &str, category: Option<&str>) -> String {
    // Made a second apart, so "the order they were made" is one order.
    let made: i64 = connection
        .query_row("SELECT COUNT(*) FROM task_conditions", [], |row| row.get(0))
        .unwrap();
    journalled(connection, "New Condition", |tx| {
        create_condition_in_category(tx, "w", name, category, made * 1000)
    })
    .unwrap()
}

fn task(connection: &Connection, id: &str, status: &str, groups: &str) {
    connection
        .execute(
            "INSERT INTO tasks (id, listId, title, status, sortOrder, createdAt, updatedAt)
             VALUES (?1, 'l', ?1, ?2, 0, '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000')",
            params![id, status],
        )
        .unwrap();
    if !groups.is_empty() {
        connection
            .execute(
                "INSERT INTO task_metadata (taskId, planningJSON, updatedAt)
                 VALUES (?1, ?2, '2024-01-01 00:00:00.000')",
                params![id, format!("{{\"requirementGroups\":{groups}}}")],
            )
            .unwrap();
    }
}

fn shown(connection: &Connection) -> Vec<(String, Vec<String>)> {
    display_order(connection, "w")
        .unwrap()
        .into_iter()
        .map(|section| {
            (
                section.title,
                section.conditions.into_iter().map(|c| c.name).collect(),
            )
        })
        .collect()
}

fn groups(connection: &Connection, task: &str) -> Option<Vec<Vec<String>>> {
    let json: Option<String> = connection
        .query_row(
            "SELECT planningJSON FROM task_metadata WHERE taskId = ?1",
            [task],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
        .flatten();
    json.and_then(|json| Planning::from_json(&json).unwrap().requirement_groups)
}

#[test]
fn conditions_and_headings_move_and_the_move_undoes() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    let campus = make(&mut connection, "Campus", Some("Location"));
    let mat = make(&mut connection, "Mat", Some("Equipment"));
    let _quiet = make(&mut connection, "Quiet", None);
    // Before anything is placed: Location, the rest alphabetically, Other.
    assert_eq!(
        shown(&connection),
        vec![
            ("Location".into(), vec!["Home".into(), "Campus".into()]),
            ("Equipment".into(), vec!["Mat".into()]),
            ("Other".into(), vec!["Quiet".into()]),
        ]
    );
    assert!(
        journalled(&mut connection, "Move Condition", |tx| move_condition(
            tx, &campus, -1, 1
        ))
        .unwrap()
    );
    // At the top already: nothing to do.
    assert!(
        !journalled(&mut connection, "Move Condition", |tx| move_condition(
            tx, &campus, -1, 1
        ))
        .unwrap()
    );
    assert!(
        journalled(&mut connection, "Move Category", |tx| {
            move_condition_category(tx, "w", None, -2, 1)
        })
        .unwrap()
    );
    assert_eq!(
        shown(&connection),
        vec![
            ("Other".into(), vec!["Quiet".into()]),
            ("Location".into(), vec!["Campus".into(), "Home".into()]),
            ("Equipment".into(), vec!["Mat".into()]),
        ]
    );
    // A new one goes last under its heading; refiling one puts it last under
    // the new heading and leaves the old heading where it was.
    let gym = make(&mut connection, "Gym", Some("location"));
    journalled(&mut connection, "Edit Condition", |tx| {
        set_condition_category(tx, &home, Some("Equipment"), 2)
    })
    .unwrap();
    assert_eq!(
        shown(&connection),
        vec![
            ("Other".into(), vec!["Quiet".into()]),
            ("Location".into(), vec!["Campus".into(), "Gym".into()]),
            ("Equipment".into(), vec!["Mat".into(), "Home".into()]),
        ]
    );
    assert!(
        journalled(&mut connection, "Move Condition", |tx| move_condition(
            tx, &gym, -1, 3
        ))
        .unwrap()
    );
    undo(&mut connection).unwrap();
    assert_eq!(
        shown(&connection)[1],
        ("Location".into(), vec!["Campus".into(), "Gym".into()])
    );
    // Archived ones move among themselves.
    connection
        .execute(
            "UPDATE task_conditions SET isArchived = 1 WHERE id = ?1",
            [&mat],
        )
        .unwrap();
    assert!(
        !journalled(&mut connection, "Move Condition", |tx| move_condition(
            tx, &mat, 1, 4
        ))
        .unwrap()
    );
}

#[test]
fn a_category_is_renamed_merged_and_location_stays() {
    let mut connection = workspace();
    let mat = make(&mut connection, "Mat", Some("Equipment"));
    let bell = make(&mut connection, "Bell", Some("Equipment"));
    let tired = make(&mut connection, "Tired", Some("Energy"));
    let home = make(&mut connection, "Home", Some("Location"));
    let renamed = journalled(&mut connection, "Rename Category", |tx| {
        rename_condition_category(tx, "w", Some("equipment"), Some("Gear"), 1)
    })
    .unwrap();
    assert_eq!(renamed, 2);
    let category = |connection: &Connection, id: &str| -> Option<String> {
        connection
            .query_row(
                "SELECT category FROM task_conditions WHERE id = ?1",
                [id],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_eq!(category(&connection, &mat), Some("Gear".into()));
    assert_eq!(category(&connection, &bell), Some("Gear".into()));
    // Onto one in use: merged, spelled as it is spelled.
    journalled(&mut connection, "Rename Category", |tx| {
        rename_condition_category(tx, "w", Some("Gear"), Some("energy"), 1)
    })
    .unwrap();
    assert_eq!(category(&connection, &mat), Some("Energy".into()));
    assert_eq!(category(&connection, &tired), Some("Energy".into()));
    assert!(matches!(
        journalled(&mut connection, "Rename Category", |tx| {
            rename_condition_category(tx, "w", Some("Location"), Some("Places"), 1)
        }),
        Err(CoreError::InvalidCondition)
    ));
    assert_eq!(category(&connection, &home), Some("Location".into()));
    undo(&mut connection).unwrap();
    assert_eq!(category(&connection, &mat), Some("Gear".into()));
}

#[test]
fn merging_moves_every_requirement_and_archives_the_old_one() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    let house = make(&mut connection, "House", Some("Location"));
    let mat = make(&mut connection, "Mat", None);
    task(&connection, "a", "open", &format!("[[\"{house}\"]]"));
    task(
        &connection,
        "b",
        "open",
        &format!("[[\"{home}\",\"{house}\"],[\"{mat}\"]]"),
    );
    task(
        &connection,
        "c",
        "open",
        &format!("[[\"{house}\"],[\"{home}\"]]"),
    );
    task(&connection, "d", "open", &format!("[[\"{mat}\"]]"));
    connection
        .execute_batch(&format!(
            "INSERT INTO focus_contexts (workspaceId, conditionIdsJSON, conditionsSetAt, updatedAt)
             VALUES ('w', '[\"{house}\",\"{mat}\"]', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');"
        ))
        .unwrap();
    let changed = journalled(&mut connection, "Merge Conditions", |tx| {
        merge_conditions(tx, &house, &home, 5)
    })
    .unwrap();
    assert_eq!(changed, 3);
    assert_eq!(groups(&connection, "a"), Some(vec![vec![home.clone()]]));
    assert_eq!(
        groups(&connection, "b"),
        Some(vec![vec![home.clone()], vec![mat.clone()]])
    );
    assert_eq!(groups(&connection, "c"), Some(vec![vec![home.clone()]]));
    assert_eq!(groups(&connection, "d"), Some(vec![vec![mat.clone()]]));
    let archived: bool = connection
        .query_row(
            "SELECT isArchived FROM task_conditions WHERE id = ?1",
            [&house],
            |row| row.get(0),
        )
        .unwrap();
    assert!(archived);
    let context = crate::focus_context::load(&connection, "w")
        .unwrap()
        .unwrap();
    let mut expected = vec![home.clone(), mat.clone()];
    expected.sort();
    assert_eq!(context.condition_ids, expected);
    assert!(matches!(
        journalled(&mut connection, "Merge Conditions", |tx| {
            merge_conditions(tx, &home, &home, 5)
        }),
        Err(CoreError::InvalidCondition)
    ));
    undo(&mut connection).unwrap();
    assert_eq!(groups(&connection, "a"), Some(vec![vec![house.clone()]]));
}

#[test]
fn merging_carries_a_negation_over() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    let house = make(&mut connection, "House", Some("Location"));
    let quiet = make(&mut connection, "Quiet", None);
    task(&connection, "away", "open", &format!("[[\"!{house}\"]]"));
    task(
        &connection,
        "either",
        "open",
        &format!("[[\"!{house}\",\"!{home}\"],[\"{house}\",\"{quiet}\"]]"),
    );
    task(
        &connection,
        "both",
        "open",
        &format!("[[\"{house}\",\"!{home}\"]]"),
    );
    let changed = journalled(&mut connection, "Merge Conditions", |tx| {
        merge_conditions(tx, &house, &home, 5)
    })
    .unwrap();
    assert_eq!(changed, 3);
    assert_eq!(
        groups(&connection, "away"),
        Some(vec![vec![format!("!{home}")]])
    );
    assert_eq!(
        groups(&connection, "either"),
        Some(vec![
            vec![format!("!{home}")],
            vec![home.clone(), quiet.clone()]
        ])
    );
    // Named both ways, as it may be: always met, and left so.
    assert_eq!(
        groups(&connection, "both"),
        Some(vec![vec![home.clone(), format!("!{home}")]])
    );
}

#[test]
fn a_negated_requirement_counts_as_its_condition() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    task(
        &connection,
        "both",
        "open",
        &format!("[[\"{home}\"],[\"!{home}\",\"x\"]]"),
    );
    task(&connection, "away", "open", &format!("[[\"!{home}\"]]"));
    assert_eq!(
        condition_usage(&connection, "w").unwrap(),
        vec![
            ConditionUsage {
                condition_id: home.clone(),
                open_tasks: 2
            },
            ConditionUsage {
                condition_id: "x".into(),
                open_tasks: 1
            },
        ]
    );
    let requiring: Vec<String> = tasks_requiring(&connection, "w", &home)
        .unwrap()
        .into_iter()
        .map(|t| t.task_id)
        .collect();
    assert_eq!(requiring, ["away", "both"]);
    let counts = condition_waiting_counts(vec![
        vec![vec!["!campus".into()]],
        vec![vec!["campus".into()], vec!["!campus".into()]],
    ]);
    assert_eq!(
        counts,
        vec![ConditionUsage {
            condition_id: "campus".into(),
            open_tasks: 2
        }]
    );
}

#[test]
fn usage_counts_open_tasks_only_and_names_them() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    task(
        &connection,
        "open",
        "open",
        &format!("[[\"{home}\"],[\"{home}\",\"x\"]]"),
    );
    task(&connection, "done", "completed", &format!("[[\"{home}\"]]"));
    task(&connection, "free", "open", "");
    assert_eq!(
        condition_usage(&connection, "w").unwrap(),
        vec![
            ConditionUsage {
                condition_id: home.clone(),
                open_tasks: 1
            },
            ConditionUsage {
                condition_id: "x".into(),
                open_tasks: 1
            },
        ]
    );
    let requiring = tasks_requiring(&connection, "w", &home).unwrap();
    assert_eq!(requiring.len(), 1);
    assert_eq!(requiring[0].task_id, "open");
    assert_eq!(requiring[0].list_name, "Inbox");
}

#[test]
fn waiting_counts_each_task_once_per_condition() {
    let counts = condition_waiting_counts(vec![
        vec![
            vec!["campus".into(), "library".into()],
            vec!["campus".into()],
        ],
        vec![vec!["campus".into()]],
        vec![vec!["mat".into()]],
    ]);
    assert_eq!(
        counts
            .iter()
            .map(|c| (c.condition_id.as_str(), c.open_tasks))
            .collect::<Vec<_>>(),
        vec![("campus", 2), ("library", 1), ("mat", 1)]
    );
}

#[test]
fn a_task_requirements_are_set_checked_and_cleared() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    let campus = make(&mut connection, "Campus", Some("Location"));
    let old = make(&mut connection, "Old", None);
    task(&connection, "t", "open", "");
    assert!(
        journalled(&mut connection, "Edit Conditions", |tx| {
            set_task_requirements(tx, "t", vec![vec![home.clone(), campus.clone()]], 1)
        })
        .unwrap()
    );
    assert_eq!(
        groups(&connection, "t"),
        Some(vec![vec![home.clone(), campus.clone()]])
    );
    assert!(
        !journalled(&mut connection, "Edit Conditions", |tx| {
            set_task_requirements(tx, "t", vec![vec![home.clone(), campus.clone()]], 1)
        })
        .unwrap()
    );
    connection
        .execute(
            "UPDATE task_conditions SET isArchived = 1 WHERE id = ?1",
            [&old],
        )
        .unwrap();
    for bad in [
        vec![vec![old.clone()]],
        vec![vec![]],
        vec![vec![home.clone(), home.clone()]],
        vec![vec![home.clone()], vec![home.clone()]],
        vec![vec!["nope".to_string()]],
    ] {
        assert!(matches!(
            journalled(&mut connection, "Edit Conditions", |tx| {
                set_task_requirements(tx, "t", bad, 1)
            }),
            Err(CoreError::InvalidCondition)
        ));
    }
    assert!(matches!(
        journalled(&mut connection, "Edit Conditions", |tx| {
            set_task_requirements(tx, "missing", vec![], 1)
        }),
        Err(CoreError::MissingTask { .. })
    ));
    // A condition required not to hold is checked as the condition: an
    // archived one only if the task already named it, either way.
    for bad in [
        vec![vec![format!("!{old}")]],
        vec![vec!["!nope".to_string()]],
    ] {
        assert!(matches!(
            journalled(&mut connection, "Edit Conditions", |tx| {
                set_task_requirements(tx, "t", bad, 1)
            }),
            Err(CoreError::InvalidCondition)
        ));
    }
    let away = vec![
        vec![format!("!{home}")],
        vec![campus.clone(), format!("!{campus}")],
    ];
    assert!(
        journalled(&mut connection, "Edit Conditions", |tx| {
            set_task_requirements(tx, "t", away.clone(), 1)
        })
        .unwrap()
    );
    assert_eq!(groups(&connection, "t"), Some(away));
    journalled(&mut connection, "Edit Conditions", |tx| {
        set_task_requirements(tx, "t", vec![], 1)
    })
    .unwrap();
    assert_eq!(groups(&connection, "t"), None);
}

#[test]
fn a_second_condition_with_a_live_name_is_the_first() {
    let mut connection = workspace();
    let home = make(&mut connection, "Home", Some("Location"));
    assert_eq!(make(&mut connection, " home ", None), home);
    connection
        .execute(
            "UPDATE task_conditions SET isArchived = 1 WHERE id = ?1",
            [&home],
        )
        .unwrap();
    assert_ne!(make(&mut connection, "Home", None), home);
}
