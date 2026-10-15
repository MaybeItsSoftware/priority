use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// Wednesday 11 March 2026, 10:00 UTC.
const WEDNESDAY: i64 = 1_773_223_200_000;
const DAY: i64 = 86_400_000;

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
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt)
               VALUES ('thesis', 'l', 'Write thesis', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt)
               VALUES ('chapter', 'l', 'thesis', 'Chapter one', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn draft(rule: &str) -> CommitmentDraft {
    CommitmentDraft {
        title: " Work on thesis ".into(),
        rule: rule.into(),
        expires_at_ms: None,
        stacks_missed: false,
    }
}

fn commit(connection: &mut Connection, draft: &CommitmentDraft, now: i64) -> String {
    journalled(connection, "Commit to Task", |tx| {
        save_commitment(tx, "thesis", draft, None, now, "UTC")
    })
    .unwrap()
}

fn column(connection: &Connection, task_id: &str) -> Option<String> {
    connection
        .query_row(
            "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
            [task_id],
            |row| row.get(0),
        )
        .optional()
        .unwrap()
        .flatten()
}

fn status(connection: &Connection, task_id: &str) -> String {
    connection
        .query_row("SELECT status FROM tasks WHERE id = ?1", [task_id], |row| {
            row.get(0)
        })
        .unwrap()
}

fn shows(connection: &Connection, daily_id: &str, now: i64) -> bool {
    habits::habit_shows(connection, daily_id, now, chrono_tz::UTC).unwrap()
}

#[test]
fn the_recurrence_syntax_reads_as_a_dailys_schedule() {
    let every_day = CommitmentSchedule {
        weekdays: (1..=7).collect(),
        interval_days: None,
    };
    assert_eq!(schedule("daily"), Some(every_day.clone()));
    assert_eq!(schedule(" Every Day "), Some(every_day));
    assert_eq!(schedule("weekdays").unwrap().weekdays, vec![2, 3, 4, 5, 6]);
    assert_eq!(schedule("every friday").unwrap().weekdays, vec![6]);
    assert_eq!(schedule("weekly").unwrap().interval_days, Some(7));
    assert_eq!(schedule("every 2 weeks").unwrap().interval_days, Some(14));
    assert_eq!(schedule("every 3 days").unwrap().interval_days, Some(3));
    assert_eq!(schedule("mon, wed, fri").unwrap().weekdays, vec![2, 4, 6]);
    assert_eq!(schedule("every tue and thu").unwrap().weekdays, vec![3, 5]);
    assert_eq!(schedule(""), None);
    assert_eq!(schedule("sometimes"), None);
    assert_eq!(schedule("mon, someday"), None);
}

#[test]
fn a_schedule_is_written_back_in_the_syntax_it_was_read_in() {
    for rule in [
        "daily",
        "weekdays",
        "every friday",
        "weekly",
        "every 2 weeks",
        "every 3 days",
        "mon, wed, fri",
        "sat, sun",
    ] {
        assert_eq!(rule_text(&schedule(rule).unwrap()), rule, "{rule}");
    }
    assert_eq!(rule_text(&schedule("every day").unwrap()), "daily");
}

#[test]
fn only_a_weekly_rhythm_carries_a_missed_day() {
    assert!(!schedule("daily").unwrap().carries_missed_days());
    assert!(!schedule("weekdays").unwrap().carries_missed_days());
    assert!(!schedule("every 3 days").unwrap().carries_missed_days());
    assert!(schedule("every friday").unwrap().carries_missed_days());
    assert!(schedule("every 2 weeks").unwrap().carries_missed_days());
}

#[test]
fn a_new_commitment_is_offered_a_name_from_its_task() {
    assert_eq!(default_title(" Write thesis "), "Work on Write thesis");
    assert_eq!(default_title(""), "Work on it");
}

#[test]
fn committing_makes_a_linked_subtask_that_lands_in_today_and_undoes_in_one_step() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);

    let (parent, list, title): (String, String, String) = connection
        .query_row(
            "SELECT parentTaskId, listId, title FROM tasks WHERE id = ?1",
            [&subtask],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(parent, "thesis");
    assert_eq!(list, "l");
    assert_eq!(title, "Work on thesis");
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));

    let live = commitments(&connection, "thesis").unwrap();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].task_id, subtask);
    assert_eq!(live[0].rule, "daily");
    assert_eq!(live[0].expires_at_ms, None);
    assert_eq!(
        commitment(&connection, &subtask).unwrap(),
        Some(live[0].clone())
    );
    // An ordinary subtask is not one.
    assert_eq!(all_commitments(&connection).unwrap(), live);
    assert_eq!(commitment(&connection, "chapter").unwrap(), None);
    assert!(commitments(&connection, "chapter").unwrap().is_empty());

    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Commit to Task")
    );
    assert!(commitments(&connection, "thesis").unwrap().is_empty());
}

