//! The context: which conditions hold now, the time available, the goal and
//! when the answer lapses, kept per workspace in `focus_contexts`.
//!
//! It used to live in each app's preferences, where nothing else could see
//! it. As a row, the CLI and the agent read and set it like any other part
//! of the workspace, and the app sees their change the way it sees any other
//! external write. The table is local and neither journalled nor synced:
//! where you are is where this machine is, and saying so is not an edit to
//! undo.

use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::time::{decode_strings, parse_stored, stored, swift_json_strings};

/// What holds now, as stored.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StoredFocusContext {
    /// The conditions on, sorted.
    pub condition_ids: Vec<String>,
    /// When the conditions on were last changed; none with none on.
    pub conditions_set_at_ms: Option<i64>,
    /// When the time available ends; none for no limit.
    pub available_until_ms: Option<i64>,
    /// When the conditions stop being trusted; none for never.
    pub expires_at_ms: Option<i64>,
    /// "progress" or "finish".
    pub mode: String,
    /// The conditions that held before the last expiry, offered back.
    pub suggested_ids: Vec<String>,
}

impl Default for StoredFocusContext {
    fn default() -> Self {
        Self {
            condition_ids: Vec::new(),
            conditions_set_at_ms: None,
            available_until_ms: None,
            expires_at_ms: None,
            mode: "progress".to_string(),
            suggested_ids: Vec::new(),
        }
    }
}

fn sorted(ids: Vec<String>) -> Vec<String> {
    ids.into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn table_exists(connection: &Connection) -> Result<bool, CoreError> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'focus_contexts')",
        [],
        |row| row.get(0),
    )?)
}

fn millis(text: Option<String>) -> Option<i64> {
    text.as_deref()
        .and_then(parse_stored)
        .map(|instant| instant.timestamp_millis())
}

/// The workspace's context as last saved, or none if it never was (or the
/// database predates v27).
pub fn load(
    connection: &Connection,
    workspace_id: &str,
) -> Result<Option<StoredFocusContext>, CoreError> {
    if !table_exists(connection)? {
        return Ok(None);
    }
    Ok(connection
        .query_row(
            "SELECT conditionIdsJSON, conditionsSetAt, availableUntil, expiresAt, mode, suggestedIdsJSON
             FROM focus_contexts WHERE workspaceId = ?1",
            [workspace_id],
            |row| {
                Ok(StoredFocusContext {
                    condition_ids: sorted(decode_strings(&row.get::<_, String>(0)?)),
                    conditions_set_at_ms: millis(row.get(1)?),
                    available_until_ms: millis(row.get(2)?),
                    expires_at_ms: millis(row.get(3)?),
                    mode: row.get(4)?,
                    suggested_ids: sorted(decode_strings(&row.get::<_, String>(5)?)),
                })
            },
        )
        .optional()?)
}

