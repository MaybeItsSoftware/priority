//! Filter lists: saved rule sets asked of every task, read and edited.
//!
//! The definitions, their evaluation and every write are the Rust core's
//! (`core/src/filter_lists.rs`), the same functions the apps call, so the
//! CLI cannot disagree with the Mac about which tasks a filter list shows.
//! This adds the CLI's JSON, its refusals, and finding a list by name.
//!
//! Today and Everything are built-in definitions rather than rows: they are
//! listed and evaluated like the rest, and refused for editing.

use super::{TaskRow, has_migration, map_core_error, non_empty, task_rows, workspace_row};
use crate::error::{Result, ToolError};
use crate::workspace::Workspace;
use chrono::Utc;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use takt_core::filter_lists::{
    self as core, FilterDefinition, FilterListRow, FilterRule, builtin_filter_lists,
    describe_filter_definition, filter_rule_catalog,
};

/// What adds `filter_lists`. Before it, the read shows only the built-in
/// lists and the writes are refused.
const FILTER_LISTS_MIGRATION: &str = "v23_filter_lists";

/// A filter list's name, icon and definition as a create or an edit gives
/// them. `None` leaves a part as it is, or at its default on a create.
#[derive(Default)]
pub struct FilterEdit {
    pub name: Option<String>,
    /// `Some(None)` clears it.
    pub icon: Option<Option<String>>,
    /// "all" or "any".
    pub match_mode: Option<String>,
    /// "open", "done" or "all".
    pub show: Option<String>,
    /// Replaces the whole set.
    pub rules: Option<Vec<FilterRule>>,
}

impl FilterEdit {
    fn is_empty(&self) -> bool {
        self.name.is_none()
            && self.icon.is_none()
            && self.match_mode.is_none()
            && self.show.is_none()
            && self.rules.is_none()
    }

    /// `base` with this edit's parts over it. The core validates the result.
    fn definition_over(&self, base: &FilterDefinition) -> FilterDefinition {
        let word = |value: &Option<String>, current: &str| {
            value
                .as_deref()
                .map(|text| text.trim().to_lowercase())
                .unwrap_or_else(|| current.to_string())
        };
        FilterDefinition {
            match_mode: word(&self.match_mode, &base.match_mode),
            show: word(&self.show, &base.show),
            rules: self.rules.clone().unwrap_or_else(|| base.rules.clone()),
        }
    }
}

impl Workspace {
    /// Today and Everything, then the workspace's own in sidebar order.
    pub fn filter_lists(&self) -> Result<Value> {
        let connection = self.open()?;
        let (workspace_id, _) = workspace_row(&connection)?;
        let rows = every_filter_list(&connection, &workspace_id)?;
        Ok(json!({
            "count": rows.len(),
            "filter_lists": rows.iter().map(filter_list_json).collect::<Vec<_>>(),
        }))
    }

    /// The tasks a filter list shows, found by id or by name, in board
    /// order: list by list, each in outline order. Evaluated in this
    /// machine's time zone, as the app does.
    pub fn filter_list_tasks(&self, id_or_name: &str) -> Result<Value> {
        let connection = self.open()?;
        let (workspace_id, _) = workspace_row(&connection)?;
        let filter = find(&connection, &workspace_id, id_or_name)?;
        let zone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".into());
        // The evaluation is the Rust core's, shared with the apps.
        let matched = core::tasks(
            &connection,
            &workspace_id,
            &filter.definition,
            Utc::now().timestamp_millis(),
            &zone,
        )
        .map_err(map_core_error)?;

        let ids: Vec<&str> = matched.iter().map(|task| task.id.as_str()).collect();
        let rows = task_rows(
            &connection,
            "t.id IN (SELECT value FROM json_each(?1))",
            [json!(ids).to_string()],
        )?;
        let by_id: HashMap<&str, &TaskRow> =
            rows.iter().map(|row| (row.id.as_str(), row)).collect();
        let list_names = list_names(&connection, &workspace_id)?;
        let blocked: HashSet<String> = takt_core::dependencies::blocked_task_ids(&connection)
            .map_err(map_core_error)?
            .into_iter()
            .collect();
        let tasks: Vec<Value> = ids
            .iter()
            .filter_map(|id| by_id.get(id))
            .map(|row| {
                let mut task = row.to_json();
                task["list_name"] = json!(list_names.get(&row.list_id));
                if blocked.contains(&row.id) {
                    task["blocked"] = json!(true);
                }
                task
            })
            .collect();
        Ok(json!({
            "filter_list": filter_list_json(&filter),
            "task_count": tasks.len(),
            "tasks": tasks,
        }))
    }

    /// `filter_lists::create`, as one "New Filter List" step, at the end of
    /// the sidebar's filter lists. Without rules it shows every open task.
    pub fn create_filter_list(&self, edit: FilterEdit) -> Result<Value> {
        let name = non_empty(edit.name.as_deref().unwrap_or_default(), "name")?;
        let definition = edit.definition_over(&FilterDefinition::default());
        let icon = edit.icon.clone().flatten();
        self.journalled("New Filter List", |tx, _now| {
            require_filter_lists(tx)?;
            let (workspace_id, _) = workspace_row(tx)?;
            // The write is the Rust core's, shared with the apps.
            let row = core::create(
                tx,
                &workspace_id,
                &name,
                icon.as_deref(),
                None,
                &definition,
                Utc::now().timestamp_millis(),
            )
            .map_err(map_core_error)?;
            Ok(filter_list_json(&row))
        })
    }

