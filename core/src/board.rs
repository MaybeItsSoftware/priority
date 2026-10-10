//! A combined scope's board — Everything's, or a folder's — selected and
//! walked here, so only what the board draws crosses.
//!
//! The Mac used to read every task of every list in scope
//! (`tasks_in_lists`), pick the actionable ones as cards, walk the trees for
//! each card's subtasks and every task's parent, and then read the cards'
//! metadata in a second call. At several thousand tasks almost all of that
//! was the crossing: every row came over once as a task and once more as a
//! metadata row. Here the selection and the walk are done over rows that
//! never leave the core, and what crosses is the rows the board draws — its
//! cards and their subtasks — the placements of those that have one, the
//! ids of the few tasks it names without drawing, and the trees' shape.
//!
//! Crossing costs by the value, not the byte: UniFFI's Swift side reads
//! every integer, option and string on its own, at a fraction of a
//! microsecond each, which is what made a row cost several microseconds. So
//! the rows (`packed_rows`) and the shape — tens of thousands of indexes —
//! cross as packed bytes, each read in one pass, and placements cross only
//! for the rows that have one.
//!
//! The rules are `WorkspaceListTree.actionableTasks(visibleRootTaskId:)` and
//! `WorkspaceBoardTrees(cardIDs:trees:)` in Swift, which a test holds this to.

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use crate::CoreError;
use crate::packed_rows::pack_task_rows;
use crate::records::{TaskColumns, TaskRow};

/// A drawn row's column and matrix place, for a row that has either.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BoardPlacement {
    /// An index into `BoardRead.rows`.
    pub row: u32,
    pub kanban_column: Option<String>,
    pub matrix_urgency: Option<i64>,
    pub matrix_importance: Option<i64>,
}

/// A combined scope's board.
///
/// Tasks are named by *node*: an index into `rows` followed by `other_ids`,
/// so node `rows.len() + i` is `other_ids[i]`. The fields of indexes are
/// packed, each a run of little-endian `u32`s, so that they cross as one
/// value each rather than one per index.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BoardRead {
    /// Packed by `packed_rows::pack_task_rows`: the tasks the board draws,
    /// the cards, then the other rows of their trees, each once. Thousands
    /// of them on Everything's board, so they cross as one buffer.
    pub rows: Vec<u8>,
    /// The placements of the rows that have one.
    pub placements: Vec<BoardPlacement>,
    /// Tasks the board names without drawing: a finished subtask left out,
    /// a list or a finished task a card hangs from.
    pub other_ids: Vec<String>,
    /// Packed: the cards in board order (sidebar order, then outline order),
    /// as indexes into `rows`.
    pub cards: Vec<u8>,
    /// Packed: each node's parent node, or `u32::MAX` for a task with no
    /// parent the walk reached. Covers every task the walk reached in a list
    /// that has a card.
    pub parents: Vec<u8>,
    /// Packed: the nodes that have a subtree — every card, and every task
    /// inside a card's tree — each followed by its rows' end in `tree_rows`
    /// and `tree_depths`. Its rows start where the previous key's end.
    pub tree_keys: Vec<u8>,
    /// Packed: indexes into `rows`, depth first beneath each key.
    pub tree_rows: Vec<u8>,
    /// Packed: each tree row's depth below its key, the key's children 0.
    pub tree_depths: Vec<u8>,
}

/// `values` as little-endian bytes.
fn packed(values: impl IntoIterator<Item = u32>) -> Vec<u8> {
    values.into_iter().flat_map(u32::to_le_bytes).collect()
}

