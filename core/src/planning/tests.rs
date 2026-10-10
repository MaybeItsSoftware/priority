//! Ported from Kotlin's `TaskPlanningTest` (Swift had no suite of its own);
//! the decoding cases are what Swift's `JSONDecoder` does with each input,
//! checked against a `Codable` copy of `TaskPlanning`.

use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

fn at_reference_seconds(seconds: i64) -> Option<i64> {
    Some(REFERENCE_DATE_MS + seconds * 1000)
}

#[test]
fn an_empty_plan_normalises_away() {
    assert_eq!(Planning::default().normalized(), None);
    assert_eq!(
        Planning {
            requirement_groups: Some(vec![]),
            requires_single_sitting: Some(false),
            ..Default::default()
        }
        .normalized(),
        None
    );
    assert_eq!(
        Planning {
            minimum_block_seconds: Some(600),
            requires_single_sitting: Some(false),
            ..Default::default()
        }
        .normalized(),
        Some(Planning {
            minimum_block_seconds: Some(600),
            ..Default::default()
        })
    );
    // An empty group inside groups is still a requirement as written.
    let kept = Planning {
        requirement_groups: Some(vec![vec![]]),
        ..Default::default()
    };
    assert_eq!(task_planning_normalized(kept.clone()), Some(kept));
}

#[test]
fn json_omits_absent_fields_and_dates_are_reference_seconds() {
    let plan = Planning {
        start_at_ms: at_reference_seconds(100),
        due_date: Some("2026-10-02".into()),
        requirement_groups: Some(vec![vec!["A".into(), "B".into()]]),
        requires_single_sitting: Some(true),
        ..Default::default()
    };
    let json = task_planning_encode(plan.clone());
    assert_eq!(
        json,
        r#"{"startAt":100,"dueDate":"2026-10-02","requirementGroups":[["A","B"]],"requiresSingleSitting":true}"#
    );
    assert_eq!(task_planning_decode(json.clone()).unwrap(), plan);
    assert_eq!(
        task_planning_decode(json.replace("100", "100.0")).unwrap(),
        plan
    );
    assert_eq!(task_planning_encode(Planning::default()), "{}");
}

