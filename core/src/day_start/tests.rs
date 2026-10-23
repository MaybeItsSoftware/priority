use chrono::{DateTime, Utc};
use rusqlite::Connection;

use super::*;
use crate::schema::migrate;
use crate::sync::{self, IncomingRow};

const T: &str = "2024-01-01 00:00:00.000";
const LONDON: &str = "Europe/London";

/// A workspace with two places, a setting and an archived place.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch("PRAGMA foreign_keys = ON")
        .unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_conditions (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt, category)
               VALUES ('home', 'w', 'Home', 1, 0, '{T}', '{T}', 'Location'),
                      ('campus', 'w', 'Campus', 1, 0, '{T}', '{T}', 'Location'),
                      ('laptop', 'w', 'Laptop', 0, 0, '{T}', '{T}', 'Tools on hand'),
                      ('old', 'w', 'Old flat', 1, 1, '{T}', '{T}', 'Location');"
        ))
        .unwrap();
    connection
}

fn ms(text: &str) -> i64 {
    DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&Utc)
        .timestamp_millis()
}

fn starting(ids: &[&str]) -> DayStartSettings {
    DayStartSettings {
        resets: true,
        hour: 4,
        condition_ids: ids.iter().map(|id| id.to_string()).collect(),
        last_reset_day: None,
    }
}

fn configure(connection: &mut Connection, settings: &DayStartSettings, now_ms: i64) {
    let tx = connection.transaction().unwrap();
    assert!(save(&tx, settings, now_ms, LONDON).unwrap());
    tx.commit().unwrap();
}

fn say(connection: &mut Connection, context: StoredFocusContext, now_ms: i64) {
    let tx = connection.transaction().unwrap();
    focus_context::save(&tx, "w", &context, now_ms).unwrap();
    tx.commit().unwrap();
}

fn reset(connection: &mut Connection, now_ms: i64) -> bool {
    let tx = connection.transaction().unwrap();
    let reset = apply(&tx, "w", now_ms, LONDON).unwrap();
    tx.commit().unwrap();
    reset
}

fn context(connection: &Connection) -> StoredFocusContext {
    focus_context::load(connection, "w").unwrap().unwrap()
}

/// At Campus with a laptop, Laptop's quiet switched off, an hour free and
/// an expiry: everything a reset clears.
fn busy_evening(at: i64) -> StoredFocusContext {
    StoredFocusContext {
        condition_ids: vec!["campus".into(), "laptop".into()],
        available_until_ms: Some(at + 3_600_000),
        expires_at_ms: Some(at + 86_400_000 * 3),
        suggested_ids: vec!["home".into()],
        off_ids: vec![],
        ..Default::default()
    }
}

#[test]
fn nothing_resets_until_it_is_switched_on() {
    let mut connection = workspace();
    say(&mut connection, busy_evening(0), ms("2026-10-22T20:00:00Z"));
    assert_eq!(settings(&connection).unwrap(), DayStartSettings::default());
    assert!(!reset(&mut connection, ms("2026-10-23T09:00:00Z")));
    assert_eq!(context(&connection).condition_ids, vec!["campus", "laptop"]);
}

#[test]
fn the_day_resets_once_at_four_and_not_before() {
    let mut connection = workspace();
    // Switched on in the evening: that day counts as started.
    configure(
        &mut connection,
        &starting(&["home"]),
        ms("2026-10-22T19:00:00Z"),
    );
    let evening = ms("2026-10-22T20:00:00Z");
    say(&mut connection, busy_evening(evening), evening);
    assert!(!reset(&mut connection, ms("2026-10-22T21:00:00Z")));
    // 03:59 BST is still yesterday.
    assert!(!reset(&mut connection, ms("2026-10-23T02:59:00Z")));
    assert_eq!(context(&connection).condition_ids, vec!["campus", "laptop"]);

    let morning = ms("2026-10-23T03:00:00Z");
    assert!(reset(&mut connection, morning));
    let after = context(&connection);
    assert_eq!(after.condition_ids, vec!["home"]);
    assert_eq!(after.conditions_set_at_ms, Some(morning));
    assert_eq!(after.available_until_ms, None);
    assert_eq!(after.expires_at_ms, None);
    assert!(after.off_ids.is_empty());
    assert!(after.suggested_ids.is_empty());
    assert_eq!(
        settings(&connection).unwrap().last_reset_day.as_deref(),
        Some("2026-10-23")
    );

    // Said Campus at nine: the rest of the day leaves it alone.
    say(&mut connection, busy_evening(0), ms("2026-10-23T08:00:00Z"));
    assert!(!reset(&mut connection, ms("2026-10-23T12:00:00Z")));
    assert!(!reset(&mut connection, ms("2026-10-24T02:00:00Z")));
    assert_eq!(context(&connection).condition_ids, vec!["campus", "laptop"]);
}

