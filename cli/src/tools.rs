//! The Takt tools, implemented once.
//!
//! Both front ends — the CLI subcommands in `cli.rs` and the MCP server in
//! `mcp.rs` — dispatch through [`Tools::call`], so the two cannot drift from
//! each other. Anything a client can ask for over MCP is reachable from the
//! command line with the same arguments and the same answer, by construction
//! rather than by discipline.
//!
//! These are also the app's tools. Takt ships this binary as its MCP
//! server, so there is no second implementation to keep in step any more —
//! which is what retired `scripts/mcp_parity_check.py`. See `cli/src/mcp.rs`.

use crate::checkvist::CheckvistClient;
use crate::error::{Result, ToolError};
use crate::local::LocalState;
use crate::workspace::Workspace;
use chrono::Local;
use serde_json::{Map, Value, json};

#[derive(Debug)]
pub struct ToolOutcome {
    pub title: String,
    pub payload: Value,
}

pub struct Tools {
    pub client: CheckvistClient,
    pub local: LocalState,
    /// The app's own database. The focus reads are read-only; the task tree
    /// is written under the app's undo journal (`workspace_tasks.rs`).
    pub workspace: Workspace,
}

impl Tools {
    pub fn call(&self, name: &str, arguments: &Map<String, Value>) -> Result<ToolOutcome> {
        let list_id = || {
            self.client
                .resolve_list_id(as_string(arguments.get("list_id")).as_deref())
        };

        match name {
            "task_lists" => Ok(outcome("Checklists", json!(self.client.list_lists()?))),

            "task_fetch" => {
                let list_id = list_id()?;
                let include_closed = as_bool(arguments.get("include_closed"), false)?;
                let with_notes = as_bool(arguments.get("with_notes"), true)?;
                let payload = self
                    .client
                    .fetch_tasks(&list_id, include_closed, with_notes)?;
                Ok(outcome(
                    format!("Tasks (list {list_id}, include_closed={include_closed})"),
                    json!(payload),
                ))
            }

            "task_add" => {
                let content = required_string(arguments, "content")?;
                let location =
                    as_string(arguments.get("location")).unwrap_or_else(|| "default".into());
                if !matches!(location.as_str(), "default" | "specific") {
                    return Err(ToolError::new("location must be 'default' or 'specific'."));
                }
                let list_id = list_id()?;
                let parent_task_id = if location == "specific" {
                    Some(required_int(arguments, "parent_task_id")?)
                } else {
                    None
                };
                let position = as_optional_int(arguments.get("position"))?.or(Some(1));
                let due = as_string(arguments.get("due"));
                let payload = self.client.create_task(
                    &list_id,
                    content.trim(),
                    parent_task_id,
                    position,
                    due.as_deref(),
                )?;
                Ok(outcome("Task created", payload))
            }

            "task_update" => {
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                let content = as_string(arguments.get("content"));
                let due = as_string(arguments.get("due"));
                let tags = as_string(arguments.get("tags"));
                let payload = self.client.update_task(
                    &list_id,
                    task_id,
                    content.as_deref(),
                    due.as_deref(),
                    tags.as_deref(),
                )?;
                Ok(outcome("Task updated", payload))
            }

            "task_complete" | "task_reopen" | "task_invalidate" => {
                let (action, title) = match name {
                    "task_complete" => ("close", "Task completed"),
                    "task_reopen" => ("reopen", "Task reopened"),
                    _ => ("invalidate", "Task invalidated"),
                };
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                Ok(outcome(
                    title,
                    self.client.task_action(&list_id, task_id, action)?,
                ))
            }

            "task_delete" => {
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                Ok(outcome(
                    "Task deleted",
                    self.client.delete_task(&list_id, task_id)?,
                ))
            }

            "task_move" => {
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                let position = required_int(arguments, "position")?;
                if position < 1 {
                    return Err(ToolError::new("position must be 1 or greater."));
                }
                Ok(outcome(
                    "Task moved",
                    self.client.move_task(&list_id, task_id, position)?,
                ))
            }

            "task_reparent" => {
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                // Absent means "move to root". 0 means the same, so a client
                // that cannot express null still has a way to say it.
                let parent_id = match as_optional_int(arguments.get("parent_task_id"))? {
                    None | Some(0) => None,
                    Some(parent_id) => Some(parent_id),
                };
                if parent_id == Some(task_id) {
                    return Err(ToolError::new("A task cannot be its own parent."));
                }
                Ok(outcome(
                    "Task reparented",
                    self.client.reparent_task(&list_id, task_id, parent_id)?,
                ))
            }

            "project_move" => {
                let source_list_id = required_string(arguments, "source_list_id")?;
                let target_list_id = required_string(arguments, "target_list_id")?;
                let task_id = required_int(arguments, "task_id")?;
                Ok(outcome(
                    "Project moved",
                    self.client
                        .move_project_to_list(&source_list_id, &target_list_id, task_id)?,
                ))
            }

            "task_note_add" => {
                let list_id = list_id()?;
                let task_id = required_int(arguments, "task_id")?;
                let note = required_string(arguments, "note")?;
                Ok(outcome(
                    "Note added",
                    self.client.add_note(&list_id, task_id, &note)?,
                ))
            }

            "list_create" => {
                let name = required_string(arguments, "name")?;
                Ok(outcome("List created", self.client.create_list(&name)?))
            }

            "task_search" => {
                // 0 reads as "unset", as `days` does elsewhere here; anything
                // below that is a request for a negative number of results.
                // Checked before the fetch, so a bad call costs no request.
                let limit = as_optional_int(arguments.get("limit"))?
                    .filter(|n| *n != 0)
                    .unwrap_or(50);
                if limit < 1 {
                    return Err(ToolError::new("limit must be 1 or greater."));
                }
                let shown = limit as usize;
                let list_id = list_id()?;
                let include_closed = as_bool(arguments.get("include_closed"), false)?;
                let tasks = self.client.fetch_tasks(&list_id, include_closed, false)?;
                let matches = filter_tasks(
                    tasks,
                    as_string(arguments.get("query")).as_deref(),
                    as_string(arguments.get("tag")).as_deref(),
                    as_string(arguments.get("due_before")).as_deref(),
                );
                let suffix = if matches.len() > shown {
                    format!(", showing {limit}")
                } else {
                    String::new()
                };
                let title = format!(
                    "Search (list {list_id}, {} match(es){suffix})",
                    matches.len()
                );
                Ok(outcome(
                    title,
                    json!(matches.into_iter().take(shown).collect::<Vec<_>>()),
                ))
            }

            "daily_log_fetch" => {
                let days = as_optional_int(arguments.get("days"))?
                    .filter(|n| *n != 0)
                    .unwrap_or(1);
                if !(1..=90).contains(&days) {
                    return Err(ToolError::new("days must be between 1 and 90."));
                }
                let payload = self.local.day_summaries(Local::now(), days);
                Ok(outcome(
                    format!("Daily log ({days} day(s))"),
                    json!(payload),
                ))
            }

            "dailies_list" => Ok(outcome(
                "Dailies",
                self.local.dailies_snapshot(Local::now()),
            )),

            "task_metadata" => {
                let list_id = list_id()?;
                let payload = self.local.task_metadata(&list_id);
                Ok(outcome(format!("Takt metadata (list {list_id})"), payload))
            }

            "task_matrix_set" => {
                let list_id = list_id()?;
                let entries = arguments
                    .get("placements")
                    .and_then(Value::as_array)
                    .ok_or_else(|| ToolError::new("placements must be an array."))?;
                let mut placements = Vec::with_capacity(entries.len());
                for entry in entries {
                    let number = |key: &str| entry.get(key).and_then(Value::as_f64);
                    let task_id = entry
                        .get("task_id")
                        .and_then(Value::as_i64)
                        .ok_or_else(|| ToolError::new("each placement needs a task_id."))?;
                    let (Some(urgency), Some(importance)) =
                        (number("urgency"), number("importance"))
                    else {
                        return Err(ToolError::new(
                            "each placement needs urgency and importance.",
                        ));
                    };
                    placements.push((task_id, urgency, importance));
                }
                Ok(outcome(
                    "Matrix updated",
                    self.local.set_eisenhower_levels(&list_id, &placements)?,
                ))
            }

            "daily_add" => {
                let title = required_string(arguments, "title")?;
                let weekdays = as_optional_weekdays(arguments.get("active_weekdays"))?;
                let interval = as_optional_interval(arguments.get("interval_days"))?;
                reject_both_schedules(weekdays.as_ref(), interval)?;
                Ok(outcome(
                    "Daily added",
                    self.local.add_daily(&title, weekdays, interval)?,
                ))
            }

            "daily_update" => {
                let daily_id = required_string(arguments, "daily_id")?;
                let title = as_string(arguments.get("title"));
                let weekdays = as_optional_weekdays(arguments.get("active_weekdays"))?;
                let interval = as_optional_interval(arguments.get("interval_days"))?;
                reject_both_schedules(weekdays.as_ref(), interval)?;
                let archived = match arguments.get("archived") {
                    None | Some(Value::Null) => None,
                    value => Some(as_bool(value, false)?),
                };
                if title.is_none() && weekdays.is_none() && interval.is_none() && archived.is_none()
                {
                    return Err(ToolError::new(
                        "No updates provided. Pass title, active_weekdays, interval_days and/or archived.",
                    ));
                }
                let payload = self.local.update_daily(
                    &daily_id,
                    title.as_deref(),
                    weekdays,
                    archived,
                    interval,
                )?;
                Ok(outcome("Daily updated", payload))
            }

            "daily_tick" => {
                let daily_id = required_string(arguments, "daily_id")?;
                let done = as_bool(arguments.get("done"), true)?;
                let payload = self.local.set_daily(&daily_id, done)?;
                let title = if payload.get("changed") == Some(&Value::Bool(true)) {
                    if done {
                        "Daily ticked"
                    } else {
                        "Daily un-ticked"
                    }
                } else {
                    "Daily already in that state"
                };
                Ok(outcome(title, payload))
            }

            // -- the app's workspace, read-only ------------------------------
            "focus_status" => {
                let payload = self.workspace.focus_status(chrono::Utc::now())?;
                let title = if payload["running"] == Value::Bool(true) {
                    if payload["paused"] == Value::Bool(true) {
                        "Focus paused"
                    } else {
                        "Focus running"
                    }
                } else {
                    "No focus session"
                };
                Ok(outcome(title, payload))
            }

            "focus_history" => {
                let days = as_optional_int(arguments.get("days"))?
                    .filter(|n| *n != 0)
                    .unwrap_or(1);
                if !(1..=90).contains(&days) {
                    return Err(ToolError::new("days must be between 1 and 90."));
                }
                // Logical days, so a block worked at one in the morning counts
                // towards the evening it belonged to rather than the next day.
                let now = Local::now();
                let until = self.local.logical_day(now) + chrono::Duration::days(1);
                let since = until - chrono::Duration::days(days);
                let payload = self.workspace.focus_history(since, until)?;
                Ok(outcome(format!("Focused time ({days} day(s))"), payload))
            }

            // -- the app's local task tree, read and written ------------------
            "workspace_tree" => {
                let include_archived = as_bool(arguments.get("include_archived"), false)?;
                Ok(outcome(
                    "Workspace folders and lists",
                    self.workspace.tree(include_archived)?,
                ))
            }

            "workspace_tasks" => {
                let list_id = required_string(arguments, "list_id")?;
                let parent = as_id(arguments.get("parent_task_id"));
                let include_closed = as_bool(arguments.get("include_closed"), false)?;
                let payload = self
                    .workspace
                    .tasks(&list_id, parent.as_deref(), include_closed)?;
                let title = format!(
                    "Tasks in \"{}\" ({} shown)",
                    payload["list"]["name"].as_str().unwrap_or(&list_id),
                    payload["task_count"]
                );
                Ok(outcome(title, payload))
            }

            "workspace_task_add" => {
                let parent_task_id = as_id(arguments.get("parent_task_id"));
                // The parent names its own list, so either is enough.
                let list_id = match (as_id(arguments.get("list_id")), &parent_task_id) {
                    (Some(list_id), _) => list_id,
                    (None, Some(parent)) => self.workspace.list_of_task(parent)?,
                    (None, None) => {
                        return Err(ToolError::new(
                            "Missing required argument: list_id (or a parent_task_id).",
                        ));
                    }
                };
                let task = crate::workspace_tasks::NewTask {
                    list_id,
                    title: required_string(arguments, "title")?,
                    parent_task_id,
                    notes: as_string(arguments.get("notes")).unwrap_or_default(),
                    external_links: as_string_list(arguments.get("external_links"))?
                        .unwrap_or_default(),
                    kanban_column: as_string(arguments.get("kanban_column")),
                    kind: as_string(arguments.get("kind")).unwrap_or_else(|| "task".into()),
                    at_top: as_bool(arguments.get("at_top"), false)?,
                };
                Ok(outcome("Task created", self.workspace.add_task(task)?))
            }

            "workspace_task_update" => {
                let task_id = required_string(arguments, "task_id")?;
                let edit = crate::workspace_tasks::TaskEdit {
                    title: as_string(arguments.get("title")),
                    notes: as_string(arguments.get("notes")),
                    external_links: as_string_list(arguments.get("external_links"))?,
                    status: as_string(arguments.get("status")).map(|s| s.trim().to_lowercase()),
                    // Present-but-null clears the column; absent leaves it.
                    kanban_column: arguments
                        .get("kanban_column")
                        .map(|value| as_string(Some(value))),
                    kind: as_string(arguments.get("kind")).map(|s| s.trim().to_lowercase()),
                    pinned: match arguments.get("pinned") {
                        None | Some(Value::Null) => None,
                        value => Some(as_bool(value, false)?),
                    },
                    // Present-but-null (or empty) clears; absent leaves it.
                    waiting_on: arguments
                        .get("waiting_on")
                        .map(|value| as_string(Some(value))),
                    follow_up_at: arguments
                        .get("follow_up_at")
                        .map(|value| as_string(Some(value))),
                };
                Ok(outcome(
                    "Task updated",
                    self.workspace.update_task(&task_id, edit)?,
                ))
            }

            "workspace_task_move" => {
                let task_id = required_string(arguments, "task_id")?;
                let parent = as_id(arguments.get("parent_task_id"));
                let list_id = as_id(arguments.get("list_id"));
                let position = as_optional_int(arguments.get("position"))?;
                Ok(outcome(
                    "Task moved",
                    self.workspace.move_task(
                        &task_id,
                        parent.as_deref(),
                        list_id.as_deref(),
                        position,
                    )?,
                ))
            }

            "workspace_task_to_list" => {
                let task_id = required_string(arguments, "task_id")?;
                let folder_id = as_id(arguments.get("folder_id"));
                Ok(outcome(
                    "Task promoted to its own list",
                    self.workspace
                        .task_to_list(&task_id, folder_id.as_deref())?,
                ))
            }

            "workspace_task_delete" => {
                let task_id = required_string(arguments, "task_id")?;
                Ok(outcome(
                    "Task deleted",
                    self.workspace.delete_task(&task_id)?,
                ))
            }

            "workspace_folder_create" => {
                let name = required_string(arguments, "name")?;
                let parent = as_id(arguments.get("parent_folder_id"));
                Ok(outcome(
                    "Folder created",
                    self.workspace.create_folder(&name, parent.as_deref())?,
                ))
            }

            "workspace_list_create" => {
                let name = required_string(arguments, "name")?;
                let folder_id = as_id(arguments.get("folder_id"));
                Ok(outcome(
                    "List created",
                    self.workspace.create_list(&name, folder_id.as_deref())?,
                ))
            }

            "workspace_list_move" => {
                let list_id = required_string(arguments, "list_id")?;
                let folder_id = as_id(arguments.get("folder_id"));
                Ok(outcome(
                    "List moved",
                    self.workspace.move_list(&list_id, folder_id.as_deref())?,
                ))
            }

            "workspace_list_delete" => {
                let list_id = required_string(arguments, "list_id")?;
                Ok(outcome(
                    "List deleted",
                    self.workspace.delete_list(&list_id)?,
                ))
            }

            _ => Err(ToolError::new(format!("Unknown tool: {name}"))),
        }
    }
}

