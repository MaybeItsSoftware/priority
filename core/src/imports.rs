//! Bringing work in from somewhere else (Checkvist so far). Running an import
//! twice must not make two copies of anything. Replaces
//! `WorkspaceStore+Import.swift`.

use std::collections::{HashMap, HashSet};

use rusqlite::{OptionalExtension, Transaction, params};

use crate::CoreError;
use crate::lists::new_id;
use crate::time::stored;

/// One task as the outside service has it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportedTaskSeed {
    pub source_id: String,
    pub parent_source_id: Option<String>,
    pub title: String,
    pub notes: String,
    /// "open", "completed" or "cancelled".
    pub status: String,
    pub sort_order: i64,
}

/// What an import did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportOutcome {
    pub list_id: String,
    pub inserted_task_ids: Vec<String>,
    pub updated_task_ids: Vec<String>,
    pub created_list: bool,
}

/// Copies tasks from an outside service into the workspace, safely re-run.
///
/// A seed whose `(source_system, source_id)` is already present updates that
/// task's content only: where it sits locally is the user's. A previous
/// run's list (the one most of its tasks still live in) is the destination;
/// otherwise a new list named `list_name` is made. A broken parent link
/// becomes a root, a cycle is broken by promoting one member to a root, and
/// duplicate source ids in one run are refused. Not an undo step.
/// `WorkspaceStore.importTasks`.
pub fn import_tasks(
    transaction: &Transaction,
    workspace_id: &str,
    list_name: &str,
    source_system: &str,
    seeds: &[ImportedTaskSeed],
    now_ms: i64,
) -> Result<Option<ImportOutcome>, CoreError> {
    if seeds.is_empty() {
        return Ok(None);
    }
    let source_ids: HashSet<&str> = seeds.iter().map(|seed| seed.source_id.as_str()).collect();
    if source_ids.len() != seeds.len() {
        return Err(CoreError::DuplicateSourceId);
    }
    let now = stored(now_ms);

    // The tasks a previous run made, by source id, with the list each is in.
    let mut existing: HashMap<String, (String, String)> = HashMap::new();
    let ids: Vec<&str> = seeds.iter().map(|seed| seed.source_id.as_str()).collect();
    for chunk in ids.chunks(400) {
        let placeholders = vec!["?"; chunk.len()].join(",");
        let sql = format!(
            "SELECT tasks.sourceId, tasks.id, tasks.listId FROM tasks
             JOIN task_lists ON task_lists.id = tasks.listId
             WHERE task_lists.workspaceId = ? AND tasks.sourceSystem = ? AND tasks.sourceId IN ({placeholders})"
        );
        let mut statement = transaction.prepare(&sql)?;
        let mut values: Vec<&dyn rusqlite::ToSql> = vec![&workspace_id, &source_system];
        for id in chunk {
            values.push(id);
        }
        let rows = statement.query_map(values.as_slice(), |row| {
            Ok((
                row.get::<_, String>(0)?,
                (row.get::<_, String>(1)?, row.get::<_, String>(2)?),
            ))
        })?;
        for row in rows {
            let (source, found) = row?;
            existing.insert(source, found);
        }
    }

    let mut counts: HashMap<&str, usize> = HashMap::new();
    for (_, list) in existing.values() {
        *counts.entry(list.as_str()).or_default() += 1;
    }
    // Most tasks wins; a tie goes to the smallest id, as Swift's max(by:) does.
    let home = counts
        .iter()
        .max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0)))
        .map(|(list, _)| list.to_string());
    let home = match home {
        Some(list) => transaction
            .query_row("SELECT id FROM task_lists WHERE id = ?1", [&list], |row| {
                row.get::<_, String>(0)
            })
            .optional()?,
        None => None,
    };
    let (list_id, created_list) = match home {
        Some(list) => (list, false),
        None => {
            let order: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?1 AND folderId IS NULL",
                [workspace_id],
                |row| row.get(0),
            )?;
            let id = new_id();
            transaction.execute(
                "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived,
                                         createdAt, updatedAt, systemRole, visibleRootTaskId, completedAt)
                 VALUES (?1, ?2, NULL, ?3, NULL, ?4, 0, ?5, ?5, NULL, NULL, NULL)",
                params![id, workspace_id, list_name, order, now],
            )?;
            (id, true)
        }
    };

    let mut local_id: HashMap<&str, String> = existing
        .iter()
        .map(|(source, (id, _))| (source.as_str(), id.clone()))
        .collect();
    for seed in seeds {
        local_id
            .entry(seed.source_id.as_str())
            .or_insert_with(new_id);
    }
    let mut settled: HashSet<&str> = HashSet::new();
    let mut inserted = Vec::new();
    let mut updated = Vec::new();
    let mut remaining: Vec<&ImportedTaskSeed> = seeds.iter().collect();
    while !remaining.is_empty() {
        let ready = remaining
            .iter()
            .position(|seed| match seed.parent_source_id.as_deref() {
                None => true,
                Some(parent) => !source_ids.contains(parent) || settled.contains(parent),
            });
        // A cyclic hierarchy cannot be held by foreign keys: promote one
        // member to a root and keep every task.
        let seed = remaining.remove(ready.unwrap_or(0));
        let id = local_id[seed.source_id.as_str()].clone();
        if existing.contains_key(&seed.source_id) {
            transaction.execute(
                "UPDATE tasks SET title = ?1, notes = ?2, status = ?3, updatedAt = ?4 WHERE id = ?5",
                params![seed.title, seed.notes, seed.status, now, id],
            )?;
            updated.push(id);
        } else {
            let parent = if ready.is_some() {
                seed.parent_source_id
                    .as_deref()
                    .and_then(|parent| local_id.get(parent))
                    .cloned()
            } else {
                None
            };
            transaction.execute(
                "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
                                    sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, NULL, ?8, ?9, 'task', NULL, NULL, NULL, ?10, ?10)",
                params![
                    id,
                    list_id,
                    parent,
                    seed.title,
                    seed.notes,
                    seed.status,
                    seed.sort_order,
                    source_system,
                    seed.source_id,
                    now
                ],
            )?;
            inserted.push(id);
        }
        settled.insert(seed.source_id.as_str());
    }
    if created_list {
        crate::schema::data::register_visible_roots_in(transaction, true, Some(&list_id))?;
    }
    Ok(Some(ImportOutcome {
        list_id,
        inserted_task_ids: inserted,
        updated_task_ids: updated,
        created_list,
    }))
}