#[test]
fn a_weekly_commitment_shows_only_on_its_day_and_is_carried_when_missed() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("every friday"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    assert_eq!(column(&connection, &subtask), None);
    assert!(!shows(&connection, &daily, WEDNESDAY));
    assert!(shows(&connection, &daily, WEDNESDAY + 2 * DAY));
    // Missed on Friday, still owed on Saturday.
    assert!(shows(&connection, &daily, WEDNESDAY + 3 * DAY));
}

#[test]
fn a_commitment_stops_on_its_end_date() {
    let mut connection = workspace();
    let ends = CommitmentDraft {
        expires_at_ms: Some(WEDNESDAY + 2 * DAY),
        ..draft("daily")
    };
    let subtask = commit(&mut connection, &ends, WEDNESDAY);
    let live = commitment(&connection, &subtask).unwrap().unwrap();
    assert_eq!(
        live.expires_at_ms,
        Some(habits::start_of_day_ms(
            habits::local_day(WEDNESDAY + 2 * DAY, chrono_tz::UTC),
            chrono_tz::UTC
        ))
    );
    assert!(shows(&connection, &live.daily_id, WEDNESDAY + DAY));
    assert!(!shows(&connection, &live.daily_id, WEDNESDAY + 2 * DAY));
    let tx = connection.transaction().unwrap();
    assert!(habits::reconcile_habits(&tx, WEDNESDAY + 2 * DAY, "UTC").unwrap());
    tx.commit().unwrap();
    assert_eq!(commitment(&connection, &subtask).unwrap(), None);
    assert_eq!(column(&connection, &subtask), None);
}

#[test]
fn completing_the_task_ends_its_commitment_whatever_its_end_date() {
    let mut connection = workspace();
    let ends = CommitmentDraft {
        expires_at_ms: Some(WEDNESDAY + 30 * DAY),
        ..draft("daily")
    };
    let subtask = commit(&mut connection, &ends, WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    journalled(&mut connection, "Change Status", |tx| {
        tasks::set_status(tx, "thesis", "completed", WEDNESDAY + DAY, "UTC")
    })
    .unwrap();
    let archived: Option<String> = connection
        .query_row(
            "SELECT archivedAt FROM dailies WHERE id = ?1",
            [&daily],
            |row| row.get(0),
        )
        .unwrap();
    assert!(archived.is_some());
    assert_eq!(status(&connection, &subtask), "completed");
    assert_eq!(column(&connection, &subtask), None);
    assert!(commitments(&connection, "thesis").unwrap().is_empty());
}

#[test]
fn the_habit_pass_ends_a_commitment_whose_task_was_closed_some_other_way() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    // As a sync from elsewhere would land it: the parent alone, no cascade.
    connection
        .execute(
            "UPDATE tasks SET status = 'completed' WHERE id = 'thesis'",
            [],
        )
        .unwrap();
    assert!(!shows(&connection, &daily, WEDNESDAY + DAY));
    let tx = connection.transaction().unwrap();
    assert!(habits::reconcile_habits(&tx, WEDNESDAY + DAY, "UTC").unwrap());
    tx.commit().unwrap();
    assert_eq!(column(&connection, &subtask), None);
}

#[test]
fn editing_rewrites_the_schedule_and_name_in_place() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let edited = CommitmentDraft {
        title: "Draft a page".into(),
        rule: "weekdays".into(),
        expires_at_ms: None,
        stacks_missed: false,
    };
    let again = journalled(&mut connection, "Edit Commitment", |tx| {
        save_commitment(tx, "thesis", &edited, Some(&subtask), WEDNESDAY, "UTC")
    })
    .unwrap();
    assert_eq!(again, subtask);
    let live = commitments(&connection, "thesis").unwrap();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].title, "Draft a page");
    assert_eq!(live[0].rule, "weekdays");
    // A subtask that is not this task's commitment cannot be edited as one.
    let refused = journalled(&mut connection, "Edit Commitment", |tx| {
        save_commitment(tx, "thesis", &edited, Some("chapter"), WEDNESDAY, "UTC")
    });
    assert!(matches!(refused, Err(CoreError::MissingTask { .. })));
}

