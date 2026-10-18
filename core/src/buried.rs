//! Buried tasks: an open task whose start is still to come.
//!
//! A buried task is not hidden. Among its siblings it sorts after every task
//! that is not buried, blocked ones included, so a parent's children read as
//! three sections: the open work, then what is blocked ([`crate::dependencies`]),
//! then what is buried. Each section keeps its own order, and a buried task
//! that is also blocked is in the buried one. Its subtasks go with it.
//!
//! The rule every client draws from lives here, so the Mac, the phones and the
//! CLI cannot disagree about it:
//!
//! - **Order.** [`section_order`] in the reads that hand back a list's rows,
//!   in place of the blocked term. It reads SQLite's own clock, so a read made
//!   after the start has arrived puts the task back in its place without
//!   anything being written. Its `sortOrder` is never changed by burying,
//!   which is what lets it come back where it was.
//! - **Moves.** A reorder steps a task past the siblings drawn in its own
//!   section ([`sibling_section`]), and an indent goes under the sibling drawn
//!   above it, as for blocked tasks.
//! - **Next up and Today** leave a future start alone (`focus`), unchanged.

use std::collections::HashSet;

use rusqlite::Connection;

use crate::CoreError;
use crate::records::all;
use crate::time::stored;

/// An `ORDER BY` term, over a query whose task table is named `tasks`, that is
/// 1 for an open task whose start is still to come and 0 otherwise.
/// `julianday` reads the stored start in either of the forms it is written
/// in, with a space or a `T`. It reads SQLite's own clock.
const BURIED: &str = "(tasks.status = 'open' AND EXISTS (\
     SELECT 1 FROM task_metadata buried_meta \
     WHERE buried_meta.taskId = tasks.id AND buried_meta.startAt IS NOT NULL \
     AND julianday(buried_meta.startAt) > julianday('now')))";

/// The `ORDER BY` term that puts siblings in their sections: 0 for open
/// work, 1 for blocked, 2 for buried, blocked or not. Sorting on it ahead of
/// `sortOrder` keeps each section in its own order. `blocked` is
/// `dependencies::blocked_last`'s term.
pub(crate) fn section_order(blocked: &str) -> String {
    format!("(CASE WHEN {BURIED} THEN 2 WHEN {blocked} THEN 1 ELSE 0 END)")
}

/// The open tasks buried at `now_ms`.
pub fn buried_task_ids(connection: &Connection, now_ms: i64) -> Result<Vec<String>, CoreError> {
    all(
        connection,
        "SELECT m.taskId FROM task_metadata m
         JOIN tasks ON tasks.id = m.taskId
         WHERE tasks.status = 'open' AND m.startAt IS NOT NULL
           AND julianday(m.startAt) > julianday(?1)
         ORDER BY m.taskId",
        [stored(now_ms)],
        |row| row.get(0),
    )
}

/// The section a sibling is drawn in, as [`section_order`] sorts it: 0 for
/// open work, 1 blocked, 2 buried (blocked or not).
pub(crate) fn sibling_section(id: &str, blocked: &HashSet<String>, buried: &HashSet<String>) -> u8 {
    if buried.contains(id) {
        2
    } else if blocked.contains(id) {
        1
    } else {
        0
    }
}

#[cfg(test)]
mod tests;
