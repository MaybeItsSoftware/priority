//! Task rows as one buffer of bytes, for the reads that hand back thousands
//! of them.
//!
//! UniFFI lifts a record field by field, and its Swift side pays for every
//! field on its own: each integer is a bounds-checked copy out of `Data`,
//! each string a fresh `[UInt8]` before it becomes a `String`. A `TaskRow`
//! has seventeen fields, nine of them strings or optional strings, which is
//! what made a row cost about 6 µs to cross. Packed, the whole read crosses
//! as one `Vec<u8>` and the client reads it in a single pass over raw
//! memory: `WorkspaceStore.unpackedTasks` in Swift.
//!
//! The layout, every integer little-endian:
//!
//! ```text
//! u32 row count
//! per row:
//!   u16 flags      which optional fields are present (FLAG_*), and is_promoted
//!   i64 sort_order, created_at_ms, updated_at_ms
//!   i64 due_at_ms, estimate_seconds, archived_at_ms, completed_at_ms
//!                  each only when its flag is set
//!   str id, list_id, title, notes, status
//!   str parent_task_id, source_system, source_id, item_kind
//!                  each only when its flag is set
//! where str is a u32 byte length followed by that many bytes of UTF-8
//! ```
//!
//! A field added to `TaskRow` is added here and in the decoders, and the
//! round-trip tests on both sides fail until it is.

use crate::records::TaskRow;

pub const FLAG_PARENT: u16 = 1 << 0;
pub const FLAG_DUE: u16 = 1 << 1;
pub const FLAG_ESTIMATE: u16 = 1 << 2;
pub const FLAG_SOURCE_SYSTEM: u16 = 1 << 3;
pub const FLAG_SOURCE_ID: u16 = 1 << 4;
pub const FLAG_ITEM_KIND: u16 = 1 << 5;
/// `is_promoted` is present; `FLAG_PROMOTED_VALUE` holds it.
pub const FLAG_PROMOTED: u16 = 1 << 6;
pub const FLAG_PROMOTED_VALUE: u16 = 1 << 7;
pub const FLAG_ARCHIVED: u16 = 1 << 8;
pub const FLAG_COMPLETED: u16 = 1 << 9;

/// `rows`, packed.
pub fn pack_task_rows<'a>(rows: impl ExactSizeIterator<Item = &'a TaskRow>) -> Vec<u8> {
    let count = rows.len();
    // A guess at a row's size, so the buffer rarely grows.
    let mut out = Vec::with_capacity(4 + count * 160);
    out.extend_from_slice(&(count as u32).to_le_bytes());
    for row in rows {
        pack_task_row(row, &mut out);
    }
    out
}

fn pack_task_row(row: &TaskRow, out: &mut Vec<u8>) {
    let mut flags = 0u16;
    let mut set = |present: bool, flag: u16| {
        if present {
            flags |= flag;
        }
    };
    set(row.parent_task_id.is_some(), FLAG_PARENT);
    set(row.due_at_ms.is_some(), FLAG_DUE);
    set(row.estimate_seconds.is_some(), FLAG_ESTIMATE);
    set(row.source_system.is_some(), FLAG_SOURCE_SYSTEM);
    set(row.source_id.is_some(), FLAG_SOURCE_ID);
    set(row.item_kind.is_some(), FLAG_ITEM_KIND);
    set(row.is_promoted.is_some(), FLAG_PROMOTED);
    set(row.is_promoted == Some(true), FLAG_PROMOTED_VALUE);
    set(row.archived_at_ms.is_some(), FLAG_ARCHIVED);
    set(row.completed_at_ms.is_some(), FLAG_COMPLETED);
    out.extend_from_slice(&flags.to_le_bytes());

    for value in [row.sort_order, row.created_at_ms, row.updated_at_ms]
        .into_iter()
        .chain(row.due_at_ms)
        .chain(row.estimate_seconds)
        .chain(row.archived_at_ms)
        .chain(row.completed_at_ms)
    {
        out.extend_from_slice(&value.to_le_bytes());
    }

    for text in [&row.id, &row.list_id, &row.title, &row.notes, &row.status]
        .into_iter()
        .chain(&row.parent_task_id)
        .chain(&row.source_system)
        .chain(&row.source_id)
        .chain(&row.item_kind)
    {
        out.extend_from_slice(&(text.len() as u32).to_le_bytes());
        out.extend_from_slice(text.as_bytes());
    }
}