/// The board of the lists `list_ids`, in that order: the open lists of
/// Everything or of a folder.
///
/// A finished task (anything not open) that was finished before
/// `hide_completed_before_ms`, or whose finish was never recorded, does not
/// cross as a row: it is left out of the trees, as the client would hide it.
/// It still counts for the walk — its open subtasks stay on show at their
/// depth — and is still named as a parent and a tree key. `None` keeps
/// every finished task.
pub fn combined_board(
    connection: &Connection,
    list_ids: &[String],
    hide_completed_before_ms: Option<i64>,
) -> Result<BoardRead, CoreError> {
    let (tasks, visible_roots) = read_tasks(connection, list_ids)?;
    let Selection { outlines, cards } = select(&tasks, &visible_roots, list_ids);
    let is_list = |task: &TaskRow| task.item_kind.as_deref() == Some("list");
    let is_open = |task: &TaskRow| !matches!(task.status.as_str(), "completed" | "cancelled");

    // `WorkspaceBoardTrees`: every list holding a card, walked without its
    // archived lists, for each task's parent and each card's tree.
    let card_set: HashSet<usize> = cards.iter().copied().collect();
    let mut touched: Vec<&str> = Vec::new();
    for &card in &cards {
        let list = tasks[card].list_id.as_str();
        if !touched.contains(&list) {
            touched.push(list);
        }
    }
    let mut parent_of: HashMap<usize, usize> = HashMap::new();
    let mut walked: Vec<usize> = Vec::new();
    let mut keyed: HashSet<usize> = card_set.clone();
    let mut trees: HashMap<usize, Vec<(usize, usize)>> = HashMap::new();
    for list in touched {
        let mut ancestors: Vec<(usize, usize)> = Vec::new();
        let mut archived_depth: Option<usize> = None;
        for &(index, depth) in outlines.get(list).into_iter().flatten() {
            if archived_depth.is_some_and(|d| depth <= d) {
                archived_depth = None;
            }
            if archived_depth.is_some() {
                continue;
            }
            let task = &tasks[index];
            if is_list(task) && task.archived_at_ms.is_some() {
                archived_depth = Some(depth);
                continue;
            }
            while ancestors.last().is_some_and(|(_, d)| *d >= depth) {
                ancestors.pop();
            }
            walked.push(index);
            if let Some(&(parent, _)) = ancestors.last() {
                parent_of.insert(index, parent);
            }
            // Keyed ancestors are closed downwards, so the nearest decides.
            let inside_card = ancestors.last().is_some_and(|(a, _)| keyed.contains(a));
            if inside_card {
                for &(ancestor, ancestor_depth) in &ancestors {
                    if keyed.contains(&ancestor) {
                        trees
                            .entry(ancestor)
                            .or_default()
                            .push((index, depth - ancestor_depth - 1));
                    }
                }
                keyed.insert(index);
            }
            ancestors.push((index, depth));
        }
    }

    // What crosses whole: the cards, then each tree row the client would
    // not hide outright.
    let hidden = |index: usize| {
        let task = &tasks[index];
        hide_completed_before_ms.is_some_and(|before| {
            !is_open(task) && task.completed_at_ms.is_none_or(|at| at < before)
        })
    };
    let mut node_of: HashMap<usize, u32> = HashMap::new();
    let mut drawn: Vec<usize> = Vec::new();
    for &index in cards.iter().chain(
        cards
            .iter()
            .flat_map(|card| trees.get(card).into_iter().flatten().map(|(i, _)| i)),
    ) {
        if !node_of.contains_key(&index) && (card_set.contains(&index) || !hidden(index)) {
            node_of.insert(index, drawn.len() as u32);
            drawn.push(index);
        }
    }
    // The rest of the walk, named by id: as a parent, a child or a key.
    let has_children: HashSet<usize> = parent_of.values().copied().collect();
    let mut other: Vec<usize> = Vec::new();
    for &index in &walked {
        if node_of.contains_key(&index) {
            continue;
        }
        if parent_of.contains_key(&index) || has_children.contains(&index) || keyed.contains(&index)
        {
            node_of.insert(index, (drawn.len() + other.len()) as u32);
            other.push(index);
        }
    }

    let nodes: Vec<usize> = drawn.iter().chain(other.iter()).copied().collect();
    let parents = packed(nodes.iter().map(|index| {
        parent_of
            .get(index)
            .and_then(|parent| node_of.get(parent))
            .map_or(u32::MAX, |&node| node)
    }));
    let mut tree_keys = Vec::new();
    let mut tree_rows = Vec::new();
    let mut tree_depths = Vec::new();
    for &index in &nodes {
        if !keyed.contains(&index) {
            continue;
        }
        for &(row, depth) in trees.get(&index).into_iter().flatten() {
            if let Some(&node) = node_of
                .get(&row)
                .filter(|&&node| (node as usize) < drawn.len())
            {
                tree_rows.push(node);
                tree_depths.push(depth as u32);
            }
        }
        tree_keys.push(node_of[&index]);
        tree_keys.push(tree_rows.len() as u32);
    }

    let mut placements = placements(connection)?;
    let other_ids = other.iter().map(|&index| tasks[index].id.clone()).collect();
    let cards = packed(cards.iter().map(|card| node_of[card]));
    let placements = drawn
        .iter()
        .enumerate()
        .filter_map(|(row, &index)| {
            let (kanban_column, matrix_urgency, matrix_importance) =
                placements.remove(&tasks[index].id)?;
            Some(BoardPlacement {
                row: row as u32,
                kanban_column,
                matrix_urgency,
                matrix_importance,
            })
        })
        .collect();
    Ok(BoardRead {
        rows: pack_task_rows(drawn.iter().map(|&index| &tasks[index])),
        placements,
        other_ids,
        cards,
        parents,
        tree_keys: packed(tree_keys),
        tree_rows: packed(tree_rows),
        tree_depths: packed(tree_depths),
    })
}

