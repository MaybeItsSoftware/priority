//! The merge rule from docs/sync.md ("`POST /v1/push`"), with no database.
//!
//! Every device can edit offline, so two pushes can disagree about the same
//! row. The server settles that per column, by hybrid logical clock: the newer
//! stamp wins, so two devices editing different fields of one task both keep
//! their edit, and the same field converges on whichever edit was made later.
//! Deletes are a row-level stamp of their own. Keeping the rule here, pure,
//! means it is tested exhaustively without Postgres, and `push.rs` is left
//! with nothing to decide, only rows to read and write.

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use uuid::Uuid;

/// A row as the server stores it, minus its position in the sequence.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct StoredRow {
    /// Every column ever pushed for the row, with its latest winning value.
    pub data: Map<String, Value>,
    /// The HLC of the push that wrote each column of `data`.
    pub col_hlc: BTreeMap<String, String>,
    pub deleted: bool,
    pub deleted_hlc: Option<String>,
    pub last_device_id: Option<Uuid>,
}

/// What a pushed change asks for.
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    /// Set these columns. Only the columns the device changed are sent, which
    /// is what lets edits to different columns both survive.
    Upsert(Map<String, Value>),
    Delete,
}

/// One entry of a push's `changes`, already validated.
#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    pub table: String,
    pub id: String,
    pub op: Op,
    pub hlc: String,
}

/// What a change did to the row.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The change lost everywhere, or was already applied. Nothing is written,
    /// so the row keeps its `seq` and no device is sent it again. This is what
    /// makes re-pushing a batch after a lost response safe.
    Unchanged,
    /// The row to store. The caller gives it a fresh `seq`.
    Changed(StoredRow),
}

/// Resolves `change` against the stored row, if there is one, for `device`.
///
/// `lastDeviceId` on a changed row is simply the pusher, and is diagnostic
/// only. It once also kept a row out of its pusher's own feed, which lost
/// data: a row a device last wrote can still hold another device's earlier
/// edit to a column it never received. So nothing reads it any more.
pub fn merge(stored: Option<&StoredRow>, change: &Change, device: Uuid) -> Outcome {
    match &change.op {
        Op::Upsert(values) => upsert(stored, values, &change.hlc, device),
        Op::Delete => delete(stored, &change.hlc, device),
    }
}

fn upsert(
    stored: Option<&StoredRow>,
    values: &Map<String, Value>,
    hlc: &str,
    device: Uuid,
) -> Outcome {
    let mut row = stored.cloned().unwrap_or_default();
    let mut changed = stored.is_none();

    if row.deleted {
        // A delete is only undone by an edit made after it: undoing a delete
        // on one device re-inserts the row with a fresh stamp. An edit made
        // before the delete, arriving late, must not bring the row back.
        match row.deleted_hlc.as_deref() {
            Some(deleted_hlc) if hlc <= deleted_hlc => return Outcome::Unchanged,
            _ => {}
        }
        row.deleted = false;
        changed = true;
    }

    for (column, value) in values {
        let wins = row
            .col_hlc
            .get(column)
            .is_none_or(|existing| hlc > existing.as_str());
        if wins {
            row.data.insert(column.clone(), value.clone());
            row.col_hlc.insert(column.clone(), hlc.to_owned());
            changed = true;
        }
    }

    if !changed {
        return Outcome::Unchanged;
    }
    row.last_device_id = Some(device);
    Outcome::Changed(row)
}

fn delete(stored: Option<&StoredRow>, hlc: &str, device: Uuid) -> Outcome {
    let Some(existing) = stored else {
        // A delete for a row the server never saw still leaves a tombstone.
        // Otherwise an older insert of the same row, pushed later by a device
        // that was offline, would create it as though it had never gone.
        return Outcome::Changed(StoredRow {
            deleted: true,
            deleted_hlc: Some(hlc.to_owned()),
            last_device_id: Some(device),
            ..StoredRow::default()
        });
    };

    // An edit stamped after the delete means someone was still working on the
    // row; the edit wins and the delete is dropped.
    if existing
        .col_hlc
        .values()
        .any(|column| hlc <= column.as_str())
    {
        return Outcome::Unchanged;
    }
    // A second delete only matters if it is newer: it raises the bar a later
    // resurrecting edit has to clear. Re-pushing the same one changes nothing.
    if existing.deleted
        && existing
            .deleted_hlc
            .as_deref()
            .is_some_and(|deleted_hlc| hlc <= deleted_hlc)
    {
        return Outcome::Unchanged;
    }

    let mut row = existing.clone();
    row.deleted = true;
    row.deleted_hlc = Some(hlc.to_owned());
    row.last_device_id = Some(device);
    Outcome::Changed(row)
}