/// Saves the workspace's context. When the conditions on differ from what
/// was stored, they are stamped as set at `now_ms` (and the stamp goes when
/// none are on); otherwise the stamp stays, whatever `context` carries.
/// False, writing nothing, when nothing changed.
pub fn save(
    transaction: &Transaction,
    workspace_id: &str,
    context: &StoredFocusContext,
    now_ms: i64,
) -> Result<bool, CoreError> {
    let current = load(transaction, workspace_id)?;
    let ids = sorted(context.condition_ids.clone());
    let set_at = if ids.is_empty() {
        None
    } else {
        match &current {
            Some(current) if current.condition_ids == ids => current.conditions_set_at_ms,
            _ => Some(now_ms),
        }
    };
    let next = StoredFocusContext {
        condition_ids: ids,
        conditions_set_at_ms: set_at,
        suggested_ids: sorted(context.suggested_ids.clone()),
        mode: if context.mode == "finish" {
            "finish".to_string()
        } else {
            "progress".to_string()
        },
        ..context.clone()
    };
    if current.as_ref() == Some(&next) {
        return Ok(false);
    }
    transaction.execute(
        "INSERT INTO focus_contexts
           (workspaceId, conditionIdsJSON, conditionsSetAt, availableUntil, expiresAt, mode, suggestedIdsJSON, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(workspaceId) DO UPDATE SET
           conditionIdsJSON = excluded.conditionIdsJSON, conditionsSetAt = excluded.conditionsSetAt,
           availableUntil = excluded.availableUntil, expiresAt = excluded.expiresAt,
           mode = excluded.mode, suggestedIdsJSON = excluded.suggestedIdsJSON,
           updatedAt = excluded.updatedAt",
        params![
            workspace_id,
            swift_json_strings(&next.condition_ids),
            next.conditions_set_at_ms.map(stored),
            next.available_until_ms.map(stored),
            next.expires_at_ms.map(stored),
            next.mode,
            swift_json_strings(&next.suggested_ids),
            stored(now_ms),
        ],
    )?;
    Ok(true)
}

/// A merged condition's place in the context taken by the one it was merged
/// into, on and offered back alike.
pub(crate) fn replace_condition(
    transaction: &Transaction,
    workspace_id: &str,
    from: &str,
    into: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let Some(mut context) = load(transaction, workspace_id)? else {
        return Ok(());
    };
    let swap = |ids: &mut Vec<String>| {
        for id in ids.iter_mut() {
            if id == from {
                *id = into.to_string();
            }
        }
    };
    let set_at = context.conditions_set_at_ms;
    swap(&mut context.condition_ids);
    swap(&mut context.suggested_ids);
    context.condition_ids = sorted(context.condition_ids);
    save(transaction, workspace_id, &context, now_ms)?;
    // The same answer, renamed: not a new one, so it keeps its stamp.
    if set_at.is_some() {
        transaction.execute(
            "UPDATE focus_contexts SET conditionsSetAt = ?1 WHERE workspaceId = ?2",
            params![set_at.map(stored), workspace_id],
        )?;
    }
    Ok(())
}

/// The context as it stands at `now_ms`: once it has expired its conditions
/// are set aside — offered back, so "Use again" can restore them — and the
/// expiry and stamp go with them. Otherwise `context` unchanged.
#[uniffi::export]
pub fn focus_context_in_force(context: StoredFocusContext, now_ms: i64) -> StoredFocusContext {
    match context.expires_at_ms {
        Some(expiry) if expiry <= now_ms => StoredFocusContext {
            suggested_ids: if context.condition_ids.is_empty() {
                context.suggested_ids
            } else {
                context.condition_ids
            },
            condition_ids: Vec::new(),
            conditions_set_at_ms: None,
            expires_at_ms: None,
            ..context
        },
        _ => context,
    }
}

/// Whether the conditions on were said on an earlier day than `now_ms`, in
/// `zone`: a place left on overnight is probably not where you are. Never
/// with nothing on.
#[uniffi::export]
pub fn focus_context_is_stale(context: StoredFocusContext, now_ms: i64, zone: String) -> bool {
    use chrono::TimeZone;
    let (false, Some(set_at)) = (
        context.condition_ids.is_empty(),
        context.conditions_set_at_ms,
    ) else {
        return false;
    };
    let zone = crate::periodic::zone(&zone);
    let day = |ms: i64| {
        zone.timestamp_millis_opt(ms)
            .single()
            .map(|instant| instant.date_naive())
    };
    matches!((day(set_at), day(now_ms)), (Some(then), Some(now)) if then < now)
}

/// `current` with `on` turned on and `off` turned off. Turning a place on
/// turns every other place (`location_ids`) off, since you are in one place
/// at a time; whatever else combines. Sorted.
#[uniffi::export]
pub fn focus_context_changed(
    current: Vec<String>,
    on: Vec<String>,
    off: Vec<String>,
    location_ids: Vec<String>,
) -> Vec<String> {
    let mut next: BTreeSet<String> = current.into_iter().collect();
    for id in &off {
        next.remove(id);
    }
    // The last place named wins, as saying two in a row would.
    for id in on {
        if location_ids.contains(&id) {
            for place in &location_ids {
                next.remove(place);
            }
        }
        next.insert(id);
    }
    next.into_iter().collect()
}

#[cfg(test)]
mod tests;