#[test]
fn an_unreadable_schedule_or_an_empty_name_is_refused() {
    let mut connection = workspace();
    let refused = journalled(&mut connection, "Commit to Task", |tx| {
        save_commitment(tx, "thesis", &draft("now and then"), None, WEDNESDAY, "UTC")
    });
    assert!(matches!(refused, Err(CoreError::InvalidRecurrence { .. })));
    let unnamed = CommitmentDraft {
        title: "  ".into(),
        ..draft("daily")
    };
    let refused = journalled(&mut connection, "Commit to Task", |tx| {
        save_commitment(tx, "thesis", &unnamed, None, WEDNESDAY, "UTC")
    });
    assert!(matches!(refused, Err(CoreError::EmptyName)));
    let missing = journalled(&mut connection, "Commit to Task", |tx| {
        save_commitment(tx, "gone", &draft("daily"), None, WEDNESDAY, "UTC")
    });
    assert!(matches!(missing, Err(CoreError::MissingTask { .. })));
    let count: i64 = connection
        .query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 2);
}

#[test]
fn stopping_archives_the_daily_closes_the_subtask_and_keeps_its_history() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    journalled(&mut connection, "Log Daily", |tx| {
        crate::dailies::log_contribution(tx, &daily, 600, true, WEDNESDAY, "UTC")
    })
    .unwrap();
    journalled(&mut connection, "Stop Commitment", |tx| {
        stop_commitment(tx, &subtask, WEDNESDAY + DAY, "UTC")
    })
    .unwrap();
    assert!(commitments(&connection, "thesis").unwrap().is_empty());
    assert_eq!(status(&connection, &subtask), "completed");
    assert_eq!(status(&connection, "thesis"), "open");
    assert_eq!(column(&connection, &subtask), None);
    let logged: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM daily_contributions WHERE dailyId = ?1",
            [&daily],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(logged, 1);
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Stop Commitment")
    );
    assert_eq!(commitments(&connection, "thesis").unwrap().len(), 1);
    // Stopping what is not a commitment does nothing.
    journalled(&mut connection, "Stop Commitment", |tx| {
        stop_commitment(tx, "chapter", WEDNESDAY, "UTC")
    })
    .unwrap();
    assert_eq!(status(&connection, "chapter"), "open");
}

fn reconcile(connection: &mut Connection, now: i64) {
    let tx = connection.transaction().unwrap();
    habits::reconcile_habits(&tx, now, "UTC").unwrap();
    tx.commit().unwrap();
}

fn done(connection: &mut Connection, daily: &str, now: i64) {
    journalled(connection, "Log Daily", |tx| {
        crate::dailies::log_contribution(tx, daily, 0, true, now, "UTC")
    })
    .unwrap();
}

fn done_days(connection: &Connection, daily: &str) -> Vec<String> {
    let mut statement = connection
        .prepare(
            "SELECT dayKey FROM daily_contributions WHERE dailyId = ?1 AND completedAt IS NOT NULL ORDER BY dayKey",
        )
        .unwrap();
    statement
        .query_map([daily], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn by_default_a_missed_appearance_vanishes() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("mon, wed, fri"), WEDNESDAY);
    let live = commitment(&connection, &subtask).unwrap().unwrap();
    assert!(!live.stacks_missed);
    // Wednesday is missed: on Thursday it has gone from Today.
    assert!(!shows(&connection, &live.daily_id, WEDNESDAY + DAY));
    reconcile(&mut connection, WEDNESDAY + DAY);
    assert_eq!(column(&connection, &subtask), None);
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + DAY, "UTC").unwrap(),
        0
    );
    // Friday's comes, and one completion clears it: nothing is owed.
    reconcile(&mut connection, WEDNESDAY + 2 * DAY);
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
    done(&mut connection, &live.daily_id, WEDNESDAY + 2 * DAY);
    reconcile(&mut connection, WEDNESDAY + 2 * DAY);
    assert_eq!(column(&connection, &subtask), None);
    assert_eq!(done_days(&connection, &live.daily_id), vec!["2026-03-13"]);
}