    /// `filter_lists::update`, as one "Edit Filter List" step: what the edit
    /// names changes, the rest (its colour included) stays. A no-op edit
    /// leaves no undo step.
    pub fn update_filter_list(&self, id: &str, edit: FilterEdit) -> Result<Value> {
        if edit.is_empty() {
            return Err(ToolError::new(
                "No updates provided. Pass name, icon, match, show and/or rules.",
            ));
        }
        refuse_builtin(id)?;
        let name = edit
            .name
            .as_deref()
            .map(|name| non_empty(name, "name"))
            .transpose()?;
        self.journalled("Edit Filter List", |tx, _now| {
            require_filter_lists(tx)?;
            let current = stored(tx, id)?;
            let icon = match &edit.icon {
                Some(icon) => icon.clone(),
                None => current.icon.clone(),
            };
            // The write is the Rust core's, shared with the apps.
            let row = core::update(
                tx,
                id,
                name.as_deref().unwrap_or(&current.name),
                icon.as_deref(),
                current.color_hex.as_deref(),
                &edit.definition_over(&current.definition),
                Utc::now().timestamp_millis(),
            )
            .map_err(map_core_error)?;
            Ok(filter_list_json(&row))
        })
    }

    /// `filter_lists::delete`, as one "Delete Filter List" step. No task is
    /// touched: a filter list never held any.
    pub fn delete_filter_list(&self, id: &str) -> Result<Value> {
        refuse_builtin(id)?;
        self.journalled("Delete Filter List", |tx, _now| {
            require_filter_lists(tx)?;
            let current = stored(tx, id)?;
            // The write is the Rust core's, shared with the apps.
            core::delete(tx, id).map_err(map_core_error)?;
            Ok(json!({ "deleted": current.id, "name": current.name }))
        })
    }
}

/// The rule vocabulary in one line per field, for the tool descriptions:
/// `due: overdue, within <days>, …`. Built from the core's catalog, so it
/// cannot fall behind it.
pub fn rule_catalog_text() -> String {
    filter_rule_catalog()
        .iter()
        .map(|field| {
            let ops: Vec<String> = field
                .ops
                .iter()
                .map(|op| match op.value_kind.as_str() {
                    "none" => op.op.clone(),
                    kind => format!("{} <{kind}>", op.op),
                })
                .collect();
            format!("{}: {}", field.field, ops.join(", "))
        })
        .collect::<Vec<_>>()
        .join("; ")
}

/// The field names a rule may test, for the schema's enum.
pub fn rule_fields() -> Vec<String> {
    filter_rule_catalog()
        .into_iter()
        .map(|field| field.field)
        .collect()
}

fn filter_list_json(row: &FilterListRow) -> Value {
    json!({
        "id": row.id,
        "name": row.name,
        "icon": row.icon,
        "color_hex": row.color_hex,
        "builtin": row.is_builtin,
        "summary": describe_filter_definition(row.definition.clone()),
        "match": row.definition.match_mode,
        "show": row.definition.show,
        "rules": row.definition.rules.iter().map(|rule| json!({
            "field": rule.field,
            "op": rule.op,
            "value": rule.value,
        })).collect::<Vec<_>>(),
        "sort_order": row.sort_order,
    })
}

/// The built-in lists, then the stored ones (none on a database not yet
/// migrated to v23).
fn every_filter_list(connection: &Connection, workspace_id: &str) -> Result<Vec<FilterListRow>> {
    let mut rows = builtin_filter_lists();
    rows.extend(core::filter_lists(connection, workspace_id).map_err(map_core_error)?);
    Ok(rows)
}

/// A filter list by id (`builtin:today` included), else by its name, which
/// must then be unambiguous.
fn find(connection: &Connection, workspace_id: &str, id_or_name: &str) -> Result<FilterListRow> {
    let key = id_or_name.trim();
    if let Some(row) = core::filter_list(connection, key).map_err(map_core_error)? {
        return Ok(row);
    }
    let named: Vec<FilterListRow> = every_filter_list(connection, workspace_id)?
        .into_iter()
        .filter(|row| row.name.trim().eq_ignore_ascii_case(key))
        .collect();
    match named.len() {
        1 => Ok(named.into_iter().next().expect("one")),
        0 => Err(ToolError::new(format!(
            "No filter list \"{key}\". workspace_filter_lists lists them and their ids."
        ))),
        count => Err(ToolError::new(format!(
            "{count} filter lists are called \"{key}\"; pass the id instead ({}).",
            named
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ))),
    }
}

/// A stored filter list by id.
fn stored(connection: &Connection, id: &str) -> Result<FilterListRow> {
    core::filter_list(connection, id)
        .map_err(map_core_error)?
        .filter(|row| !row.is_builtin)
        .ok_or_else(|| missing(id))
}

fn missing(id: &str) -> ToolError {
    ToolError::new(format!(
        "No filter list with id {id}. workspace_filter_lists lists them and their ids."
    ))
}

fn refuse_builtin(id: &str) -> Result<()> {
    if builtin_filter_lists().iter().any(|row| row.id == id.trim()) {
        return Err(ToolError::new(
            "Today and Everything are built in, and cannot be edited or deleted.",
        ));
    }
    Ok(())
}

fn list_names(connection: &Connection, workspace_id: &str) -> Result<HashMap<String, String>> {
    let mut names = HashMap::new();
    for list in takt_core::records::lists(connection, workspace_id, true).map_err(map_core_error)? {
        names.insert(list.id, list.name);
    }
    Ok(names)
}

/// Refuses a filter-list write on a database the app has not migrated to
/// `filter_lists` yet, rather than failing on the missing table.
fn require_filter_lists(connection: &Connection) -> Result<()> {
    if has_migration(connection, FILTER_LISTS_MIGRATION)? {
        return Ok(());
    }
    Err(ToolError::new(format!(
        "This workspace predates filter lists ({FILTER_LISTS_MIGRATION}). \
         Open an up-to-date Takt once to migrate it."
    )))
}
