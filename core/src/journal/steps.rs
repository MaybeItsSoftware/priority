//! Taking back one particular step, rather than the latest.
//!
//! The agent panel shows each change the assistant made as a card with an
//! Undo button, and by the time the user presses it other steps may stand on
//! top of it. Undo by menu replays the newest step; this replays the one the
//! card names — when doing so leaves every later step exactly as it left its
//! rows. Whether it does is not guessed from which rows the steps share
//! (a task deleted by one step can cascade to a subtask another added):
//! the step is replayed inside a savepoint and every row a later standing
//! step touched is compared with that step's after-image. When one no longer
//! matches, the step is taken back together with the later steps that built
//! on its rows (an edit to the task it added), when that is enough, and
//! otherwise with every later step, newest first, as undo by menu would;
//! [`step_undo_plan`] says which, so the button can say so before it is
//! pressed.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};

use super::{UndoStep, replay};
use crate::CoreError;
use crate::schema::triggers::JOURNALLED_TABLES;
use crate::workspace::CoreWorkspace;

/// What pressing Undo on one step would do.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct StepUndoPlan {
    /// The step is still in the journal. A step trimmed off its end, or a
    /// redo dropped by a newer change, is gone for good.
    pub available: bool,
    /// It has been taken back already, so the button is Redo.
    pub is_undone: bool,
    /// Later steps that have to be taken back with it, newest first. Empty
    /// when it can be taken back alone.
    pub later_steps: Vec<UndoStep>,
    /// For an undone step: Redo would put it back without disturbing a
    /// later step.
    pub can_redo: bool,
}

struct Group {
    id: String,
    label: Option<String>,
    count: u32,
}

fn group(connection: &Connection, id: &str) -> Result<Option<(bool, i64)>, CoreError> {
    Ok(connection
        .query_row(
            "SELECT MAX(undone), MAX(id) FROM change_log WHERE groupId = ?1 HAVING COUNT(*) > 0",
            [id],
            |row| Ok((row.get::<_, Option<bool>>(0)?.unwrap_or(false), row.get(1)?)),
        )
        .optional()?)
}