#[test]
fn overrides_from_a_provided_condition_are_cleared() {
    let mut connection = workspace();
    connection
        .execute(
            "UPDATE task_conditions SET providesJSON = '[\"laptop\"]' WHERE id = 'home'",
            [],
        )
        .unwrap();
    configure(
        &mut connection,
        &starting(&["home"]),
        ms("2026-10-22T19:00:00Z"),
    );
    let evening = ms("2026-10-22T20:00:00Z");
    say(
        &mut connection,
        StoredFocusContext {
            condition_ids: vec!["home".into()],
            off_ids: vec!["laptop".into()],
            ..Default::default()
        },
        evening,
    );
    assert_eq!(context(&connection).off_ids, vec!["laptop"]);
    let morning = ms("2026-10-23T05:00:00Z");
    assert!(reset(&mut connection, morning));
    let after = context(&connection);
    assert_eq!(after.condition_ids, vec!["home"]);
    assert!(after.off_ids.is_empty());
    // Home again, but said today: not stale.
    assert_eq!(after.conditions_set_at_ms, Some(morning));
    assert!(!focus_context::focus_context_is_stale(
        after,
        morning + 60_000,
        LONDON.into()
    ));
}

#[test]
fn a_device_closed_for_days_resets_once_when_it_opens() {
    let mut connection = workspace();
    configure(
        &mut connection,
        &starting(&["home"]),
        ms("2026-10-18T19:00:00Z"),
    );
    say(&mut connection, busy_evening(0), ms("2026-10-18T20:00:00Z"));
    // Opened five days later in the afternoon.
    let opened = ms("2026-10-23T14:00:00Z");
    assert!(reset(&mut connection, opened));
    assert_eq!(context(&connection).condition_ids, vec!["home"]);
    assert!(!reset(&mut connection, opened + 60_000));
    assert_eq!(
        settings(&connection).unwrap().last_reset_day.as_deref(),
        Some("2026-10-23")
    );
}

#[test]
fn the_starting_set_keeps_one_place_and_only_live_conditions() {
    let mut connection = workspace();
    configure(
        &mut connection,
        &starting(&["campus", "home", "laptop", "old", "gone"]),
        ms("2026-10-22T19:00:00Z"),
    );
    assert!(reset(&mut connection, ms("2026-10-23T06:00:00Z")));
    let ids = context(&connection).condition_ids;
    // The archived place and the deleted condition drop out; of the two
    // places, the last named (sorted) wins, as saying both in turn would.
    assert_eq!(ids, vec!["home", "laptop"]);
}

#[test]
fn an_empty_starting_set_starts_the_day_with_nothing_on() {
    let mut connection = workspace();
    configure(&mut connection, &starting(&[]), ms("2026-10-22T19:00:00Z"));
    say(&mut connection, busy_evening(0), ms("2026-10-22T20:00:00Z"));
    assert!(reset(&mut connection, ms("2026-10-23T06:00:00Z")));
    let after = context(&connection);
    assert!(after.condition_ids.is_empty());
    assert_eq!(after.conditions_set_at_ms, None);
    assert_eq!(after.available_until_ms, None);
}