#[test]
fn a_start_is_written_shortest_as_swift_writes_a_double() {
    let encode = |ms: i64| {
        task_planning_encode(Planning {
            start_at_ms: Some(ms),
            ..Default::default()
        })
    };
    assert_eq!(
        encode(REFERENCE_DATE_MS + 812_345_678_123),
        r#"{"startAt":812345678.123}"#
    );
    // Date(timeIntervalSince1970: 1759312345.678), as Swift wrote it.
    assert_eq!(encode(1_759_312_345_678), r#"{"startAt":781005145.678}"#);
    assert_eq!(encode(REFERENCE_DATE_MS - 500), r#"{"startAt":-0.5}"#);
    assert_eq!(
        task_planning_decode(r#"{"startAt":1e2}"#.into())
            .unwrap()
            .start_at_ms,
        at_reference_seconds(100)
    );
    assert_eq!(
        task_planning_decode(r#"{"startAt":781005145.678}"#.into())
            .unwrap()
            .start_at_ms,
        Some(1_759_312_345_678)
    );
}

#[test]
fn strings_escape_slashes_and_controls_as_swift_does() {
    let plan = Planning {
        due_date: Some("a/b\u{1}\"\\\t\u{2028}".into()),
        minimum_block_seconds: Some(600),
        ..Default::default()
    };
    let json = task_planning_encode(plan.clone());
    assert_eq!(
        json,
        "{\"dueDate\":\"a\\/b\\u0001\\\"\\\\\\t\u{2028}\",\"minimumBlockSeconds\":600}"
    );
    assert_eq!(task_planning_decode(json).unwrap(), plan);
}

#[test]
fn decoding_is_as_strict_as_swifts_decoder() {
    let read = |json: &str| task_planning_decode(json.into());
    // What Swift's JSONDecoder accepts.
    assert_eq!(read(r#"{"x":1}"#).unwrap(), Planning::default());
    assert_eq!(read(r#" {"dueDate":null} "#).unwrap(), Planning::default());
    assert_eq!(
        read(r#"{"minimumBlockSeconds":600.0}"#)
            .unwrap()
            .minimum_block_seconds,
        Some(600)
    );
    assert_eq!(
        read(r#"{"minimumBlockSeconds":1e3}"#)
            .unwrap()
            .minimum_block_seconds,
        Some(1000)
    );
    assert_eq!(
        read(r#"{"minimumBlockSeconds":-5}"#)
            .unwrap()
            .minimum_block_seconds,
        Some(-5)
    );
    // What it refuses.
    for refused in [
        "",
        "not json",
        "[]",
        "null",
        r#"{"minimumBlockSeconds":600.5}"#,
        r#"{"minimumBlockSeconds":9223372036854775808}"#,
        r#"{"dueDate":5}"#,
        r#"{"requirementGroups":[["a",1]]}"#,
        r#"{"requirementGroups":[null]}"#,
        r#"{"startAt":"x"}"#,
        r#"{"requiresSingleSitting":1}"#,
    ] {
        assert!(
            matches!(read(refused), Err(CoreError::Database { .. })),
            "{refused} should be refused"
        );
    }
}

#[test]
fn the_refusals_read_as_the_platforms_wrote_them() {
    assert_eq!(
        task_planning_error_message(PlanningError::InvalidCondition),
        "A required condition is missing, archived or belongs to another workspace."
    );
    assert_eq!(
        task_planning_error_message(PlanningError::InvalidSchedule),
        "Start must be before the deadline."
    );
    assert_eq!(
        task_planning_error_message(PlanningError::InvalidMinimum),
        "Enter a minimum useful block of at least one minute."
    );
    assert_eq!(
        task_planning_error_message(PlanningError::EstimateRequired),
        "One-sitting tasks need a positive estimate at least as long as their minimum block."
    );
    assert_eq!(
        task_planning_error_message(PlanningError::InvalidDate),
        "Choose a valid calendar date."
    );
    assert_eq!(
        task_planning_error_message(PlanningError::Unavailable),
        "This task or planned block is no longer available in the current conditions and time window."
    );
}

fn workspace(metadata: &str) -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt) VALUES
               ('a', 'l', 'A', 0, '{T}', '{T}'), ('b', 'l', 'B', 1, '{T}', '{T}'),
               ('c', 'l', 'C', 2, '{T}', '{T}'), ('d', 'l', 'D', 3, '{T}', '{T}');
             {metadata}"
        ))
        .unwrap();
    connection
}

#[test]
fn the_values_take_the_start_from_its_column_and_drop_empty_plans() {
    let connection = workspace(&format!(
        r#"INSERT INTO task_metadata (taskId, startAt, planningJSON, updatedAt) VALUES
             ('a', NULL, '{{"startAt":5,"requirementGroups":[["home"]]}}', '{T}'),
             ('b', '2001-01-01 00:01:40.000', NULL, '{T}'),
             ('c', NULL, '{{"requirementGroups":[],"requiresSingleSitting":false}}', '{T}'),
             ('d', NULL, NULL, '{T}');"#
    ));
    let values = planning_values(&connection).unwrap();
    assert_eq!(
        values,
        [
            TaskPlanningEntry {
                task_id: "a".into(),
                planning: Planning {
                    requirement_groups: Some(vec![vec!["home".into()]]),
                    ..Default::default()
                },
            },
            TaskPlanningEntry {
                task_id: "b".into(),
                planning: Planning {
                    start_at_ms: at_reference_seconds(100),
                    ..Default::default()
                },
            },
        ]
    );
}

#[test]
fn an_unreadable_blob_refuses_the_values() {
    let connection = workspace(&format!(
        r#"INSERT INTO task_metadata (taskId, planningJSON, updatedAt) VALUES ('a', '{{"dueDate":5}}', '{T}');"#
    ));
    assert!(planning_values(&connection).is_err());
}
