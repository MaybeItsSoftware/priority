//! The whole workspace written out to a file, for a backup or another app.
//!
//! Every list, archived included, in the sidebar's order, each with its whole
//! task tree depth first in the outline's order, as Markdown or as JSON. It
//! is read and written here in one call, so no row crosses to a client.
//!
//! The bytes are the ones the Mac wrote before the export moved here, from
//! `Encodable` models through Foundation's `JSONEncoder` with
//! `.prettyPrinted, .sortedKeys` and `.iso8601` dates: two-space indent,
//! `"key" : value`, keys in order, a nil field left out, `/` escaped as
//! `\/`, an empty array as `[`, a blank line, `]`, dates to the whole second
//! (rounded down) in UTC, no trailing newline. `workspace.json` and
//! `workspace.md` beside this file were written by the Mac.

use rusqlite::Connection;

use crate::CoreError;
use crate::records::{self, ListRow, TaskRow};
use crate::theme::json::{self, Json};
use crate::workspace::CoreWorkspace;

/// The two formats the workspace is written out in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExportFormat {
    Markdown,
    Json,
}

/// One list and its whole task tree, depth first, each task with its depth.
struct ExportedList {
    list: ListRow,
    tasks: Vec<(TaskRow, usize)>,
}

#[uniffi::export]
impl CoreWorkspace {
    /// The workspace `workspace_id` written out as `format`, stamped
    /// `exported_at_ms`; absent when there is no such workspace.
    pub fn export_workspace(
        &self,
        workspace_id: String,
        format: ExportFormat,
        exported_at_ms: i64,
    ) -> Result<Option<String>, CoreError> {
        export(&self.read(), &workspace_id, format, exported_at_ms)
    }
}

/// `CoreWorkspace::export_workspace` on a connection, read in one
/// transaction so the document is one moment's workspace.
pub fn export(
    connection: &Connection,
    workspace_id: &str,
    format: ExportFormat,
    exported_at_ms: i64,
) -> Result<Option<String>, CoreError> {
    let transaction = connection.unchecked_transaction()?;
    let Some(workspace) = records::workspaces(&transaction)?
        .into_iter()
        .find(|workspace| workspace.id == workspace_id)
    else {
        return Ok(None);
    };
    let lists = records::lists(&transaction, workspace_id, true)?
        .into_iter()
        .map(|list| {
            let mut tasks = Vec::new();
            walk(&transaction, &list.id, None, 0, &mut tasks)?;
            Ok(ExportedList { list, tasks })
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    transaction.finish()?;
    Ok(Some(match format {
        ExportFormat::Json => document_json(exported_at_ms, &workspace.name, &lists),
        ExportFormat::Markdown => markdown(&workspace.name, &lists),
    }))
}

/// Depth first, in the outline's own order, so the file reads top to bottom
/// the way the list does. A task whose parent is not in the list is not
/// reached, as it never was.
fn walk(
    connection: &Connection,
    list_id: &str,
    parent: Option<&str>,
    depth: usize,
    out: &mut Vec<(TaskRow, usize)>,
) -> Result<(), CoreError> {
    for task in records::children(connection, list_id, parent)? {
        let id = task.id.clone();
        out.push((task, depth));
        walk(connection, list_id, Some(&id), depth + 1, out)?;
    }
    Ok(())
}

fn markdown(workspace: &str, lists: &[ExportedList]) -> String {
    let mut lines = vec![format!("# {workspace}"), String::new()];
    for entry in lists {
        let suffix = if entry.list.is_archived {
            " (archived)"
        } else {
            ""
        };
        lines.push(format!("## {}{suffix}", entry.list.name));
        lines.push(String::new());
        for (task, depth) in &entry.tasks {
            let box_ = if task.status == "open" { "[ ]" } else { "[x]" };
            let indent = "  ".repeat(*depth);
            lines.push(format!("{indent}- {box_} {}", task.title));
            for note in note_lines(&task.notes) {
                lines.push(format!("{indent}  > {note}"));
            }
        }
        lines.push(String::new());
    }
    lines.join("\n")
}

/// The notes' non-empty lines, split the way Swift's
/// `split(separator: "\n")` splits: by `Character`, and `\r\n` is one
/// character that is not `\n`, so a Windows line ending does not split.
fn note_lines(notes: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let bytes = notes.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' && (index == 0 || bytes[index - 1] != b'\r') {
            lines.push(&notes[start..index]);
            start = index + 1;
        }
    }
    lines.push(&notes[start..]);
    lines.retain(|line| !line.is_empty());
    lines
}