#[test]
fn a_stacking_commitment_keeps_each_missed_appearance_until_it_is_done() {
    let mut connection = workspace();
    let stacking = CommitmentDraft {
        stacks_missed: true,
        ..draft("mon, wed, fri")
    };
    let subtask = commit(&mut connection, &stacking, WEDNESDAY);
    let live = commitment(&connection, &subtask).unwrap().unwrap();
    assert!(live.stacks_missed);
    // Wednesday is missed: on Thursday it is still in Today, owed.
    assert!(shows(&connection, &live.daily_id, WEDNESDAY + DAY));
    reconcile(&mut connection, WEDNESDAY + DAY);
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + DAY, "UTC").unwrap(),
        1
    );
    // Friday's comes on top of it: two owed, one of them missed.
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 2 * DAY, "UTC").unwrap(),
        1
    );
    // The first completion pays off Wednesday, so the card stays for Friday's.
    done(&mut connection, &live.daily_id, WEDNESDAY + 2 * DAY);
    assert_eq!(done_days(&connection, &live.daily_id), vec!["2026-03-11"]);
    reconcile(&mut connection, WEDNESDAY + 2 * DAY);
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 2 * DAY, "UTC").unwrap(),
        0
    );
    // The second is Friday's own, and the stack is clear.
    done(&mut connection, &live.daily_id, WEDNESDAY + 2 * DAY);
    assert_eq!(
        done_days(&connection, &live.daily_id),
        vec!["2026-03-11", "2026-03-13"]
    );
    reconcile(&mut connection, WEDNESDAY + 2 * DAY);
    assert_eq!(column(&connection, &subtask), None);
    assert!(!shows(&connection, &live.daily_id, WEDNESDAY + 3 * DAY));
}

#[test]
fn turning_stacking_on_does_not_bill_for_days_missed_before_it() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    // Thursday and Friday are missed while it vanishes; stacking starts Saturday.
    let stacking = CommitmentDraft {
        stacks_missed: true,
        ..draft("daily")
    };
    journalled(&mut connection, "Edit Commitment", |tx| {
        save_commitment(
            tx,
            "thesis",
            &stacking,
            Some(&subtask),
            WEDNESDAY + 3 * DAY,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 3 * DAY, "UTC").unwrap(),
        0
    );
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 5 * DAY, "UTC").unwrap(),
        2
    );
    // Saving it again with stacking left on keeps what is owed.
    journalled(&mut connection, "Edit Commitment", |tx| {
        save_commitment(
            tx,
            "thesis",
            &stacking,
            Some(&subtask),
            WEDNESDAY + 5 * DAY,
            "UTC",
        )
    })
    .unwrap();
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 5 * DAY, "UTC").unwrap(),
        2
    );
    // Turning it off forgives them, and undoing that brings them back.
    journalled(&mut connection, "Edit Commitment", |tx| {
        save_commitment(
            tx,
            "thesis",
            &draft("daily"),
            Some(&subtask),
            WEDNESDAY + 5 * DAY,
            "UTC",
        )
    })
    .unwrap();
    assert!(
        !commitment(&connection, &subtask)
            .unwrap()
            .unwrap()
            .stacks_missed
    );
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 5 * DAY, "UTC").unwrap(),
        0
    );
    undo(&mut connection).unwrap();
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + 5 * DAY, "UTC").unwrap(),
        2
    );
}

fn resting(connection: &Connection, now: i64) -> HashSet<String> {
    resting_task_ids(connection, now, "UTC").unwrap()
}

fn complete(connection: &mut Connection, task_id: &str, now: i64) {
    journalled(connection, "Change Status", |tx| {
        tasks::set_status(tx, task_id, "completed", now, "UTC")
    })
    .unwrap();
}

#[test]
fn completing_a_commitments_subtask_ticks_today_and_rests_it_until_its_next_day() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    assert!(resting(&connection, WEDNESDAY).is_empty());

    complete(&mut connection, &subtask, WEDNESDAY);
    // Done for the day, not for good: it stays open, its card leaves Today,
    // and it rests.
    assert_eq!(status(&connection, &subtask), "open");
    assert_eq!(done_days(&connection, &daily), vec!["2026-03-11"]);
    assert_eq!(column(&connection, &subtask), None);
    assert!(commitment(&connection, &subtask).unwrap().is_some());
    assert!(resting(&connection, WEDNESDAY).contains(&subtask));
    assert_eq!(commitments(&connection, "thesis").unwrap().len(), 1);

    // Its next day it is back, on its own.
    assert!(resting(&connection, WEDNESDAY + DAY).is_empty());
}