/// The stamp the changes feed reports for a row: the newest thing that
/// happened to it, column write or delete. A device advances its clock past
/// it on receipt.
pub fn row_hlc(col_hlc: &BTreeMap<String, String>, deleted_hlc: Option<&str>) -> Option<String> {
    col_hlc
        .values()
        .map(String::as_str)
        .chain(deleted_hlc)
        .max()
        .map(str::to_owned)
}

/// Whether `hlc` has the `"<ms:013d>-<counter:04d>-<deviceId>"` shape.
///
/// Every comparison above is plain string order, which is only the clock's
/// order when the numeric parts are fixed width. A malformed stamp would not
/// fail; it would silently win or lose against everything, so it is refused
/// at the door instead.
pub fn is_valid_hlc(hlc: &str) -> bool {
    let bytes = hlc.as_bytes();
    bytes.len() > 19
        && bytes[..13].iter().all(u8::is_ascii_digit)
        && bytes[13] == b'-'
        && bytes[14..18].iter().all(u8::is_ascii_digit)
        && bytes[18] == b'-'
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hlc(ms: u64, counter: u32, device: &str) -> String {
        format!("{ms:013}-{counter:04}-{device}")
    }

    fn values(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            _ => panic!("not an object"),
        }
    }

    fn upsert_change(stamp: &str, columns: Value) -> Change {
        Change {
            table: "tasks".into(),
            id: "T1".into(),
            op: Op::Upsert(values(columns)),
            hlc: stamp.into(),
        }
    }

    fn delete_change(stamp: &str) -> Change {
        Change {
            table: "tasks".into(),
            id: "T1".into(),
            op: Op::Delete,
            hlc: stamp.into(),
        }
    }

    fn changed(outcome: Outcome) -> StoredRow {
        match outcome {
            Outcome::Changed(row) => row,
            Outcome::Unchanged => panic!("expected a change"),
        }
    }

    const A: Uuid = Uuid::from_u128(0xA);
    const B: Uuid = Uuid::from_u128(0xB);

    fn seeded() -> StoredRow {
        changed(merge(
            None,
            &upsert_change(
                &hlc(1000, 0, "a"),
                json!({"title": "Buy milk", "notes": ""}),
            ),
            A,
        ))
    }

    #[test]
    fn a_new_row_takes_every_column_and_the_pusher() {
        let row = seeded();
        assert_eq!(row.data, values(json!({"title": "Buy milk", "notes": ""})));
        assert_eq!(row.col_hlc.get("title"), Some(&hlc(1000, 0, "a")));
        assert_eq!(row.last_device_id, Some(A));
        assert!(!row.deleted);
    }

    #[test]
    fn concurrent_edits_to_different_fields_both_survive() {
        let base = seeded();
        let after_a = changed(merge(
            Some(&base),
            &upsert_change(&hlc(2000, 0, "a"), json!({"title": "Buy oat milk"})),
            A,
        ));
        // B edited from the same base, at an earlier wall time, another field.
        let after_b = changed(merge(
            Some(&after_a),
            &upsert_change(&hlc(1500, 0, "b"), json!({"notes": "the big one"})),
            B,
        ));
        assert_eq!(
            after_b.data,
            values(json!({"title": "Buy oat milk", "notes": "the big one"}))
        );
        assert_eq!(after_b.last_device_id, Some(B));
    }

    #[test]
    fn an_older_hlc_loses_the_column() {
        let base = changed(merge(
            Some(&seeded()),
            &upsert_change(&hlc(3000, 0, "a"), json!({"title": "newer"})),
            A,
        ));
        let outcome = merge(
            Some(&base),
            &upsert_change(&hlc(2000, 0, "b"), json!({"title": "older"})),
            B,
        );
        assert_eq!(outcome, Outcome::Unchanged);
    }

    #[test]
    fn the_counter_breaks_ties_within_a_millisecond() {
        let base = seeded();
        let row = changed(merge(
            Some(&base),
            &upsert_change(&hlc(1000, 1, "b"), json!({"title": "second"})),
            B,
        ));
        assert_eq!(row.data["title"], json!("second"));
    }

    #[test]
    fn a_partly_losing_push_keeps_the_winning_columns_and_records_the_pusher() {
        let base = changed(merge(
            Some(&seeded()),
            &upsert_change(&hlc(3000, 0, "a"), json!({"title": "A's title"})),
            A,
        ));
        let row = changed(merge(
            Some(&base),
            &upsert_change(
                &hlc(2000, 0, "b"),
                json!({"title": "B's title", "notes": "B's notes"}),
            ),
            B,
        ));
        assert_eq!(row.data["title"], json!("A's title"));
        assert_eq!(row.data["notes"], json!("B's notes"));
        assert_eq!(row.last_device_id, Some(B));
    }

    #[test]
    fn a_delete_beats_older_edits() {
        let deleted = changed(merge(
            Some(&seeded()),
            &delete_change(&hlc(2000, 0, "b")),
            B,
        ));
        assert!(deleted.deleted);
        assert_eq!(deleted.deleted_hlc, Some(hlc(2000, 0, "b")));
        assert_eq!(deleted.last_device_id, Some(B));

        // An edit made before the delete, arriving afterwards, stays dead.
        let late_edit = merge(
            Some(&deleted),
            &upsert_change(&hlc(1500, 0, "a"), json!({"title": "too late"})),
            A,
        );
        assert_eq!(late_edit, Outcome::Unchanged);
    }

    #[test]
    fn a_delete_loses_to_a_newer_edit() {
        let base = changed(merge(
            Some(&seeded()),
            &upsert_change(&hlc(3000, 0, "a"), json!({"title": "still here"})),
            A,
        ));
        let outcome = merge(Some(&base), &delete_change(&hlc(2000, 0, "b")), B);
        assert_eq!(outcome, Outcome::Unchanged);
    }

    #[test]
    fn a_newer_edit_resurrects_a_deleted_row_over_its_old_data() {
        let deleted = changed(merge(
            Some(&seeded()),
            &delete_change(&hlc(2000, 0, "b")),
            B,
        ));
        let row = changed(merge(
            Some(&deleted),
            &upsert_change(&hlc(3000, 0, "a"), json!({"title": "back"})),
            A,
        ));
        assert!(!row.deleted);
        assert_eq!(row.data, values(json!({"title": "back", "notes": ""})));
        assert_eq!(row.last_device_id, Some(A));
    }

    #[test]
    fn re_pushing_the_same_change_changes_nothing() {
        let change = upsert_change(&hlc(2000, 0, "a"), json!({"title": "once"}));
        let row = changed(merge(Some(&seeded()), &change, A));
        assert_eq!(merge(Some(&row), &change, A), Outcome::Unchanged);

        let delete = delete_change(&hlc(3000, 0, "a"));
        let deleted = changed(merge(Some(&row), &delete, A));
        assert_eq!(merge(Some(&deleted), &delete, A), Outcome::Unchanged);
    }

    #[test]
    fn a_delete_of_an_unknown_row_leaves_a_tombstone() {
        let tombstone = changed(merge(None, &delete_change(&hlc(2000, 0, "b")), B));
        assert!(tombstone.deleted);
        let late_insert = merge(
            Some(&tombstone),
            &upsert_change(&hlc(1000, 0, "a"), json!({"title": "x"})),
            A,
        );
        assert_eq!(late_insert, Outcome::Unchanged);
    }

    #[test]
    fn row_hlc_is_the_newest_column_or_delete() {
        let row = changed(merge(
            Some(&seeded()),
            &delete_change(&hlc(2000, 0, "b")),
            B,
        ));
        assert_eq!(
            row_hlc(&row.col_hlc, row.deleted_hlc.as_deref()),
            Some(hlc(2000, 0, "b"))
        );
        assert_eq!(row_hlc(&seeded().col_hlc, None), Some(hlc(1000, 0, "a")));
    }

    #[test]
    fn hlc_shape_is_checked() {
        assert!(is_valid_hlc(&hlc(1, 0, "D3V1CE")));
        assert!(!is_valid_hlc("1-0-device"));
        assert!(!is_valid_hlc("0000000001000-0000-"));
        assert!(!is_valid_hlc("000000000100x-0000-a"));
    }
}
