use rusqlite::Connection;

use super::*;
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
             VALUES ('w', 'Mine', '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000');",
        )
        .unwrap();
    connection
}

fn context(ids: &[&str]) -> StoredFocusContext {
    StoredFocusContext {
        condition_ids: ids.iter().map(|id| id.to_string()).collect(),
        ..Default::default()
    }
}

#[test]
fn a_context_is_saved_stamped_and_read_back() {
    let mut connection = workspace();
    assert_eq!(load(&connection, "w").unwrap(), None);
    let tx = connection.transaction().unwrap();
    assert!(save(&tx, "w", &context(&["campus", "mat"]), 1_000).unwrap());
    // The same conditions again: nothing to write, and the stamp stays.
    assert!(!save(&tx, "w", &context(&["mat", "campus"]), 9_000).unwrap());
    let mut longer = context(&["campus", "mat"]);
    longer.available_until_ms = Some(60_000);
    longer.mode = "finish".into();
    assert!(save(&tx, "w", &longer, 9_000).unwrap());
    tx.commit().unwrap();
    let stored = load(&connection, "w").unwrap().unwrap();
    assert_eq!(stored.condition_ids, vec!["campus", "mat"]);
    assert_eq!(stored.conditions_set_at_ms, Some(1_000));
    assert_eq!(stored.available_until_ms, Some(60_000));
    assert_eq!(stored.mode, "finish");
    let tx = connection.transaction().unwrap();
    assert!(save(&tx, "w", &context(&["home"]), 20_000).unwrap());
    assert_eq!(
        load(&tx, "w").unwrap().unwrap().conditions_set_at_ms,
        Some(20_000)
    );
    assert!(save(&tx, "w", &context(&[]), 30_000).unwrap());
    assert_eq!(load(&tx, "w").unwrap().unwrap().conditions_set_at_ms, None);
}

#[test]
fn an_expired_context_is_set_aside_and_offered_back() {
    let mut on = context(&["campus"]);
    on.expires_at_ms = Some(100);
    on.conditions_set_at_ms = Some(10);
    on.off_ids = vec!["quiet".into()];
    assert_eq!(focus_context_in_force(on.clone(), 99), on);
    let lapsed = focus_context_in_force(on, 100);
    assert!(lapsed.condition_ids.is_empty());
    assert!(lapsed.off_ids.is_empty(), "nothing provides it any more");
    assert_eq!(lapsed.suggested_ids, vec!["campus"]);
    assert_eq!(lapsed.expires_at_ms, None);
    assert_eq!(lapsed.conditions_set_at_ms, None);
}

#[test]
fn a_context_from_an_earlier_day_is_stale() {
    // 2024-01-01 23:00 and 2024-01-02 01:00 in London.
    let evening = 1_704_150_000_000;
    let night = evening + 2 * 3_600_000;
    let mut on = context(&["campus"]);
    on.conditions_set_at_ms = Some(evening);
    assert!(!focus_context_is_stale(
        on.clone(),
        evening + 1,
        "Europe/London".into()
    ));
    assert!(focus_context_is_stale(
        on.clone(),
        night,
        "Europe/London".into()
    ));
    // Still the same day in New York.
    assert!(!focus_context_is_stale(
        on.clone(),
        night,
        "America/New_York".into()
    ));
    assert!(!focus_context_is_stale(
        context(&[]),
        night,
        "Europe/London".into()
    ));
}

#[test]
fn turning_conditions_on_and_off_keeps_one_place() {
    let places = vec!["home".to_string(), "campus".to_string()];
    assert_eq!(
        focus_context_changed(
            vec!["home".into(), "mat".into()],
            vec!["campus".into()],
            vec![],
            places.clone()
        ),
        vec!["campus", "mat"]
    );
    assert_eq!(
        focus_context_changed(
            vec!["home".into(), "mat".into()],
            vec!["quiet".into()],
            vec!["mat".into()],
            places
        ),
        vec!["home", "quiet"]
    );
}