/// Each list's outline, and the cards picked from them.
struct Selection<'a> {
    /// Each list's outline, depth first in sibling order, each task once.
    outlines: HashMap<&'a str, Vec<(usize, usize)>>,
    /// The cards in board order, as indexes into the tasks.
    cards: Vec<usize>,
}

/// Picks the cards of `list_ids` out of `tasks`, list by list.
fn select<'a>(
    tasks: &'a [TaskRow],
    visible_roots: &HashMap<String, Option<String>>,
    list_ids: &'a [String],
) -> Selection<'a> {
    // Children by list and parent ("" for a root), in sibling order.
    let mut children: HashMap<(&str, &str), Vec<usize>> = HashMap::with_capacity(tasks.len());
    for (index, task) in tasks.iter().enumerate() {
        let parent = task.parent_task_id.as_deref().unwrap_or("");
        children
            .entry((task.list_id.as_str(), parent))
            .or_default()
            .push(index);
    }
    let is_list = |task: &TaskRow| task.item_kind.as_deref() == Some("list");
    let is_open = |task: &TaskRow| !matches!(task.status.as_str(), "completed" | "cancelled");

    // Each list's outline once, depth first in sibling order, each task once.
    let mut outlines: HashMap<&str, Vec<(usize, usize)>> = HashMap::new();
    for list_id in list_ids {
        if outlines.contains_key(list_id.as_str()) {
            continue;
        }
        let mut items = Vec::new();
        let mut visited: HashSet<usize> = HashSet::new();
        let mut stack: Vec<(usize, usize)> = children
            .get(&(list_id.as_str(), ""))
            .into_iter()
            .flatten()
            .rev()
            .map(|&index| (index, 0))
            .collect();
        while let Some((index, depth)) = stack.pop() {
            if !visited.insert(index) {
                continue;
            }
            items.push((index, depth));
            if let Some(kids) = children.get(&(list_id.as_str(), tasks[index].id.as_str())) {
                stack.extend(kids.iter().rev().map(|&kid| (kid, depth + 1)));
            }
        }
        outlines.insert(list_id.as_str(), items);
    }

    // The cards: `actionableTasks(visibleRootTaskId:)`, list by list. A task
    // beneath a list that is archived or not open is out, and so is the
    // list's own visible root.
    let mut cards: Vec<usize> = Vec::new();
    for list_id in list_ids {
        let visible_root = visible_roots.get(list_id).cloned().flatten();
        let mut ancestors: Vec<(usize, usize, bool)> = Vec::new();
        for &(index, depth) in &outlines[list_id.as_str()] {
            while ancestors.last().is_some_and(|(_, d, _)| *d >= depth) {
                ancestors.pop();
            }
            let task = &tasks[index];
            let suppresses = is_list(task) && (task.archived_at_ms.is_some() || !is_open(task));
            let inactive = suppresses || ancestors.last().is_some_and(|(_, _, i)| *i);
            if !is_list(task)
                && visible_root.as_deref() != Some(task.id.as_str())
                && !inactive
                && is_open(task)
            {
                cards.push(index);
            }
            ancestors.push((index, depth, inactive));
        }
    }
    Selection { outlines, cards }
}

