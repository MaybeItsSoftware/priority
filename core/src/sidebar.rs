//! What the sidebar draws beneath its lists, walked here so only that crosses.
//!
//! The sidebar used to read every task in every list (`tasks_in_lists`) and
//! shape them in the client, on every write, undo, external write and sync
//! pull. At several thousand tasks the crossing alone was most of a refresh,
//! while what the sidebar keeps is a few dozen nested lists and one count per
//! list. So the walk is here, over the four columns it needs, and the client
//! gets the nested lists' rows and the counts.
//! `WorkspaceSidebarIndex(lists:trees:)` in Swift is the same walk over rows
//! already in memory; a test holds the two to the same answer.

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use crate::CoreError;
use crate::records::{self, OutlineItem, TaskRow};
use crate::time::parse_stored;

/// One list's task count. `WorkspaceSidebarIndex.taskCounts`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ListTaskCount {
    pub list_id: String,
    pub count: i64,
}

/// `WorkspaceSidebarIndex`: the nested lists to draw, with their depth among
/// lists; the archived ones the restore menu offers; each list's task count.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SidebarIndex {
    pub nested_lists: Vec<OutlineItem>,
    pub archived_nested_lists: Vec<TaskRow>,
    pub task_counts: Vec<ListTaskCount>,
}

/// The little of a task the walk needs.
struct Node {
    id: String,
    list_id: String,
    parent_id: Option<String>,
    is_list: bool,
    archived: bool,
}

/// Walks each list in the order given, each depth first in sibling order. A
/// task counts if the walk reaches it from a root. A nested list's depth
/// counts only the lists above it, not the tasks, and the list's own visible
/// root is not one; a nested list beneath an archived one is hidden with it.
pub fn sidebar_index(
    connection: &Connection,
    list_ids: &[String],
) -> Result<SidebarIndex, CoreError> {
    let mut visible_roots: HashMap<String, Option<String>> = HashMap::new();
    let mut nodes: Vec<Node> = Vec::new();
    let mut unique: Vec<&String> = list_ids.iter().collect();
    unique.sort();
    unique.dedup();
    for chunk in unique.chunks(500) {
        let marks = vec!["?"; chunk.len()].join(", ");
        let mut statement = connection.prepare_cached(&format!(
            "SELECT id, visibleRootTaskId FROM task_lists WHERE id IN ({marks})"
        ))?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk))?;
        while let Some(row) = rows.next()? {
            visible_roots.insert(row.get(0)?, row.get(1)?);
        }
        let mut statement = connection.prepare_cached(&format!(
            "SELECT id, listId, parentTaskId, itemKind = 'list', \
               CASE WHEN itemKind = 'list' THEN archivedAt END \
             FROM tasks WHERE listId IN ({marks}) ORDER BY listId, sortOrder, createdAt"
        ))?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk))?;
        while let Some(row) = rows.next()? {
            let archived_at: Option<String> = row.get(4)?;
            nodes.push(Node {
                id: row.get(0)?,
                list_id: row.get(1)?,
                parent_id: row.get(2)?,
                is_list: row.get::<_, Option<bool>>(3)?.unwrap_or(false),
                // As the client reads it: a date it can parse.
                archived: archived_at.as_deref().and_then(parse_stored).is_some(),
            });
        }
    }
    // Children keyed by list and parent ("" for a root), in sibling order:
    // the walk is per list, as the client's trees are.
    let mut children: HashMap<(&str, &str), Vec<&Node>> = HashMap::with_capacity(nodes.len());
    for node in &nodes {
        let parent = node.parent_id.as_deref().unwrap_or("");
        children
            .entry((node.list_id.as_str(), parent))
            .or_default()
            .push(node);
    }

    let mut nested: Vec<(String, i64)> = Vec::new();
    let mut archived: Vec<String> = Vec::new();
    let mut counts = Vec::with_capacity(list_ids.len());
    for list_id in list_ids {
        let visible_root = visible_roots.get(list_id).cloned().flatten();
        let mut count = 0i64;
        let mut visited: HashSet<&str> = HashSet::new();
        // (node, depth) on an explicit stack in reverse, so the pop order is
        // sibling order, depth first.
        let mut stack: Vec<(&Node, usize)> = children
            .get(&(list_id.as_str(), ""))
            .into_iter()
            .flatten()
            .rev()
            .map(|node| (*node, 0))
            .collect();
        // The path from the root to the item being visited.
        let mut ancestors: Vec<(&Node, usize)> = Vec::new();
        while let Some((node, depth)) = stack.pop() {
            if !visited.insert(node.id.as_str()) {
                continue;
            }
            count += 1;
            while ancestors.last().is_some_and(|(_, d)| *d >= depth) {
                ancestors.pop();
            }
            let is_visible_root = visible_root.as_deref() == Some(node.id.as_str());
            if node.is_list && !is_visible_root {
                if node.archived {
                    archived.push(node.id.clone());
                } else if !ancestors.iter().any(|(a, _)| a.is_list && a.archived) {
                    let list_depth = ancestors
                        .iter()
                        .filter(|(a, _)| {
                            a.is_list && visible_root.as_deref() != Some(a.id.as_str())
                        })
                        .count();
                    nested.push((node.id.clone(), list_depth as i64));
                }
            }
            ancestors.push((node, depth));
            if let Some(kids) = children.get(&(list_id.as_str(), node.id.as_str())) {
                stack.extend(kids.iter().rev().map(|kid| (*kid, depth + 1)));
            }
        }
        counts.push(ListTaskCount {
            list_id: list_id.clone(),
            count,
        });
    }

    // Only the lists cross as whole rows.
    let wanted: Vec<String> = nested
        .iter()
        .map(|(id, _)| id.clone())
        .chain(archived.iter().cloned())
        .collect();
    let mut rows: HashMap<String, TaskRow> = records::tasks_by_id(connection, &wanted)?
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect();
    let nested_lists = nested
        .into_iter()
        .filter_map(|(id, depth)| {
            rows.get(&id)
                .cloned()
                .map(|task| OutlineItem { task, depth })
        })
        .collect();
    let archived_nested_lists = archived
        .into_iter()
        .filter_map(|id| rows.remove(&id))
        .collect();
    Ok(SidebarIndex {
        nested_lists,
        archived_nested_lists,
        task_counts: counts,
    })
}

#[cfg(test)]
mod tests;