/// A workspace id, where empty means absent: a client that cannot send null
/// can still say "top level" or "no parent".
pub fn as_id(value: Option<&Value>) -> Option<String> {
    as_string(value)
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

/// An array of strings. A bare string is taken as a one-item list, since that
/// is what a client means by `"external_links": "https://…"`.
pub fn as_string_list(value: Option<&Value>) -> Result<Option<Vec<String>>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(vec![text.clone()])),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| match item {
                Value::String(text) => Ok(text.clone()),
                other => Err(ToolError::new(format!(
                    "Expected an array of strings, found {}.",
                    type_name(other)
                ))),
            })
            .collect::<Result<Vec<_>>>()
            .map(Some),
        Some(other) => Err(ToolError::new(format!(
            "Expected an array of strings, got {}.",
            type_name(other)
        ))),
    }
}

fn outcome(title: impl Into<String>, payload: Value) -> ToolOutcome {
    ToolOutcome {
        title: title.into(),
        payload,
    }
}

/// Filtering runs here rather than in the caller so a search over a large list
/// costs one result instead of the whole list. All three filters are ANDed;
/// omitting one drops it.
pub fn filter_tasks(
    tasks: Vec<Value>,
    query: Option<&str>,
    tag: Option<&str>,
    due_before: Option<&str>,
) -> Vec<Value> {
    let mut matches = tasks;

    if let Some(query) = query.map(str::trim).filter(|q| !q.is_empty()) {
        let needle = query.to_lowercase();
        matches.retain(|task| content_of(task).to_lowercase().contains(&needle));
    }

    if let Some(tag) = tag.map(str::trim).filter(|t| !t.is_empty()) {
        let normalized = tag.trim_start_matches('#').to_lowercase();
        matches.retain(|task| has_tag(task, &normalized));
    }

    if let Some(cutoff) = due_before.map(str::trim).filter(|d| !d.is_empty()) {
        // Checkvist serialises `due` as YYYY-MM-DD, which compares correctly as
        // a string. A task with no due date is never "due before" anything.
        matches.retain(|task| {
            let due = task.get("due").and_then(Value::as_str).unwrap_or("");
            !due.is_empty() && due < cutoff
        });
    }

    matches
}

