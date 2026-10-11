//! A board's columns: read, added to or edited, and deleted.
//!
//! The layouts, their resolution (a list's own, else the workspace default,
//! else the stock five) and every write are the Rust core's
//! (`core/src/board_columns.rs`), the same functions the apps call. This
//! adds the CLI's JSON and finding a board by list.

use super::{map_core_error, non_empty, workspace_row};
use crate::error::{Result, ToolError};
use crate::workspace::Workspace;
use chrono::Utc;
use rusqlite::Connection;
use serde_json::{Value, json};
use takt_core::board_columns::{
    self as core, BoardColumn, BoardColumns, DEFAULT_BOARD_KEY, EVERYTHING_BOARD_KEY,
};
use takt_core::filter_lists::{FilterDefinition, FilterRule, describe_filter_definition};

/// What a column edit changes; `None` leaves a part as it is.
#[derive(Default)]
pub struct ColumnEdit {
    pub title: Option<String>,
    /// "all" or "any", for the rules.
    pub match_mode: Option<String>,
    /// Replaces the rules; an empty set makes it an ordinary column.
    pub rules: Option<Vec<FilterRule>>,
    /// Where a new column goes: an index among the board's columns.
    pub position: Option<usize>,
}

/// The board a tool names: a list's, Everything's ("everything") or the
/// workspace default ("default"), as its `kanban_boards` key and the lists
/// it draws from.
fn board(connection: &Connection, board: Option<&str>) -> Result<(String, Vec<String>)> {
    let (workspace_id, _) = workspace_row(connection)?;
    match board.map(str::trim).filter(|board| !board.is_empty()) {
        None | Some("everything") => Ok((
            EVERYTHING_BOARD_KEY.to_string(),
            takt_core::filter_lists::scope_list_ids(connection, &workspace_id)
                .map_err(map_core_error)?,
        )),
        Some("default") => Ok((DEFAULT_BOARD_KEY.to_string(), Vec::new())),
        Some(list_id) => {
            let exists: bool = connection
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM task_lists WHERE id = ?1)",
                    [list_id],
                    |row| row.get(0),
                )
                .map_err(|error| ToolError::new(error.to_string()))?;
            if !exists {
                return Err(ToolError::new(format!(
                    "No list with id {list_id}. Pass a list id, everything or default."
                )));
            }
            Ok((format!("{list_id}/root"), vec![list_id.to_string()]))
        }
    }
}

fn read(connection: &Connection, key: &str, list_ids: &[String]) -> Result<BoardColumns> {
    let zone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".into());
    core::board_columns(
        connection,
        key,
        list_ids,
        Utc::now().timestamp_millis(),
        &zone,
    )
    .map_err(map_core_error)
}

fn column_json(column: &BoardColumn, hidden: &[String]) -> Value {
    let mut value = json!({ "id": column.id, "title": column.title });
    if let Some(rules) = &column.rules {
        value["rules"] = json!({
            "match": rules.match_mode,
            "rules": rules.rules.iter().map(|rule| json!({
                "field": rule.field, "op": rule.op, "value": rule.value,
            })).collect::<Vec<_>>(),
            "reads": describe_filter_definition(rules.clone()),
        });
    }
    if hidden.contains(&column.id) {
        value["hidden"] = json!(true);
    }
    value
}

fn layout_json(read: &BoardColumns) -> Value {
    json!({
        "board": read.key,
        "source": read.source,
        "columns": read.layout.iter().map(|column| column_json(column, &read.hidden_column_ids)).collect::<Vec<_>>(),
    })
}

/// An id from a title, unique among `columns`: `waiting-on`, `waiting-on-2`.
fn unique_id(title: &str, columns: &[BoardColumn]) -> String {
    let mut base: String = title
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    while base.contains("--") {
        base = base.replace("--", "-");
    }
    let base = base.trim_matches('-');
    let base = if base.is_empty() { "column" } else { base };
    if !columns.iter().any(|column| column.id == base) {
        return base.to_string();
    }
    (2..)
        .map(|n| format!("{base}-{n}"))
        .find(|id| !columns.iter().any(|column| &column.id == id))
        .expect("an unused id")
}