/// The steps still standing after `after`, oldest first.
fn later_standing(connection: &Connection, after: i64) -> Result<Vec<Group>, CoreError> {
    let mut statement = connection.prepare(
        "SELECT groupId, MAX(label), COUNT(*), MAX(id) AS lastId FROM change_log
         WHERE undone = 0 AND groupId IS NOT NULL
         GROUP BY groupId HAVING MAX(id) > ?1 ORDER BY lastId ASC",
    )?;
    let groups = statement
        .query_map([after], |row| {
            Ok(Group {
                id: row.get(0)?,
                label: row.get(1)?,
                count: row.get(2)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(groups)
}

/// Whether every row the later steps touched is as the last of them left it.
fn later_steps_hold(transaction: &Connection, after: i64) -> Result<bool, CoreError> {
    let mut statement = transaction.prepare(
        "SELECT c.tableName, c.rowId, c.afterJSON FROM change_log c
         WHERE c.undone = 0 AND c.id > ?1
           AND c.id = (SELECT MAX(d.id) FROM change_log d
                       WHERE d.undone = 0 AND d.tableName = c.tableName AND d.rowId = c.rowId)",
    )?;
    let expected: Vec<(String, String, Option<String>)> = statement
        .query_map([after], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
        .collect::<Result<_, _>>()?;
    for (table, key, after_json) in expected {
        let Some(&(table, key_column)) = JOURNALLED_TABLES.iter().find(|(t, _)| *t == table) else {
            continue;
        };
        let columns = super::columns(transaction, table)?;
        let pairs: Vec<String> = columns.iter().map(|c| format!("'{c}', \"{c}\"")).collect();
        let now: Option<String> = transaction
            .query_row(
                &format!(
                    "SELECT json_object({}) FROM {table} WHERE \"{key_column}\" = ?1",
                    pairs.join(", ")
                ),
                [&key],
                |row| row.get(0),
            )
            .optional()?;
        if now != after_json {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Takes back `with` (newest first) and then replays `id` backwards — or
/// just replays `id` forwards to redo — inside a savepoint, and says whether
/// every step still standing after that holds. Rolled back either way.
fn replays_cleanly(
    transaction: &mut Transaction,
    with: &[String],
    id: &str,
    last_id: i64,
    reversed: bool,
) -> Result<bool, CoreError> {
    let mut savepoint = transaction.savepoint()?;
    let replayed = (|| -> Result<(), CoreError> {
        for later in with {
            replay(&savepoint, later, true)?;
            mark(&savepoint, later, true)?;
        }
        replay(&savepoint, id, reversed)
    })();
    let clean = match replayed {
        Ok(()) => later_steps_hold(&savepoint, last_id)?,
        // A constraint the replay ran into is a later step in the way.
        Err(CoreError::Database { .. }) => false,
        Err(error) => return Err(error),
    };
    savepoint.rollback()?;
    Ok(clean)
}

/// The rows a step touched.
fn rows(connection: &Connection, id: &str) -> Result<HashSet<(String, String)>, CoreError> {
    let mut statement =
        connection.prepare("SELECT tableName, rowId FROM change_log WHERE groupId = ?1")?;
    let rows = statement
        .query_map([id], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn plan_in(transaction: &mut Transaction, id: &str) -> Result<StepUndoPlan, CoreError> {
    let Some((is_undone, last_id)) = group(transaction, id)? else {
        return Ok(StepUndoPlan::default());
    };
    if is_undone {
        let can_redo = replays_cleanly(transaction, &[], id, last_id, false)?;
        return Ok(StepUndoPlan {
            available: true,
            is_undone,
            later_steps: Vec::new(),
            can_redo,
        });
    }
    let as_step = |group: &Group| UndoStep {
        id: group.id.clone(),
        label: group.label.clone().unwrap_or_else(|| "Change".to_string()),
        is_undone: false,
        change_count: group.count,
    };
    let later_steps = if replays_cleanly(transaction, &[], id, last_id, true)? {
        Vec::new()
    } else {
        // The later steps that touched its rows, or rows those touched: an
        // edit to the task it added. Taken back with it when that is enough,
        // and otherwise everything later, as the menu would.
        let later = later_standing(transaction, last_id)?;
        let mut touched = rows(transaction, id)?;
        let mut built_on = Vec::new();
        for group in &later {
            let theirs = rows(transaction, &group.id)?;
            if !theirs.is_disjoint(&touched) {
                touched.extend(theirs);
                built_on.push(group);
            }
        }
        let newest_first: Vec<String> = built_on.iter().rev().map(|g| g.id.clone()).collect();
        if !built_on.is_empty()
            && built_on.len() < later.len()
            && replays_cleanly(transaction, &newest_first, id, last_id, true)?
        {
            built_on.iter().rev().map(|group| as_step(group)).collect()
        } else {
            later.iter().rev().map(as_step).collect()
        }
    };
    Ok(StepUndoPlan {
        available: true,
        is_undone,
        later_steps,
        can_redo: false,
    })
}

/// What Undo on step `id` would do. Writes nothing.
pub fn step_undo_plan(connection: &mut Connection, id: &str) -> Result<StepUndoPlan, CoreError> {
    let mut transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let plan = plan_in(&mut transaction, id)?;
    transaction.rollback()?;
    Ok(plan)
}

/// Takes back step `id`, alone when that leaves every later step as it was,
/// and otherwise with every later step, newest first. Returns the labels of
/// the steps taken back, the named one last; empty when it was gone or undone
/// already.
pub fn undo_step(connection: &mut Connection, id: &str) -> Result<Vec<String>, CoreError> {
    let mut transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let plan = plan_in(&mut transaction, id)?;
    if !plan.available || plan.is_undone {
        return Ok(Vec::new());
    }
    let mut labels = Vec::new();
    for later in &plan.later_steps {
        replay(&transaction, &later.id, true)?;
        mark(&transaction, &later.id, true)?;
        labels.push(later.label.clone());
    }
    replay(&transaction, id, true)?;
    mark(&transaction, id, true)?;
    let label: Option<String> = transaction.query_row(
        "SELECT MAX(label) FROM change_log WHERE groupId = ?1",
        [id],
        |row| row.get(0),
    )?;
    labels.push(label.unwrap_or_else(|| "Change".to_string()));
    transaction.commit()?;
    Ok(labels)
}

/// Puts back step `id`, which was taken back, when that leaves every later
/// standing step as it was. Returns whether it did.
pub fn redo_step(connection: &mut Connection, id: &str) -> Result<bool, CoreError> {
    let mut transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let plan = plan_in(&mut transaction, id)?;
    if !plan.can_redo {
        return Ok(false);
    }
    replay(&transaction, id, false)?;
    mark(&transaction, id, false)?;
    transaction.commit()?;
    Ok(true)
}

fn mark(transaction: &Connection, id: &str, undone: bool) -> Result<(), CoreError> {
    transaction.execute(
        "UPDATE change_log SET undone = ?1 WHERE groupId = ?2",
        params![undone, id],
    )?;
    Ok(())
}

// MARK: - The handle

#[uniffi::export]
impl CoreWorkspace {
    /// What Undo on one step would do; see [`step_undo_plan`].
    pub fn step_undo_plan(&self, id: String) -> Result<StepUndoPlan, CoreError> {
        step_undo_plan(&mut self.lock(), &id)
    }

    /// Takes back one step, with the later ones only when it must; see
    /// [`undo_step`].
    pub fn undo_step(&self, id: String) -> Result<Vec<String>, CoreError> {
        undo_step(&mut self.lock(), &id)
    }

    /// Puts back one step taken back; see [`redo_step`].
    pub fn redo_step(&self, id: String) -> Result<bool, CoreError> {
        redo_step(&mut self.lock(), &id)
    }
}