fn content_of(task: &Value) -> String {
    task.get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Checkvist returns tags as an array or a dict depending on the endpoint, and
/// also inline in the content as `#tag` — match any, rather than silently
/// missing half the tagged tasks.
fn has_tag(task: &Value, normalized: &str) -> bool {
    let in_tags = match task.get("tags") {
        Some(Value::Array(items)) => items
            .iter()
            .any(|item| value_text(item).to_lowercase() == normalized),
        Some(Value::Object(entries)) => entries.keys().any(|key| key.to_lowercase() == normalized),
        _ => false,
    };
    in_tags
        || content_of(task)
            .to_lowercase()
            .contains(&format!("#{normalized}"))
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

// -- argument coercion -------------------------------------------------------
//
// Tolerant where clients are loose: one that sends `"5"` where the schema
// says integer, or `"true"` where it says boolean, is answered rather than
// rejected. Booleans are the one place tolerance is wrong — a bug in the
// app's former in-process server accepted JSON `1` as `true` and so rejected
// `position: 1` outright.

pub fn as_string(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::Null => None,
        Value::String(text) => Some(text.clone()),
        Value::Bool(flag) => Some(if *flag { "True".into() } else { "False".into() }),
        other => Some(other.to_string()),
    }
}

pub fn as_bool(value: Option<&Value>, default: bool) -> Result<bool> {
    match value {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Bool(flag)) => Ok(*flag),
        Some(Value::String(text)) => match text.trim().to_lowercase().as_str() {
            "true" | "1" | "yes" | "y" => Ok(true),
            "false" | "0" | "no" | "n" => Ok(false),
            _ => Err(ToolError::new(format!(
                "Expected boolean value, got {text:?}."
            ))),
        },
        Some(Value::Number(number)) => number
            .as_i64()
            .map(|raw| raw != 0)
            .ok_or_else(|| ToolError::new("Expected boolean value, got a fractional number.")),
        Some(other) => Err(ToolError::new(format!(
            "Expected boolean value, got {}.",
            type_name(other)
        ))),
    }
}

