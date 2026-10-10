//! Ported from the iPhone's `ReviewModelTests` and Android's
//! `ReviewModelsTest`, which still run against the wrappers.

use chrono::{TimeZone, Utc};
use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const MINUTE: i64 = 60_000;
const HOUR: i64 = 60 * MINUTE;

fn utc(y: i32, m: u32, d: u32, h: u32, min: u32) -> i64 {
    Utc.with_ymd_and_hms(y, m, d, h, min, 0)
        .unwrap()
        .timestamp_millis()
}

fn logged(id: &str, key: &str, seconds: i64, ended_at_ms: i64) -> ReviewTimelineBlock {
    ReviewTimelineBlock {
        id: id.into(),
        task_key: key.into(),
        seconds,
        ended_at_ms,
        is_live: false,
    }
}

fn live(id: &str, key: &str, seconds: i64) -> ReviewTimelineBlock {
    ReviewTimelineBlock {
        is_live: true,
        ..logged(id, key, seconds, 0)
    }
}

fn award(id: &str, points: f64) -> ReviewAwardPoints {
    ReviewAwardPoints {
        id: id.into(),
        points,
    }
}

#[test]
fn the_timeline_groups_blocks_by_task_and_orders_by_time() {
    let day = utc(2026, 3, 10, 12, 0);
    let timeline = review_timeline(
        vec![
            logged("b1", "a", 1_500, utc(2026, 3, 10, 9, 30)),
            logged("b2", "b", 3_000, utc(2026, 3, 10, 11, 0)),
            logged("b3", "a", 600, utc(2026, 3, 10, 14, 0)),
            logged("empty", "c", 0, utc(2026, 3, 10, 15, 0)),
        ],
        vec![award("b1", 2.5), award("b2", 4.0), award("b1", 99.0)],
        day,
        utc(2026, 3, 11, 9, 0),
        "UTC".into(),
    );
    assert_eq!(timeline.kept, vec![0, 1, 2]);
    assert_eq!(timeline.total_seconds, 5_100);
    assert_eq!(timeline.points, 6.5);
    let keys: Vec<_> = timeline.summaries.iter().map(|s| s.key.as_str()).collect();
    assert_eq!(keys, vec!["b", "a"]);
    assert_eq!(timeline.summaries[1].latest, 2);
    assert_eq!(timeline.summaries[1].blocks, 2);
    assert_eq!(timeline.summaries[1].seconds, 2_100);
    let placed: Vec<u32> = timeline.layout.placements.iter().map(|p| p.block).collect();
    assert_eq!(placed, vec![0, 1, 2]);
    assert_eq!(timeline.layout.start_ms, utc(2026, 3, 10, 9, 0));
}

#[test]
fn the_running_block_shows_only_on_today_and_ends_now() {
    let now = utc(2026, 3, 10, 16, 0);
    let blocks = vec![
        logged("b1", "a", 1_200, utc(2026, 3, 10, 10, 0)),
        live("live", "a", 900),
    ];
    let today = review_timeline(
        blocks.clone(),
        vec![award("live", 5.0)],
        now,
        now,
        "UTC".into(),
    );
    assert_eq!(today.kept, vec![0, 1]);
    assert_eq!(today.total_seconds, 2_100);
    assert_eq!(today.points, 0.0, "a running block has no award yet");
    let placement = today
        .layout
        .placements
        .iter()
        .find(|p| p.block == 1)
        .unwrap();
    assert_eq!(
        placement.offset_minutes + placement.minutes,
        (now - today.layout.start_ms) as f64 / MINUTE as f64
    );
    assert_eq!(today.summaries.len(), 1);
    assert_eq!(today.summaries[0].latest, 1);

    let yesterday = review_timeline(blocks, vec![], now - 24 * HOUR, now, "UTC".into());
    assert_eq!(yesterday.kept, vec![0]);
    assert!(yesterday.layout.placements.iter().all(|p| p.block == 0));
}

#[test]
fn a_running_block_with_no_time_yet_is_left_out() {
    let now = utc(2026, 3, 10, 16, 0);
    let timeline = review_timeline(vec![live("live", "a", 0)], vec![], now, now, "UTC".into());
    assert!(timeline.kept.is_empty());
    assert!(timeline.summaries.is_empty());
    assert_eq!(timeline.layout.lane_count, 1);
}

