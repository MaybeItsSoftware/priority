use rusqlite::Connection;

use super::*;
use crate::journal::journalled;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// Wednesday 11 March 2026, 10:00 UTC.
const NOW: i64 = 1_773_223_200_000;

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
               VALUES ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO task_conditions (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt)
               VALUES ('home', 'w', 'Home', 1, 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, estimateSeconds, createdAt, updatedAt) VALUES
               ('write', 'l', 'Write', 0, 1500, '{T}', '{T}'),
               ('read', 'l', 'Read', 1, 600, '{T}', '{T}'),
               ('garden', 'l', 'Garden', 2, 1800, '{T}', '{T}');
             INSERT INTO task_metadata (taskId, planningJSON, updatedAt)
               VALUES ('garden', '{{\"requirementGroups\":[[\"home\"]]}}', '{T}');"
        ))
        .unwrap();
    connection
}

fn session(
    connection: &Connection,
    id: &str,
) -> (String, Option<String>, Option<String>, Option<String>) {
    connection
        .query_row(
            "SELECT phase, activeTaskId, pausedAt, activeBlockId FROM focus_sessions WHERE id = ?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap()
}

fn start(
    connection: &mut Connection,
    task: &str,
    context: Option<&FocusContext>,
) -> Result<String, CoreError> {
    let tx = connection.transaction().unwrap();
    let id = start_session(&tx, task, None, 1_500, 300, context, false, NOW, "UTC")?;
    tx.commit().unwrap();
    Ok(id)
}

#[test]
fn a_task_needing_a_condition_is_not_available_without_it() {
    let mut connection = workspace();
    let away = FocusContext {
        mode: "progress".into(),
        ..Default::default()
    };
    assert!(matches!(
        start(&mut connection, "garden", Some(&away)),
        Err(CoreError::Unavailable)
    ));
    let home = FocusContext {
        condition_ids: vec!["home".into()],
        ..away
    };
    let id = start(&mut connection, "garden", Some(&home)).unwrap();
    assert_eq!(session(&connection, &id).1.as_deref(), Some("garden"));
    // A second start returns the session already running.
    assert_eq!(start(&mut connection, "write", None).unwrap(), id);
}

#[test]
fn finishing_a_block_completes_the_task_scores_it_and_hands_off() {
    let mut connection = workspace();
    let id = start(&mut connection, "write", None).unwrap();
    {
        let tx = connection.transaction().unwrap();
        add_to_queue(&tx, &id, "read", Some(600), NOW).unwrap();
        add_to_queue(&tx, &id, "read", Some(600), NOW).unwrap();
        tx.commit().unwrap();
    }
    let finished = journalled(&mut connection, "Complete Task", |tx| {
        finish_block(
            tx,
            &id,
            1_200,
            Some(1.5),
            true,
            None,
            &FocusContext::default(),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(finished.outcome, "taskCompleted");
    let status: String = connection
        .query_row("SELECT status FROM tasks WHERE id = 'write'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(status, "completed");
    let (minutes, points): (f64, f64) = connection
        .query_row("SELECT minutes, points FROM focus_awards", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    assert_eq!((minutes, points), (20.0, 30.0));
    let (phase, active, paused, block) = session(&connection, &id);
    assert_eq!(
        (phase.as_str(), active.as_deref(), paused),
        ("running", Some("read"), None)
    );
    assert!(block.is_some());
    let queued: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM focus_queue_items WHERE taskId = 'read'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(queued, 1);

    // The same block again records nothing.
    let again = journalled(&mut connection, "Complete Task", |tx| {
        finish_block(
            tx,
            &id,
            1_200,
            None,
            true,
            Some(&finished.award_id.clone().unwrap()),
            &FocusContext::default(),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(
        (again.outcome.as_str(), again.seconds),
        ("progressLogged", 0)
    );

    // The last block finishes the session.
    journalled(&mut connection, "Complete Task", |tx| {
        finish_block(
            tx,
            &id,
            600,
            None,
            true,
            None,
            &FocusContext::default(),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(session(&connection, &id).0, "finished");
}

#[test]
fn a_blocked_queue_waits_paused_and_resumes_when_the_context_allows() {
    let mut connection = workspace();
    let id = start(&mut connection, "write", None).unwrap();
    {
        let tx = connection.transaction().unwrap();
        add_to_queue(&tx, &id, "garden", None, NOW).unwrap();
        tx.commit().unwrap();
    }
    journalled(&mut connection, "Complete Task", |tx| {
        finish_block(
            tx,
            &id,
            60,
            None,
            true,
            None,
            &FocusContext::default(),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    let (phase, active, paused, _) = session(&connection, &id);
    assert_eq!((phase.as_str(), active), ("running", None));
    assert!(paused.is_some());
    assert!(!has_resumable(&connection, &FocusContext::default(), NOW, "UTC").unwrap());

    let home = FocusContext {
        condition_ids: vec!["home".into()],
        ..Default::default()
    };
    assert!(has_resumable(&connection, &home, NOW, "UTC").unwrap());
    let tx = connection.transaction().unwrap();
    assert!(resume_eligible_queue(&tx, &home, NOW, "UTC").unwrap());
    tx.commit().unwrap();
    assert_eq!(session(&connection, &id).1.as_deref(), Some("garden"));
}

#[test]
fn a_dailys_block_credits_today_and_leaves_the_task_open() {
    let mut connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO dailies (id, taskId, activeWeekdaysMask, targetSeconds, sortOrder, createdAt, updatedAt)
               VALUES ('d', 'read', 127, 900, 0, '{T}', '{T}');"
        ))
        .unwrap();
    let id = start(&mut connection, "read", None).unwrap();
    let finished = journalled(&mut connection, "Log Daily Progress", |tx| {
        finish_block(
            tx,
            &id,
            1_000,
            None,
            false,
            None,
            &FocusContext::default(),
            NOW,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(
        (finished.outcome.as_str(), finished.seconds),
        ("contributionLogged", 1_000)
    );
    let (logged, done): (i64, Option<String>) = connection
        .query_row(
            "SELECT secondsLogged, completedAt FROM daily_contributions WHERE dailyId = 'd'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(logged, 1_000);
    assert!(done.is_some(), "1000 seconds meets a 900-second target");
    let status: String = connection
        .query_row("SELECT status FROM tasks WHERE id = 'read'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(status, "open");
}

#[test]
fn the_clock_banks_time_on_pause_and_checkpoint() {
    let mut connection = workspace();
    let id = start(&mut connection, "write", None).unwrap();
    let banked = |c: &Connection| -> Option<i64> {
        c.query_row(
            "SELECT accumulatedSeconds FROM focus_sessions WHERE id = ?1",
            [&id],
            |row| row.get(0),
        )
        .unwrap()
    };
    let tx = connection.transaction().unwrap();
    checkpoint(&tx, &id, NOW + 90_000).unwrap();
    pause(&tx, &id, NOW + 150_000).unwrap();
    pause(&tx, &id, NOW + 999_000).unwrap();
    tx.commit().unwrap();
    assert_eq!(banked(&connection), Some(150));
    let tx = connection.transaction().unwrap();
    resume(&tx, &id, NOW + 200_000).unwrap();
    rebase(&tx, &id, 30, NOW + 210_000).unwrap();
    checkpoint(&tx, &id, NOW + 220_000).unwrap();
    recover_interrupted(&tx).unwrap();
    finish_session(&tx, &id, NOW + 230_000).unwrap();
    tx.commit().unwrap();
    assert_eq!(banked(&connection), Some(40));
    assert_eq!(session(&connection, &id).0, "finished");
}