#[test]
fn undoing_the_tick_brings_a_resting_commitment_straight_back() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    complete(&mut connection, &subtask, WEDNESDAY);
    assert!(resting(&connection, WEDNESDAY).contains(&subtask));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Change Status")
    );
    assert!(resting(&connection, WEDNESDAY).is_empty());
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
}

#[test]
fn a_commitment_rests_on_a_day_that_is_not_one_of_its_days() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("weekdays"), WEDNESDAY);
    // Saturday 14 March is not a weekday, and a missed Friday is not carried.
    assert!(resting(&connection, WEDNESDAY + 3 * DAY).contains(&subtask));
    assert!(resting(&connection, WEDNESDAY + 4 * DAY).contains(&subtask));
    // Monday it is back.
    assert!(resting(&connection, WEDNESDAY + 5 * DAY).is_empty());
}

#[test]
fn a_stacking_commitment_does_not_rest_while_anything_is_owed() {
    let mut connection = workspace();
    let stacking = CommitmentDraft {
        stacks_missed: true,
        ..draft("daily")
    };
    let subtask = commit(&mut connection, &stacking, WEDNESDAY);
    // Wednesday and Thursday missed: on Friday three are owed.
    let friday = WEDNESDAY + 2 * DAY;
    complete(&mut connection, &subtask, friday);
    assert!(!resting(&connection, friday).contains(&subtask));
    complete(&mut connection, &subtask, friday);
    assert!(!resting(&connection, friday).contains(&subtask));
    complete(&mut connection, &subtask, friday);
    assert!(resting(&connection, friday).contains(&subtask));
    assert_eq!(status(&connection, &subtask), "open");
}

#[test]
fn what_is_filed_beneath_a_resting_commitment_rests_with_it_and_the_boards_leave_both_out() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    connection
        .execute(
            &format!(
                "INSERT INTO tasks (id, listId, parentTaskId, title, sortOrder, createdAt, updatedAt)
                 VALUES ('scales', 'l', '{subtask}', 'Scales', 0, '{T}', '{T}')"
            ),
            [],
        )
        .unwrap();
    complete(&mut connection, &subtask, WEDNESDAY);
    let rests = resting(&connection, WEDNESDAY);
    assert!(rests.contains(&subtask) && rests.contains("scales"));
    assert_eq!(rests.len(), 2);

    let lists = vec!["l".to_string()];
    let cards: Vec<String> = crate::board::cards_of(&connection, &lists, None, &rests)
        .unwrap()
        .into_iter()
        .map(|task| task.id)
        .collect();
    assert_eq!(cards, vec!["thesis", "chapter"]);
    let everything: Vec<String> =
        crate::board::cards_of(&connection, &lists, None, &HashSet::new())
            .unwrap()
            .into_iter()
            .map(|task| task.id)
            .collect();
    assert_eq!(everything.len(), 4);
}

#[test]
fn completing_the_parent_or_stopping_it_still_ends_it() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    complete(&mut connection, "thesis", WEDNESDAY);
    assert_eq!(status(&connection, &subtask), "completed");
    assert!(commitments(&connection, "thesis").unwrap().is_empty());
    assert!(resting(&connection, WEDNESDAY).is_empty());

    // Stopping it closes it for good, as it always has, even after a skip.
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    cancel(&mut connection, &subtask, WEDNESDAY);
    journalled(&mut connection, "Stop Commitment", |tx| {
        stop_commitment(tx, &subtask, WEDNESDAY, "UTC")
    })
    .unwrap();
    assert_eq!(status(&connection, &subtask), "completed");
    assert!(commitments(&connection, "thesis").unwrap().is_empty());
}

fn cancel(connection: &mut Connection, task_id: &str, now: i64) {
    journalled(connection, "Change Status", |tx| {
        tasks::set_status(tx, task_id, "cancelled", now, "UTC")
    })
    .unwrap();
}