/// A daily from before the workspace kept them, as the old plugin stored it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LegacyDailySeed {
    pub id: String,
    pub title: String,
    pub weekdays: Vec<u32>,
    pub interval_days: Option<i64>,
    pub interval_anchor_ms: Option<i64>,
    pub target_seconds: Option<i64>,
    pub archived_at_ms: Option<i64>,
    pub created_at_ms: i64,
}

/// Brings the plugin-era dailies in once: each becomes a task in the Habits
/// list with its daily, keyed by its old id so a second run adds nothing; and
/// each task in `progress_task_ids` without a daily gets an every-day one.
/// Returns how many dailies it made. Not an undo step.
/// `WorkspaceStore.importLegacyDailies`.
pub fn import_legacy_dailies(
    transaction: &Transaction,
    legacy: &[LegacyDailySeed],
    progress_task_ids: &[String],
    now_ms: i64,
) -> Result<u32, CoreError> {
    let workspace: Option<String> = transaction
        .query_row("SELECT id FROM workspaces LIMIT 1", [], |row| row.get(0))
        .optional()?;
    let Some(workspace) = workspace else {
        return Ok(0);
    };
    let now = stored(now_ms);
    let mut imported = 0;
    let mut order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dailies",
        [],
        |row| row.get(0),
    )?;
    for task_id in progress_task_ids {
        let wanted: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?1)
                    AND NOT EXISTS(SELECT 1 FROM dailies WHERE taskId = ?1)",
            [task_id],
            |row| row.get(0),
        )?;
        if !wanted {
            continue;
        }
        transaction.execute(
            "INSERT INTO dailies (id, taskId, activeWeekdaysMask, sortOrder, createdAt, updatedAt)
             VALUES (?1, ?2, 127, ?3, ?4, ?4)",
            params![new_id(), task_id, order, now],
        )?;
        order += 1;
        imported += 1;
    }
    let mut pending = Vec::new();
    for seed in legacy {
        let known: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM dailies WHERE legacyDailyId = ?1)",
            [&seed.id],
            |row| row.get(0),
        )?;
        if !known {
            pending.push(seed);
        }
    }
    if pending.is_empty() {
        return Ok(imported);
    }
    let habits = crate::habits::habits_list(transaction, &workspace, now_ms)?;
    let first_task_order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ?1",
        [&habits],
        |row| row.get(0),
    )?;
    for (offset, seed) in pending.into_iter().enumerate() {
        let task_order = first_task_order + offset as i64;
        let task_id = new_id();
        transaction.execute(
            "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
                                sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
             VALUES (?1, ?2, NULL, ?3, '', 'open', ?4, NULL, ?5, NULL, NULL, 'task', NULL, NULL, NULL, ?6, ?7)",
            params![task_id, habits, seed.title, task_order, seed.target_seconds, stored(seed.created_at_ms), now],
        )?;
        transaction.execute(
            "INSERT INTO dailies (id, taskId, activeWeekdaysMask, intervalDays, intervalAnchor, targetSeconds,
                                  sortOrder, archivedAt, legacyDailyId, createdAt, updatedAt)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                new_id(),
                task_id,
                crate::dailies::weekday_mask(&seed.weekdays),
                seed.interval_days,
                seed.interval_anchor_ms.map(stored),
                seed.target_seconds,
                order,
                seed.archived_at_ms.map(stored),
                seed.id,
                stored(seed.created_at_ms),
                now
            ],
        )?;
        order += 1;
        imported += 1;
    }
    Ok(imported)
}