fn document_json(exported_at_ms: i64, workspace: &str, lists: &[ExportedList]) -> String {
    let lists = lists
        .iter()
        .map(|entry| {
            Json::object([
                ("list", Some(list_json(&entry.list))),
                (
                    "tasks",
                    Some(Json::Array(
                        entry
                            .tasks
                            .iter()
                            .map(|(task, _)| task_json(task))
                            .collect(),
                    )),
                ),
            ])
        })
        .collect();
    let document = Json::object([
        ("exportedAt", Some(date(exported_at_ms))),
        ("lists", Some(Json::Array(lists))),
        ("workspace", Some(text(workspace))),
    ]);
    // Every number is an integer, so the writer cannot refuse it.
    json::pretty_escaping_slashes(&document).unwrap_or_default()
}

fn list_json(list: &ListRow) -> Json {
    Json::object([
        ("colorHex", list.color_hex.as_deref().map(text)),
        ("completedAt", list.completed_at_ms.map(date)),
        ("createdAt", Some(date(list.created_at_ms))),
        ("folderId", list.folder_id.as_deref().map(text)),
        ("id", Some(text(&list.id))),
        ("isArchived", Some(Json::Bool(list.is_archived))),
        ("name", Some(text(&list.name))),
        ("sortOrder", Some(Json::Integer(list.sort_order))),
        ("systemRole", list.system_role.as_deref().map(text)),
        ("updatedAt", Some(date(list.updated_at_ms))),
        (
            "visibleRootTaskId",
            list.visible_root_task_id.as_deref().map(text),
        ),
        ("workspaceId", Some(text(&list.workspace_id))),
    ])
}

fn task_json(task: &TaskRow) -> Json {
    Json::object([
        ("archivedAt", task.archived_at_ms.map(date)),
        ("completedAt", task.completed_at_ms.map(date)),
        ("createdAt", Some(date(task.created_at_ms))),
        ("dueAt", task.due_at_ms.map(date)),
        ("estimateSeconds", task.estimate_seconds.map(Json::Integer)),
        ("id", Some(text(&task.id))),
        ("isPromoted", task.is_promoted.map(Json::Bool)),
        ("itemKind", task.item_kind.as_deref().map(text)),
        ("listId", Some(text(&task.list_id))),
        ("notes", Some(text(&task.notes))),
        ("parentTaskId", task.parent_task_id.as_deref().map(text)),
        ("sortOrder", Some(Json::Integer(task.sort_order))),
        ("sourceId", task.source_id.as_deref().map(text)),
        ("sourceSystem", task.source_system.as_deref().map(text)),
        ("status", Some(text(&task.status))),
        ("title", Some(text(&task.title))),
        ("updatedAt", Some(date(task.updated_at_ms))),
    ])
}

fn text(value: &str) -> Json {
    Json::String(value.to_string())
}

/// `.iso8601` as `JSONEncoder` writes it: UTC, to the second, the fraction
/// dropped rather than rounded, so -1.5 s is `1969-12-31T23:59:58Z`.
fn date(ms: i64) -> Json {
    let seconds = ms.div_euclid(1000);
    let text = chrono::DateTime::from_timestamp(seconds, 0)
        .map(|at| at.format("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_default();
    Json::String(text)
}

#[cfg(test)]
mod tests;