fn skipped_days(connection: &Connection, daily: &str) -> Vec<String> {
    let mut statement = connection
        .prepare(
            "SELECT dayKey FROM daily_contributions WHERE dailyId = ?1 AND skippedAt IS NOT NULL ORDER BY dayKey",
        )
        .unwrap();
    statement
        .query_map([daily], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn cancelling_a_commitments_subtask_skips_today_and_the_commitment_stays_live() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    let is_candidate = |connection: &Connection| {
        crate::focus::candidates(connection, WEDNESDAY, "UTC")
            .unwrap()
            .iter()
            .any(|candidate| candidate.id == subtask)
    };
    assert!(is_candidate(&connection));

    cancel(&mut connection, &subtask, WEDNESDAY);
    // Set aside without a tick: the subtask stays open, the commitment live,
    // its card leaves Today and it rests.
    assert_eq!(status(&connection, &subtask), "open");
    assert!(done_days(&connection, &daily).is_empty());
    assert_eq!(skipped_days(&connection, &daily), vec!["2026-03-11"]);
    assert!(commitment(&connection, &subtask).unwrap().is_some());
    assert_eq!(commitments(&connection, "thesis").unwrap().len(), 1);
    assert_eq!(column(&connection, &subtask), None);
    assert!(resting(&connection, WEDNESDAY).contains(&subtask));
    // Next-up passes over it as it does a ticked one.
    assert!(!is_candidate(&connection));

    // Its next day it is back, on its own.
    assert!(resting(&connection, WEDNESDAY + DAY).is_empty());
    reconcile(&mut connection, WEDNESDAY + DAY);
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
}

#[test]
fn a_skipped_day_comes_back_on_the_next_scheduled_one() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("mon, wed, fri"), WEDNESDAY);
    cancel(&mut connection, &subtask, WEDNESDAY);
    // Thursday is not one of its days, and the skipped Wednesday is not
    // carried: it rests until Friday.
    assert!(resting(&connection, WEDNESDAY + DAY).contains(&subtask));
    assert!(resting(&connection, WEDNESDAY + 2 * DAY).is_empty());

    // A weekly one would carry a missed day; a skipped one it does not.
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("every wednesday"), WEDNESDAY);
    cancel(&mut connection, &subtask, WEDNESDAY);
    assert!(resting(&connection, WEDNESDAY + DAY).contains(&subtask));
    assert!(resting(&connection, WEDNESDAY + 7 * DAY).is_empty());
}

#[test]
fn a_skipped_day_is_not_owed_when_missed_appearances_stack() {
    let mut connection = workspace();
    let stacking = CommitmentDraft {
        stacks_missed: true,
        ..draft("daily")
    };
    let subtask = commit(&mut connection, &stacking, WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    cancel(&mut connection, &subtask, WEDNESDAY);
    assert!(resting(&connection, WEDNESDAY).contains(&subtask));
    // Thursday: Wednesday was skipped, not missed, so nothing is owed.
    assert_eq!(
        missed(&connection, &subtask, WEDNESDAY + DAY, "UTC").unwrap(),
        0
    );
    // One completion is Thursday's own and clears it.
    complete(&mut connection, &subtask, WEDNESDAY + DAY);
    assert_eq!(done_days(&connection, &daily), vec!["2026-03-12"]);
    assert!(resting(&connection, WEDNESDAY + DAY).contains(&subtask));

    // With a missed day owed, a skip sets aside the oldest, as a tick pays it.
    let mut connection = workspace();
    let subtask = commit(&mut connection, &stacking, WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    let thursday = WEDNESDAY + DAY;
    cancel(&mut connection, &subtask, thursday);
    assert_eq!(skipped_days(&connection, &daily), vec!["2026-03-11"]);
    assert_eq!(missed(&connection, &subtask, thursday, "UTC").unwrap(), 0);
    assert!(!resting(&connection, thursday).contains(&subtask));
    cancel(&mut connection, &subtask, thursday);
    assert_eq!(
        skipped_days(&connection, &daily),
        vec!["2026-03-11", "2026-03-12"]
    );
    assert!(resting(&connection, thursday).contains(&subtask));
    assert_eq!(status(&connection, &subtask), "open");
}

#[test]
fn undoing_the_skip_brings_a_resting_commitment_straight_back() {
    let mut connection = workspace();
    let subtask = commit(&mut connection, &draft("daily"), WEDNESDAY);
    let daily = commitment(&connection, &subtask).unwrap().unwrap().daily_id;
    cancel(&mut connection, &subtask, WEDNESDAY);
    assert!(resting(&connection, WEDNESDAY).contains(&subtask));
    assert_eq!(
        undo(&mut connection).unwrap().as_deref(),
        Some("Change Status")
    );
    assert!(resting(&connection, WEDNESDAY).is_empty());
    assert!(skipped_days(&connection, &daily).is_empty());
    assert_eq!(column(&connection, &subtask).as_deref(), Some("today"));
    assert_eq!(status(&connection, &subtask), "open");
}