/// One board's saved columns, as `kanban_boards` holds them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BoardBaseline {
    pub key: String,
    pub columns_json: String,
}

/// Seeds `kanban_boards` from the boards the old preferences held, plus the
/// default columns for `current_key` if it had none, without replacing a
/// board already there; returns every board. Not an undo step.
/// `WorkspaceStore.kanbanBoardConfigurations`.
pub fn kanban_board_baseline(
    transaction: &Transaction,
    legacy: &[BoardBaseline],
    current_key: &str,
) -> Result<Vec<BoardBaseline>, CoreError> {
    let mut boards: Vec<BoardBaseline> = legacy.to_vec();
    if !boards.iter().any(|board| board.key == current_key) {
        let defaults: Vec<crate::conversions::BoardColumn> = [
            ("backlog", "Backlog"),
            ("in-progress", "In progress"),
            ("this-week", "This week"),
            ("waiting-on", "Waiting on"),
            ("today", "Today"),
        ]
        .iter()
        .map(|(id, title)| crate::conversions::BoardColumn {
            id: id.to_string(),
            title: title.to_string(),
        })
        .collect();
        boards.push(BoardBaseline {
            key: current_key.to_string(),
            columns_json: crate::conversions::columns_json(&defaults),
        });
    }
    for board in &boards {
        // Only a non-empty array of columns with ids and titles is a board.
        let valid = serde_json::from_str::<Vec<serde_json::Value>>(&board.columns_json).is_ok_and(
            |columns| {
                !columns.is_empty()
                    && columns
                        .iter()
                        .all(|c| c["id"].is_string() && c["title"].is_string())
            },
        );
        if valid {
            transaction.execute(
                "INSERT OR IGNORE INTO kanban_boards (id, columnsJSON) VALUES (?1, ?2)",
                params![board.key, board.columns_json],
            )?;
        }
    }
    let mut statement = transaction.prepare("SELECT id, columnsJSON FROM kanban_boards")?;
    let all = statement
        .query_map([], |row| {
            Ok(BoardBaseline {
                key: row.get(0)?,
                columns_json: row.get(1)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(all)
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;
    use crate::schema::migrate;

    fn database() -> Connection {
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

    fn seed(id: &str, parent: Option<&str>, title: &str) -> ImportedTaskSeed {
        ImportedTaskSeed {
            source_id: id.into(),
            parent_source_id: parent.map(str::to_string),
            title: title.into(),
            notes: String::new(),
            status: "open".into(),
            sort_order: 0,
        }
    }

    #[test]
    fn importing_twice_updates_in_place_and_keeps_the_users_moves() {
        let mut connection = database();
        let seeds = vec![
            seed("1", None, "Work"),
            seed("2", Some("1"), "Proposal"),
            seed("3", Some("gone"), "Orphan"),
        ];
        let tx = connection.transaction().unwrap();
        let first = import_tasks(&tx, "w", "Work", "checkvist", &seeds, 1)
            .unwrap()
            .unwrap();
        tx.commit().unwrap();
        assert!(first.created_list);
        assert_eq!(first.inserted_task_ids.len(), 3);
        let parent: Option<String> = connection
            .query_row(
                "SELECT parentTaskId FROM tasks WHERE sourceId = '3'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(parent, None);

        let renamed = vec![seed("1", None, "Work"), seed("2", Some("1"), "Proposal v2")];
        let tx = connection.transaction().unwrap();
        let second = import_tasks(&tx, "w", "Elsewhere", "checkvist", &renamed, 2)
            .unwrap()
            .unwrap();
        tx.commit().unwrap();
        assert_eq!(
            (second.created_list, second.list_id.as_str()),
            (false, first.list_id.as_str())
        );
        assert_eq!(second.updated_task_ids.len(), 2);
        let title: String = connection
            .query_row("SELECT title FROM tasks WHERE sourceId = '2'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(title, "Proposal v2");
        let lists: i64 = connection
            .query_row("SELECT COUNT(*) FROM task_lists", [], |row| row.get(0))
            .unwrap();
        assert_eq!(lists, 1);
    }

    #[test]
    fn legacy_dailies_come_in_once_and_boards_seed_without_replacing() {
        let mut connection = database();
        let seed = LegacyDailySeed {
            id: "old-1".into(),
            title: "Stretch".into(),
            weekdays: vec![2, 4, 6],
            interval_days: None,
            interval_anchor_ms: None,
            target_seconds: Some(600),
            archived_at_ms: None,
            created_at_ms: 1_600_000_000_000,
        };
        let tx = connection.transaction().unwrap();
        assert_eq!(
            import_legacy_dailies(&tx, std::slice::from_ref(&seed), &[], 1).unwrap(),
            1
        );
        assert_eq!(import_legacy_dailies(&tx, &[seed], &[], 2).unwrap(), 0);
        let (mask, legacy): (i64, String) = tx
            .query_row(
                "SELECT activeWeekdaysMask, legacyDailyId FROM dailies",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((mask, legacy.as_str()), (42, "old-1"));

        tx.execute("INSERT INTO kanban_boards (id, columnsJSON) VALUES ('kept', '[{\"id\":\"a\",\"title\":\"A\"}]')", [])
            .unwrap();
        let legacy_boards = vec![
            BoardBaseline {
                key: "kept".into(),
                columns_json: "[{\"id\":\"b\",\"title\":\"B\"}]".into(),
            },
            BoardBaseline {
                key: "bad".into(),
                columns_json: "[]".into(),
            },
        ];
        let mut boards = kanban_board_baseline(&tx, &legacy_boards, "workspace").unwrap();
        boards.sort_by(|a, b| a.key.cmp(&b.key));
        let keys: Vec<&str> = boards.iter().map(|b| b.key.as_str()).collect();
        assert_eq!(keys, ["kept", "workspace"]);
        assert_eq!(boards[0].columns_json, "[{\"id\":\"a\",\"title\":\"A\"}]");
        assert!(
            boards[1]
                .columns_json
                .starts_with("[{\"id\":\"backlog\",\"title\":\"Backlog\"}")
        );
    }

    #[test]
    fn duplicates_are_refused_and_a_cycle_keeps_every_task() {
        let mut connection = database();
        let tx = connection.transaction().unwrap();
        assert!(matches!(
            import_tasks(
                &tx,
                "w",
                "X",
                "checkvist",
                &[seed("1", None, "A"), seed("1", None, "B")],
                1
            ),
            Err(CoreError::DuplicateSourceId)
        ));
        let cycle = vec![seed("a", Some("b"), "A"), seed("b", Some("a"), "B")];
        let outcome = import_tasks(&tx, "w", "Loop", "checkvist", &cycle, 1)
            .unwrap()
            .unwrap();
        assert_eq!(outcome.inserted_task_ids.len(), 2);
        assert!(
            import_tasks(&tx, "w", "Empty", "checkvist", &[], 1)
                .unwrap()
                .is_none()
        );
    }
}
