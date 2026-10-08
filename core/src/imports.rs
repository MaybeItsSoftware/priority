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
