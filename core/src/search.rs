//! Finding a task by what it says. `WorkspaceStore+Search.swift`.
//!
//! The query is a set of prefixes, so results narrow as the user types. Titles
//! weigh ten times notes: a task called "Invoice" beats one whose notes merely
//! mention invoices.

use std::collections::HashMap;

use rusqlite::Connection;

use crate::CoreError;
use crate::records::{ListRow, TaskRow, list};

/// One hit, with the list it lives in. `TaskSearchResult`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub task: TaskRow,
    pub list: ListRow,
    /// The matching stretch of the notes, when the match was in the notes.
    pub notes_snippet: Option<String>,
}

/// FTS5's `ascii` tokenizer as a query: ASCII letters and digits and every
/// non-ASCII character make tokens, other ASCII separates them, and ASCII is
/// folded to lower case. Each token is quoted, so a word like `OR` or a stray
/// quote cannot change the query's meaning, and matched as a prefix. Absent
/// when nothing is left to match on.
pub fn prefix_pattern(query: &str) -> Option<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for c in query.chars() {
        if c.is_ascii() && !c.is_ascii_alphanumeric() {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
        } else {
            current.push(c.to_ascii_lowercase());
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    if tokens.is_empty() {
        return None;
    }
    Some(
        tokens
            .iter()
            .map(|token| format!("\"{token}\"*"))
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// Searches titles and notes across a workspace, best match first.
pub fn search(
    connection: &Connection,
    workspace_id: &str,
    query: &str,
    including_completed: bool,
    including_archived_lists: bool,
    limit: i64,
) -> Result<Vec<SearchHit>, CoreError> {
    let Some(pattern) = prefix_pattern(query.trim()) else {
        return Ok(Vec::new());
    };
    let sql = format!(
        "SELECT {}, snippet(tasks_fts, 1, '', '', '…', 10) AS notesSnippet
         FROM tasks_fts
         JOIN tasks ON tasks.rowid = tasks_fts.rowid
         JOIN task_lists ON task_lists.id = tasks.listId
         WHERE tasks_fts MATCH ?1 AND task_lists.workspaceId = ?2
           AND (?3 OR tasks.status = 'open')
           AND (?4 OR task_lists.isArchived = 0)
         ORDER BY bm25(tasks_fts, 10.0, 1.0)
         LIMIT ?5",
        TaskRow::COLUMNS
    );
    let mut statement = connection.prepare_cached(&sql)?;
    let rows = statement.query_map(
        rusqlite::params![
            pattern,
            workspace_id,
            including_completed,
            including_archived_lists,
            limit
        ],
        |row| {
            Ok((
                TaskRow::from_row(row)?,
                row.get::<_, Option<String>>("notesSnippet")?,
            ))
        },
    )?;
    let mut lists: HashMap<String, Option<ListRow>> = HashMap::new();
    let mut hits = Vec::new();
    for row in rows {
        let (task, snippet) = row?;
        if !lists.contains_key(&task.list_id) {
            lists.insert(task.list_id.clone(), list(connection, &task.list_id)?);
        }
        let Some(Some(found)) = lists.get(&task.list_id) else {
            continue;
        };
        hits.push(SearchHit {
            list: found.clone(),
            notes_snippet: snippet
                .map(|text| text.trim().to_string())
                .filter(|text| !text.is_empty()),
            task,
        });
    }
    Ok(hits)
}

#[cfg(test)]
mod tests;