#[test]
fn changing_the_settings_never_resets_there_and_then() {
    let mut connection = workspace();
    configure(
        &mut connection,
        &starting(&["home"]),
        ms("2026-10-23T02:00:00Z"),
    );
    say(&mut connection, busy_evening(0), ms("2026-10-23T02:10:00Z"));
    // 03:30 BST, still yesterday under 04:00. Moving the change to 02:00
    // puts the day's start behind us, but the change counts as today's.
    let mut earlier = starting(&["home"]);
    earlier.hour = 2;
    configure(&mut connection, &earlier, ms("2026-10-23T02:30:00Z"));
    assert!(!reset(&mut connection, ms("2026-10-23T02:31:00Z")));
    assert_eq!(context(&connection).condition_ids, vec!["campus", "laptop"]);
    assert!(reset(&mut connection, ms("2026-10-24T01:00:00Z")));

    // Saving the same settings again writes nothing.
    let tx = connection.transaction().unwrap();
    assert!(!save(&tx, &earlier, ms("2026-10-24T09:00:00Z"), LONDON).unwrap());
}

#[test]
fn the_hour_is_clamped_and_an_older_one_is_adopted_only_once() {
    let mut connection = workspace();
    let tx = connection.transaction().unwrap();
    assert!(adopt_hour(&tx, 6, 1_000).unwrap());
    assert!(!adopt_hour(&tx, 9, 2_000).unwrap());
    assert_eq!(settings(&tx).unwrap().hour, 6);
    let mut late = starting(&["home"]);
    late.hour = 31;
    assert!(save(&tx, &late, 3_000, LONDON).unwrap());
    assert_eq!(settings(&tx).unwrap().hour, 23);
}

#[test]
fn the_boundary_holds_across_daylight_saving() {
    // Spring forward in London, 29 March 2026: 01:00 GMT becomes 02:00 BST.
    // At 04:00 the change is the wall clock's, an hour sooner in UTC.
    let mut connection = workspace();
    configure(
        &mut connection,
        &starting(&["home"]),
        ms("2026-03-28T19:00:00Z"),
    );
    say(&mut connection, busy_evening(0), ms("2026-03-28T20:00:00Z"));
    assert!(!reset(&mut connection, ms("2026-03-29T02:59:00Z")));
    assert!(reset(&mut connection, ms("2026-03-29T03:00:00Z")));

    // With the day changing at 01:00, which that night skips, the change is
    // at the first moment after the gap: 02:00 BST.
    let mut connection = workspace();
    let mut one = starting(&["home"]);
    one.hour = 1;
    configure(&mut connection, &one, ms("2026-03-28T19:00:00Z"));
    say(&mut connection, busy_evening(0), ms("2026-03-28T20:00:00Z"));
    assert!(!reset(&mut connection, ms("2026-03-29T00:59:00Z")));
    assert!(reset(&mut connection, ms("2026-03-29T01:00:00Z")));

    // Fall back, 25 October 2026: 01:00 to 02:00 BST happens twice. The day
    // changes at the first 01:00 and not again at the second.
    let mut connection = workspace();
    configure(&mut connection, &one, ms("2026-10-24T19:00:00Z"));
    say(&mut connection, busy_evening(0), ms("2026-10-24T20:00:00Z"));
    assert!(!reset(&mut connection, ms("2026-10-24T23:59:00Z")));
    assert!(reset(&mut connection, ms("2026-10-25T00:00:00Z")));
    say(&mut connection, busy_evening(0), ms("2026-10-25T00:30:00Z"));
    assert!(!reset(&mut connection, ms("2026-10-25T01:00:00Z")));
    assert_eq!(context(&connection).condition_ids, vec!["campus", "laptop"]);
}

/// Everything `from` has waiting, applied to `to` as a pull would.
fn push_pull(from: &mut Connection, to: &mut Connection) {
    let pending = sync::pending_changes(from, 500).unwrap();
    let rows: Vec<IncomingRow> = pending
        .changes
        .iter()
        .map(|change| IncomingRow {
            table: change.table.clone(),
            id: change.row_id.clone(),
            deleted: change.operation == "delete",
            values: change.values.clone(),
            hlc: None,
        })
        .collect();
    let tx = from.transaction().unwrap();
    if let Some(through) = pending.through_seq {
        sync::acknowledge(&tx, through).unwrap();
    }
    tx.commit().unwrap();
    let tx = to.transaction().unwrap();
    sync::apply_remote_rows(&tx, &rows, 1, None, 0).unwrap();
    tx.commit().unwrap();
}