/// The rows `pack_task_rows` packed, or `None` if `bytes` is not such a
/// buffer. The reference decoder: the clients have their own, and the tests
/// hold all of them to this.
pub fn unpack_task_rows(bytes: &[u8]) -> Option<Vec<TaskRow>> {
    let mut reader = Reader { bytes, at: 0 };
    let count = reader.u32()? as usize;
    let mut rows = Vec::with_capacity(count.min(bytes.len()));
    for _ in 0..count {
        let flags = u16::from_le_bytes(reader.take(2)?.try_into().ok()?);
        let has = |flag: u16| flags & flag != 0;
        let sort_order = reader.i64()?;
        let created_at_ms = reader.i64()?;
        let updated_at_ms = reader.i64()?;
        let due_at_ms = reader.i64_if(has(FLAG_DUE))?;
        let estimate_seconds = reader.i64_if(has(FLAG_ESTIMATE))?;
        let archived_at_ms = reader.i64_if(has(FLAG_ARCHIVED))?;
        let completed_at_ms = reader.i64_if(has(FLAG_COMPLETED))?;
        let id = reader.string()?;
        let list_id = reader.string()?;
        let title = reader.string()?;
        let notes = reader.string()?;
        let status = reader.string()?;
        rows.push(TaskRow {
            id,
            list_id,
            parent_task_id: reader.string_if(has(FLAG_PARENT))?,
            title,
            notes,
            status,
            sort_order,
            due_at_ms,
            estimate_seconds,
            source_system: reader.string_if(has(FLAG_SOURCE_SYSTEM))?,
            source_id: reader.string_if(has(FLAG_SOURCE_ID))?,
            item_kind: reader.string_if(has(FLAG_ITEM_KIND))?,
            is_promoted: has(FLAG_PROMOTED).then_some(has(FLAG_PROMOTED_VALUE)),
            archived_at_ms,
            completed_at_ms,
            created_at_ms,
            updated_at_ms,
        });
    }
    (reader.at == bytes.len()).then_some(rows)
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Option<&'a [u8]> {
        let slice = self.bytes.get(self.at..self.at.checked_add(count)?)?;
        self.at += count;
        Some(slice)
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }

    fn i64(&mut self) -> Option<i64> {
        Some(i64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }

    /// `Some(None)` when absent, `None` when the buffer ran out.
    fn i64_if(&mut self, present: bool) -> Option<Option<i64>> {
        if present {
            self.i64().map(Some)
        } else {
            Some(None)
        }
    }

    fn string(&mut self) -> Option<String> {
        let count = self.u32()? as usize;
        String::from_utf8(self.take(count)?.to_vec()).ok()
    }

    fn string_if(&mut self, present: bool) -> Option<Option<String>> {
        if present {
            self.string().map(Some)
        } else {
            Some(None)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str) -> TaskRow {
        TaskRow {
            id: id.to_string(),
            list_id: "list".to_string(),
            parent_task_id: None,
            title: String::new(),
            notes: String::new(),
            status: "open".to_string(),
            sort_order: 0,
            due_at_ms: None,
            estimate_seconds: None,
            source_system: None,
            source_id: None,
            item_kind: None,
            is_promoted: None,
            archived_at_ms: None,
            completed_at_ms: None,
            created_at_ms: 0,
            updated_at_ms: 0,
        }
    }

    #[test]
    fn empty_round_trips() {
        let bytes = pack_task_rows([].iter());
        assert_eq!(bytes, 0u32.to_le_bytes());
        assert_eq!(unpack_task_rows(&bytes), Some(vec![]));
    }

    #[test]
    fn every_field_round_trips_present_and_absent() {
        let bare = row("bare");
        let full = TaskRow {
            id: "full".to_string(),
            list_id: "list ✓".to_string(),
            parent_task_id: Some("bare".to_string()),
            title: "Café 🍰 — 日本語 \u{FEFF}".to_string(),
            notes: "line one\nline two".to_string(),
            status: "completed".to_string(),
            sort_order: -3,
            due_at_ms: Some(i64::MIN),
            estimate_seconds: Some(1_800),
            source_system: Some("checkvist".to_string()),
            source_id: Some(String::new()),
            item_kind: Some("list".to_string()),
            is_promoted: Some(false),
            archived_at_ms: Some(1),
            completed_at_ms: Some(i64::MAX),
            created_at_ms: 1_704_067_200_000,
            updated_at_ms: -1,
        };
        let promoted = TaskRow {
            is_promoted: Some(true),
            ..row("promoted")
        };
        let rows = vec![bare, full, promoted];
        assert_eq!(unpack_task_rows(&pack_task_rows(rows.iter())), Some(rows));
    }

    #[test]
    fn a_truncated_buffer_is_refused() {
        let bytes = pack_task_rows([row("a"), row("b")].iter());
        for end in 0..bytes.len() {
            assert_eq!(unpack_task_rows(&bytes[..end]), None, "cut at {end}");
        }
    }
}