impl Workspace {
    /// A board's columns as the core resolves them, rules included.
    pub fn board_columns(&self, board_name: Option<&str>) -> Result<Value> {
        let connection = self.open()?;
        let (key, list_ids) = board(&connection, board_name)?;
        Ok(layout_json(&read(&connection, &key, &list_ids)?))
    }

    /// Adds a column, or renames one or sets its rules, as one step. A board
    /// following the default gets columns of its own.
    pub fn set_board_column(
        &self,
        board_name: Option<&str>,
        column_id: Option<&str>,
        edit: ColumnEdit,
    ) -> Result<Value> {
        let title = edit
            .title
            .as_deref()
            .map(|title| non_empty(title, "title"))
            .transpose()?;
        let label = if column_id.is_some() {
            "Edit Board Column"
        } else {
            "Add Board Column"
        };
        self.journalled(label, |tx, _now| {
            let (key, list_ids) = board(tx, board_name)?;
            let mut columns = read(tx, &key, &list_ids)?.layout;
            let index = match column_id.map(str::trim) {
                Some(id) => columns
                    .iter()
                    .position(|column| column.id == id)
                    .ok_or_else(|| ToolError::new(format!("No column {id} on that board.")))?,
                None => {
                    let title = title
                        .clone()
                        .ok_or_else(|| ToolError::new("A new column needs a title."))?;
                    let column = BoardColumn {
                        id: unique_id(&title, &columns),
                        title,
                        rules: None,
                    };
                    let at = edit.position.unwrap_or(columns.len()).min(columns.len());
                    columns.insert(at, column);
                    at
                }
            };
            let column = &mut columns[index];
            if let Some(title) = &title {
                column.title = title.clone();
            }
            if edit.rules.is_some() || edit.match_mode.is_some() {
                let base = column.rules.clone().unwrap_or(FilterDefinition {
                    show: "all".into(),
                    ..FilterDefinition::default()
                });
                let rules = edit.rules.clone().unwrap_or(base.rules);
                column.rules = (!rules.is_empty()).then(|| FilterDefinition {
                    match_mode: edit
                        .match_mode
                        .as_deref()
                        .map(|mode| mode.trim().to_lowercase())
                        .unwrap_or(base.match_mode),
                    show: "all".into(),
                    rules,
                });
            }
            let id = column.id.clone();
            core::set_board_columns(tx, &key, &columns, &[], None, Utc::now().timestamp_millis())
                .map_err(map_core_error)?;
            let mut payload = layout_json(&read(tx, &key, &list_ids)?);
            payload["column_id"] = json!(id);
            Ok(payload)
        })
    }

    /// Deletes a column as one step, its filed tasks moving to `move_to` —
    /// by default the first remaining column that takes filed tasks.
    pub fn delete_board_column(
        &self,
        board_name: Option<&str>,
        column_id: &str,
        move_to: Option<&str>,
    ) -> Result<Value> {
        self.journalled("Delete Column", |tx, _now| {
            let (key, list_ids) = board(tx, board_name)?;
            let columns = read(tx, &key, &list_ids)?.layout;
            if !columns.iter().any(|column| column.id == column_id) {
                return Err(ToolError::new(format!(
                    "No column {column_id} on that board."
                )));
            }
            let target = move_to.map(str::to_string).or_else(|| {
                columns
                    .iter()
                    .find(|column| column.id != column_id && column.rules.is_none())
                    .map(|column| column.id.clone())
            });
            core::delete_board_column(
                tx,
                &key,
                &list_ids,
                column_id,
                target.as_deref(),
                Utc::now().timestamp_millis(),
            )
            .map_err(map_core_error)?;
            let mut payload = layout_json(&read(tx, &key, &list_ids)?);
            payload["deleted"] = json!(column_id);
            payload["moved_to"] = json!(target);
            Ok(payload)
        })
    }
}