pub fn as_optional_int(value: Option<&Value>) -> Result<Option<i64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        // Not merged with the number arm: in JSON a boolean is its own type,
        // and coercing it to 0/1 is what made `position: 1` unusable before.
        Some(Value::Bool(_)) => Err(ToolError::new("Boolean value is not a valid integer.")),
        Some(Value::Number(number)) => number
            .as_i64()
            .map(Some)
            .ok_or_else(|| ToolError::new(format!("Expected integer value, got {number}."))),
        Some(Value::String(text)) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return Ok(None);
            }
            trimmed
                .parse::<i64>()
                .map(Some)
                .map_err(|_| ToolError::new(format!("Invalid integer value: {text}")))
        }
        Some(other) => Err(ToolError::new(format!(
            "Expected integer value, got {}.",
            type_name(other)
        ))),
    }
}

/// `Calendar` weekday numbering, 1 = Sunday, matching `Daily.activeWeekdays`.
pub fn as_optional_weekdays(value: Option<&Value>) -> Result<Option<Vec<i64>>> {
    let value = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(value) => value,
    };
    let Value::Array(items) = value else {
        return Err(ToolError::new(
            "active_weekdays must be an array of integers 1-7.",
        ));
    };

    let mut weekdays: Vec<i64> = Vec::new();
    for item in items {
        let day = match item {
            Value::Number(number) => number.as_i64(),
            _ => None,
        }
        .filter(|day| (1..=7).contains(day))
        .ok_or_else(|| {
            ToolError::new("active_weekdays entries must be integers 1-7 (1 = Sunday).")
        })?;
        if !weekdays.contains(&day) {
            weekdays.push(day);
        }
    }
    if weekdays.is_empty() {
        return Err(ToolError::new("active_weekdays must not be empty."));
    }
    weekdays.sort_unstable();
    Ok(Some(weekdays))
}