fn seconds(seconds: i64, at: i64) -> WorkBlockSeconds {
    WorkBlockSeconds {
        seconds,
        recorded_at_ms: at,
    }
}

#[test]
fn progress_buckets_every_day_of_the_period() {
    let now = utc(2026, 3, 10, 15, 0);
    let summary = summarise_review_progress(
        7,
        vec![
            utc(2026, 3, 10, 9, 0),
            utc(2026, 3, 8, 9, 0),
            utc(2026, 3, 8, 10, 0),
        ],
        vec![utc(2026, 3, 9, 9, 0), utc(2026, 3, 1, 9, 0)],
        vec![
            seconds(1_800, utc(2026, 3, 10, 9, 0)),
            seconds(1_259, utc(2026, 3, 10, 11, 0)),
            seconds(600, utc(2026, 3, 8, 9, 0)),
        ],
        now,
        "UTC".into(),
    );
    assert_eq!(summary.days.len(), 7);
    let last = summary.days[6];
    assert_eq!(last.day_start_ms, utc(2026, 3, 10, 0, 0));
    assert_eq!(last.completed, 1);
    assert_eq!(
        last.focus_minutes, 50,
        "seconds are summed before they are cut to minutes"
    );
    assert_eq!(last.cumulative_completed, 3);
    assert_eq!(
        last.cumulative_added, 1,
        "a creation before the period is not counted"
    );
    assert_eq!(summary.total_completed, 3);
    assert_eq!(summary.total_added, 1);
    assert_eq!(summary.focus_minutes, 60);
    assert_eq!(summary.best_day, Some(4));
}

#[test]
fn the_best_day_is_the_first_of_equals_and_none_without_a_completion() {
    let now = utc(2026, 3, 10, 15, 0);
    let tied = summarise_review_progress(
        7,
        vec![utc(2026, 3, 6, 9, 0), utc(2026, 3, 9, 9, 0)],
        vec![],
        vec![],
        now,
        "UTC".into(),
    );
    assert_eq!(tied.best_day, Some(2));
    let empty = summarise_review_progress(7, vec![], vec![], vec![], now, "UTC".into());
    assert_eq!(empty.best_day, None);
    assert!(empty.days.iter().all(|day| day.focus_minutes == 0));
}

#[test]
fn a_day_in_a_zone_with_a_clock_change_still_counts_its_minutes() {
    // London's clocks went forward on 29 March 2026.
    let zone = "Europe/London";
    let now = utc(2026, 3, 29, 15, 0);
    let summary = summarise_review_progress(
        2,
        vec![],
        vec![],
        vec![seconds(600, utc(2026, 3, 29, 0, 30))],
        now,
        zone.into(),
    );
    assert_eq!(summary.days[1].focus_minutes, 10);
}

#[test]
fn progress_reads_the_rows_itself() {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    let t = "2025-01-01 00:00:00.000";
    let stamp = crate::time::stored;
    let now = utc(2026, 3, 10, 15, 0);
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{t}', '{t}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
               VALUES ('l', 'w', 'Inbox', 0, '{t}', '{t}');
             INSERT INTO tasks (id, listId, title, sortOrder, status, completedAt, createdAt, updatedAt) VALUES
               ('a', 'l', 'A', 0, 'completed', '{today}', '{yesterday}', '{t}'),
               ('b', 'l', 'B', 1, 'open', NULL, '{today}', '{t}');
             INSERT INTO focus_work_blocks (id, taskTitle, seconds, recordedAt)
               VALUES ('x', 'A', 1200, '{today}'), ('y', 'B', 600, '{old}');",
            today = stamp(utc(2026, 3, 10, 9, 0)),
            yesterday = stamp(utc(2026, 3, 9, 9, 0)),
            old = stamp(utc(2026, 2, 1, 9, 0)),
        ))
        .unwrap();
    let read = read_review_progress(&connection, 7, now, "UTC").unwrap();
    assert_eq!(read.total_completed, 1);
    assert_eq!(read.total_added, 2);
    assert_eq!(read.focus_minutes, 20);
    assert_eq!(read.best_day, Some(6));
}
