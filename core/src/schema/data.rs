//! The three migrations that act on rows a database already holds.
//!
//! Their DDL is captured from GRDB with the rest; what is here is the part
//! that, in Swift, walked existing workspaces and lists. An empty database
//! never reaches these loops, so the capture could not record them, and they
//! are ported from `WorkspaceStore+Migrations.swift` by hand. The Swift
//! originals are `registerVisibleRoot`, `seedConditions` and the body of
//! `v13_legacy_visible_roots`.

use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Transaction, params};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::CoreError;

/// Runs the row-level part of `identifier`, if it has one.
pub(super) fn apply(transaction: &Transaction, identifier: &str) -> Result<(), CoreError> {
    match identifier {
        "v11_stable_visible_roots" => register_visible_roots(transaction, true),
        "v12_task_conditions_and_work" => seed_conditions_everywhere(transaction),
        "v13_legacy_visible_roots" => register_visible_roots(transaction, false),
        _ => Ok(()),
    }
}

/// v11 and v13: a list whose only root task is a wrapper named like the list
/// itself shows that wrapper's children instead, so `visibleRootTaskId`
/// points at the wrapper.
///
/// v11 recognises imported wrappers (the root has a source system). v13
/// recognises early bulk imports, which predate source identity: the root has
/// no source system, so it must also have been created in the same batch as
/// the list, with at least one child from that batch.
fn register_visible_roots(transaction: &Transaction, imported: bool) -> Result<(), CoreError> {
    register_visible_roots_in(transaction, imported, None)
}

/// [`register_visible_roots`] for one list, or every list. The importer runs
/// the imported form on a list it has just made.
/// `WorkspaceStore.registerVisibleRoot`.
pub(crate) fn register_visible_roots_in(
    transaction: &Transaction,
    imported: bool,
    only_list: Option<&str>,
) -> Result<(), CoreError> {
    let mut lists = transaction.prepare(if imported {
        "SELECT id, name, createdAt FROM task_lists WHERE (?1 IS NULL OR id = ?1)"
    } else {
        "SELECT id, name, createdAt FROM task_lists WHERE visibleRootTaskId IS NULL AND (?1 IS NULL OR id = ?1)"
    })?;
    let lists: Vec<(String, String, String)> = lists
        .query_map([only_list], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<_, _>>()?;

    for (list_id, list_name, list_created_at) in lists {
        let list_key = normalized_visible_root_name(&list_name);
        if list_key.is_empty() {
            continue;
        }
        let mut roots = transaction.prepare(
            "SELECT id, title, sourceSystem, createdAt FROM tasks
             WHERE listId = ?1 AND parentTaskId IS NULL",
        )?;
        let roots: Vec<(String, String, Option<String>, String)> = roots
            .query_map([&list_id], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?
            .collect::<Result<_, _>>()?;
        let [(root_id, root_title, source_system, root_created_at)] = roots.as_slice() else {
            continue;
        };
        if normalized_visible_root_name(root_title) != list_key {
            continue;
        }
        let qualifies = if imported {
            source_system.is_some()
                && transaction.query_row(
                    "SELECT EXISTS(SELECT 1 FROM tasks WHERE parentTaskId = ?1)",
                    [root_id],
                    |row| row.get::<_, bool>(0),
                )?
        } else {
            source_system.is_none()
                && *root_created_at == list_created_at
                && transaction.query_row(
                    "SELECT EXISTS(SELECT 1 FROM tasks WHERE parentTaskId = ?1 AND createdAt = ?2)",
                    params![root_id, list_created_at],
                    |row| row.get::<_, bool>(0),
                )?
        };
        if qualifies {
            transaction.execute(
                "UPDATE task_lists SET visibleRootTaskId = ?1 WHERE id = ?2",
                params![root_id, list_id],
            )?;
        }
    }
    Ok(())
}

/// v12: every existing workspace gets the four starting conditions a new one
/// is given (`WorkspaceStore.seedConditions`).
fn seed_conditions_everywhere(transaction: &Transaction) -> Result<(), CoreError> {
    let mut workspaces = transaction.prepare("SELECT id FROM workspaces")?;
    let workspaces: Vec<String> = workspaces
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let now = grdb_timestamp(SystemTime::now());
    for workspace_id in workspaces {
        seed_conditions(transaction, &workspace_id, &now)?;
    }
    Ok(())
}

/// The four starting conditions a workspace is given: `WorkspaceStore.seedConditions`.
pub(crate) fn seed_conditions(
    transaction: &Transaction,
    workspace_id: &str,
    now: &str,
) -> Result<(), CoreError> {
    for (name, is_location) in [
        ("Home", true),
        ("Campus", true),
        ("Private", false),
        ("Floor space", false),
    ] {
        transaction.execute(
            "INSERT INTO task_conditions
               (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)",
            params![
                uuid::Uuid::new_v4().to_string().to_uppercase(),
                workspace_id,
                name,
                is_location,
                now
            ],
        )?;
    }
    Ok(())
}

/// `WorkspaceStore.normalizedVisibleRootName`: case and diacritics folded
/// away, then everything that is not a letter or a digit dropped, so
/// "Café — Work" and "cafe work" match.
///
/// Swift folds with the user's locale; this folds the same way everywhere.
/// The two differ only for locale-specific case rules (the Turkish dotted i),
/// which no list name has needed.
pub(crate) fn normalized_visible_root_name(name: &str) -> String {
    name.nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// A date as GRDB stores one: UTC, `YYYY-MM-DD HH:MM:SS.SSS`.
pub fn grdb_timestamp(time: SystemTime) -> String {
    let since = time.duration_since(UNIX_EPOCH).unwrap_or_default();
    let seconds = since.as_secs() as i64;
    let millis = since.subsec_millis();
    let (days, rem) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}.{millis:03}",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
/// `civil_from_days`).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}