/// The open, doable tasks of `list_ids`, in that order, packed by
/// `packed_rows::pack_task_rows`: a combined scope's outline, which draws
/// the cards flat and so needs none of the trees beneath them.
/// `WorkspaceStore.actionableTasks(in:limitedTo:)`.
pub fn actionable_tasks(
    connection: &Connection,
    list_ids: &[String],
) -> Result<Vec<u8>, CoreError> {
    let (tasks, visible_roots) = read_tasks(connection, list_ids)?;
    let selection = select(&tasks, &visible_roots, list_ids);
    Ok(pack_task_rows(
        selection.cards.iter().map(|&index| &tasks[index]),
    ))
}

/// Every task in the lists, in `tasks_in_lists`' order, and each list's
/// visible root.
#[allow(clippy::type_complexity)]
fn read_tasks(
    connection: &Connection,
    list_ids: &[String],
) -> Result<(Vec<TaskRow>, HashMap<String, Option<String>>), CoreError> {
    let mut unique: Vec<&String> = list_ids.iter().collect();
    unique.sort();
    unique.dedup();
    let mut tasks = Vec::new();
    let mut visible_roots = HashMap::new();
    for chunk in unique.chunks(500) {
        let marks = vec!["?"; chunk.len()].join(", ");
        let mut statement = connection.prepare_cached(&format!(
            "SELECT id, visibleRootTaskId FROM task_lists WHERE id IN ({marks})"
        ))?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk))?;
        while let Some(row) = rows.next()? {
            visible_roots.insert(row.get(0)?, row.get(1)?);
        }
        // The same statement as `records::tasks_in_lists`, so rows that tie
        // on every sort key come in the same order as the client's trees.
        let mut statement = connection.prepare_cached(&format!(
            "SELECT * FROM tasks WHERE listId IN ({marks}) ORDER BY listId, sortOrder, createdAt"
        ))?;
        let columns = TaskColumns::of(&statement)?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk))?;
        while let Some(row) = rows.next()? {
            tasks.push(columns.read(row)?);
        }
    }
    Ok((tasks, visible_roots))
}

type Placement = (Option<String>, Option<i64>, Option<i64>);

/// The column and matrix place of every task that has either.
fn placements(connection: &Connection) -> Result<HashMap<String, Placement>, CoreError> {
    let mut statement = connection.prepare_cached(
        "SELECT taskId, kanbanColumn, matrixUrgency, matrixImportance FROM task_metadata
         WHERE kanbanColumn IS NOT NULL OR matrixUrgency IS NOT NULL OR matrixImportance IS NOT NULL",
    )?;
    let mut rows = statement.query([])?;
    let mut result = HashMap::new();
    while let Some(row) = rows.next()? {
        result.insert(row.get(0)?, (row.get(1)?, row.get(2)?, row.get(3)?));
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