fn paired(device: &str) -> Connection {
    let mut connection = workspace();
    let tx = connection.transaction().unwrap();
    sync::begin(&tx, device, "https://sync.example").unwrap();
    // Both start from the same rows, so the first snapshot is already sent.
    sync::enqueue_snapshot(&tx, 0).unwrap();
    if let Some(through) = sync::latest_outbox_seq(&tx).unwrap() {
        sync::acknowledge(&tx, through).unwrap();
    }
    tx.commit().unwrap();
    connection
}

#[test]
fn once_one_device_resets_the_others_do_not() {
    let mut mac = paired("mac");
    let mut phone = paired("phone");
    configure(&mut mac, &starting(&["home"]), ms("2026-10-22T19:00:00Z"));
    say(&mut mac, busy_evening(0), ms("2026-10-22T20:00:00Z"));
    push_pull(&mut mac, &mut phone);
    assert!(settings(&phone).unwrap().resets);
    assert_eq!(context(&phone).condition_ids, vec!["campus", "laptop"]);

    // The Mac, left on overnight, resets at four; the phone pulls that.
    assert!(reset(&mut mac, ms("2026-10-23T03:00:00Z")));
    push_pull(&mut mac, &mut phone);
    assert_eq!(
        settings(&phone).unwrap().last_reset_day.as_deref(),
        Some("2026-10-23")
    );
    // Opened at seven, after you said Campus at six on the Mac: it stays.
    say(&mut mac, busy_evening(0), ms("2026-10-23T05:00:00Z"));
    push_pull(&mut mac, &mut phone);
    assert!(!reset(&mut phone, ms("2026-10-23T06:00:00Z")));
    assert_eq!(context(&phone).condition_ids, vec!["campus", "laptop"]);
}

#[test]
fn a_context_pulled_from_today_wins_over_a_late_reset() {
    // An older Mac, which does not reset, says Campus at six; the phone
    // had not reset yet and pulls it before its first look of the day.
    let mut mac = paired("mac");
    let mut phone = paired("phone");
    configure(&mut phone, &starting(&["home"]), ms("2026-10-22T19:00:00Z"));
    say(&mut mac, busy_evening(0), ms("2026-10-23T05:00:00Z"));
    push_pull(&mut mac, &mut phone);
    assert!(!reset(&mut phone, ms("2026-10-23T06:00:00Z")));
    assert_eq!(context(&phone).condition_ids, vec!["campus", "laptop"]);
    // The day is counted all the same: no reset later on either.
    assert!(!reset(&mut phone, ms("2026-10-23T20:00:00Z")));
}

#[test]
fn two_devices_resetting_at_once_agree() {
    let mut mac = paired("mac");
    let mut phone = paired("phone");
    configure(&mut mac, &starting(&["home"]), ms("2026-10-22T19:00:00Z"));
    say(&mut mac, busy_evening(0), ms("2026-10-22T20:00:00Z"));
    push_pull(&mut mac, &mut phone);
    // Both evaluate before either hears from the other.
    assert!(reset(&mut mac, ms("2026-10-23T03:00:00Z")));
    assert!(reset(&mut phone, ms("2026-10-23T03:00:30Z")));
    push_pull(&mut phone, &mut mac);
    assert_eq!(context(&mac).condition_ids, context(&phone).condition_ids);
    assert_eq!(context(&mac).condition_ids, vec!["home"]);
    assert!(!reset(&mut mac, ms("2026-10-23T04:00:00Z")));
}

#[test]
fn day_keys_follow_the_hour_and_zone() {
    assert_eq!(
        day_start_day_key(4, ms("2026-10-23T02:59:00Z"), LONDON.into()),
        "2026-10-22"
    );
    assert_eq!(
        day_start_day_key(4, ms("2026-10-23T03:00:00Z"), LONDON.into()),
        "2026-10-23"
    );
    assert_eq!(
        day_start_day_key(0, ms("2026-10-23T03:00:00Z"), "America/New_York".into()),
        "2026-10-22"
    );
}