/// Length of a rotating cycle, matching `Daily.intervalDays`.
pub fn as_optional_interval(value: Option<&Value>) -> Result<Option<i64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => match value.as_i64().filter(|days| (1..=366).contains(days)) {
            Some(days) => Ok(Some(days)),
            None => Err(ToolError::new(
                "interval_days must be an integer between 1 and 366.",
            )),
        },
    }
}

/// The two schedules are alternatives, not filters that compose, so being
/// handed both is a question with no answer — better refused than silently
/// resolved in favour of whichever the implementation checks first.
pub fn reject_both_schedules(weekdays: Option<&Vec<i64>>, interval: Option<i64>) -> Result<()> {
    if weekdays.is_some() && interval.is_some() {
        return Err(ToolError::new(
            "Pass either active_weekdays or interval_days, not both.",
        ));
    }
    Ok(())
}

pub fn required_string(arguments: &Map<String, Value>, key: &str) -> Result<String> {
    as_string(arguments.get(key))
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| ToolError::new(format!("Missing required argument: {key}")))
}

pub fn required_int(arguments: &Map<String, Value>, key: &str) -> Result<i64> {
    as_optional_int(arguments.get(key))?
        .ok_or_else(|| ToolError::new(format!("Missing required argument: {key}")))
}

fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}
