//! The Checkvist API, without the network.
//!
//! The Mac's Checkvist plugin and the CLI both talk to Checkvist. Each used to
//! build its own requests and read its own answers, and they had drifted: the
//! Mac sent form bodies and the CLI JSON, the CLI sent a due date under a key
//! the API does not document, and the Mac read every note as empty because it
//! looked for `content` where Checkvist writes `comment`. This module is both
//! halves of that conversation, so there is one copy:
//!
//! * [`checkvist_request`] turns a [`CheckvistCall`] into the method, address,
//!   headers and body to send;
//! * the `checkvist_*` readers turn what came back into rows.
//!
//! Sending stays with each client, as the sync wire's does: `URLSession` on
//! the Mac, `ureq` in the CLI. So do the token and the one retry after a 401,
//! which belong to that loop, and the credentials, which live in the Mac's
//! keychain and the CLI's own config file.

use serde_json::{Map, Value, json};

use crate::CoreError;

/// Where Checkvist answers when nobody says otherwise.
pub const DEFAULT_BASE_URL: &str = "https://checkvist.com";

/// One request, ready for a client's HTTP stack.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CheckvistHttpRequest {
    /// `GET`, `POST`, `PUT` or `DELETE`.
    pub method: String,
    pub url: String,
    pub headers: Vec<CheckvistHeader>,
    /// JSON, when the call has a body.
    pub body: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CheckvistHeader {
    pub name: String,
    pub value: String,
}

/// Something to ask Checkvist.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CheckvistCall {
    /// Exchanges a username and remote key for a token. The one call made
    /// without a token.
    Login {
        username: String,
        remote_key: String,
    },
    /// Every checklist the account can see.
    Lists,
    /// A checklist's tasks, closed ones included; notes when asked for.
    Tasks {
        list_id: String,
        with_notes: bool,
    },
    CreateList {
        name: String,
    },
    /// `parse` hands the content to Checkvist's smart syntax, which lifts
    /// `#tags` and `^due` out of it. The Mac never asks for it: it keeps tags
    /// and dates itself, and Checkvist's parser would rewrite them. Checkvist
    /// treats the parameter's presence as on, so off means leaving it out.
    CreateTask {
        list_id: String,
        content: String,
        parent_id: Option<i64>,
        position: Option<i64>,
        due: Option<String>,
        tags: Option<String>,
        priority: Option<i64>,
        parse: bool,
    },
    /// Only the fields given change. Never parsed, for the reason above.
    UpdateTask {
        list_id: String,
        task_id: i64,
        content: Option<String>,
        due: Option<String>,
        tags: Option<String>,
    },
    /// Within the current parent. Checkvist's positions start at 1.
    MoveTask {
        list_id: String,
        task_id: i64,
        position: i64,
    },
    /// `None` moves the task to the list's root. That is sent as an explicit
    /// null: leaving the key out would mean "leave the parent alone".
    ReparentTask {
        list_id: String,
        task_id: i64,
        parent_id: Option<i64>,
    },
    /// A note is a Checkvist comment, a resource of its own.
    AddNote {
        list_id: String,
        task_id: i64,
        comment: String,
    },
    /// `close`, `reopen` or `invalidate`.
    TaskAction {
        list_id: String,
        task_id: i64,
        action: String,
    },
    DeleteTask {
        list_id: String,
        task_id: i64,
    },
}

fn invalid(detail: impl Into<String>) -> CoreError {
    CoreError::Checkvist {
        detail: detail.into(),
    }
}

/// A checklist id is a decimal integer spliced into a path, so a stray `../`
/// or `?` must never reach the address.
pub fn validate_list_id(list_id: &str) -> Result<(), CoreError> {
    if !list_id.is_empty() && list_id.bytes().all(|byte| byte.is_ascii_digit()) {
        return Ok(());
    }
    Err(invalid(format!(
        "Invalid list ID {list_id:?}: a Checkvist list ID is a number."
    )))
}

/// The request for `call`, against `base_url`, carrying `token` when there is
/// one. Refuses a list id that is not a number, an action Checkvist does not
/// have, an empty name or task, and an update that changes nothing.
#[uniffi::export]
pub fn checkvist_request(
    base_url: String,
    call: CheckvistCall,
    token: Option<String>,
    user_agent: String,
) -> Result<CheckvistHttpRequest, CoreError> {
    let base = base_url.trim().trim_end_matches('/');
    let base = if base.is_empty() {
        DEFAULT_BASE_URL
    } else {
        base
    };
    let (method, path, query, body): (&str, String, Option<&str>, Option<Value>) = match call {
        CheckvistCall::Login {
            username,
            remote_key,
        } => (
            "POST",
            "/auth/login.json".into(),
            None,
            Some(json!({ "username": username, "remote_key": remote_key })),
        ),
        CheckvistCall::Lists => ("GET", "/checklists.json".into(), None, None),
        CheckvistCall::Tasks {
            list_id,
            with_notes,
        } => {
            validate_list_id(&list_id)?;
            (
                "GET",
                format!("/checklists/{list_id}/tasks.json"),
                Some(if with_notes {
                    "with_notes=true"
                } else {
                    "with_notes=false"
                }),
                None,
            )
        }
        CheckvistCall::CreateList { name } => {
            let name = name.trim();
            if name.is_empty() {
                return Err(CoreError::EmptyName);
            }
            (
                "POST",
                "/checklists.json".into(),
                None,
                Some(json!({ "checklist": { "name": name } })),
            )
        }
        CheckvistCall::CreateTask {
            list_id,
            content,
            parent_id,
            position,
            due,
            tags,
            priority,
            parse,
        } => {
            validate_list_id(&list_id)?;
            let content = content.trim();
            if content.is_empty() {
                return Err(CoreError::EmptyName);
            }
            let mut task = Map::new();
            task.insert("content".into(), json!(content));
            if let Some(parent_id) = parent_id {
                task.insert("parent_id".into(), json!(parent_id));
            }
            if let Some(position) = position {
                task.insert("position".into(), json!(position));
            }
            if let Some(due) = due.filter(|due| !due.is_empty()) {
                task.insert("due_date".into(), json!(due));
            }
            if let Some(tags) = tags.filter(|tags| !tags.is_empty()) {
                task.insert("tags".into(), json!(tags));
            }
            // Checkvist only knows 1 to 4: a negative priority, "after the
            // rest", is Takt's own and goes as none.
            if let Some(priority) = priority.filter(|p| (1..=4).contains(p)) {
                task.insert("priority".into(), json!(priority));
            }
            (
                "POST",
                format!("/checklists/{list_id}/tasks.json"),
                parse.then_some("parse=true"),
                Some(json!({ "task": task })),
            )
        }
        CheckvistCall::UpdateTask {
            list_id,
            task_id,
            content,
            due,
            tags,
        } => {
            validate_list_id(&list_id)?;
            let mut task = Map::new();
            if let Some(content) = content {
                task.insert("content".into(), json!(content));
            }
            if let Some(due) = due {
                task.insert("due_date".into(), json!(due));
            }
            if let Some(tags) = tags {
                task.insert("tags".into(), json!(tags));
            }
            if task.is_empty() {
                return Err(invalid(
                    "No updates provided. Pass content, due, and/or tags.",
                ));
            }
            put(&list_id, task_id, task)
        }
        CheckvistCall::MoveTask {
            list_id,
            task_id,
            position,
        } => {
            validate_list_id(&list_id)?;
            let mut task = Map::new();
            task.insert("position".into(), json!(position));
            put(&list_id, task_id, task)
        }
        CheckvistCall::ReparentTask {
            list_id,
            task_id,
            parent_id,
        } => {
            validate_list_id(&list_id)?;
            let mut task = Map::new();
            task.insert(
                "parent_id".into(),
                parent_id.map_or(Value::Null, Value::from),
            );
            put(&list_id, task_id, task)
        }
        CheckvistCall::AddNote {
            list_id,
            task_id,
            comment,
        } => {
            validate_list_id(&list_id)?;
            (
                "POST",
                format!("/checklists/{list_id}/tasks/{task_id}/comments.json"),
                None,
                Some(json!({ "comment": { "comment": comment } })),
            )
        }
        CheckvistCall::TaskAction {
            list_id,
            task_id,
            action,
        } => {
            validate_list_id(&list_id)?;
            if !matches!(action.as_str(), "close" | "reopen" | "invalidate") {
                return Err(invalid(format!("Unsupported task action: {action}")));
            }
            (
                "POST",
                format!("/checklists/{list_id}/tasks/{task_id}/{action}.json"),
                None,
                None,
            )
        }
        CheckvistCall::DeleteTask { list_id, task_id } => {
            validate_list_id(&list_id)?;
            (
                "DELETE",
                format!("/checklists/{list_id}/tasks/{task_id}.json"),
                None,
                None,
            )
        }
    };

    let mut url = format!("{base}{path}");
    if let Some(query) = query {
        url.push('?');
        url.push_str(query);
    }
    let mut headers = vec![CheckvistHeader {
        name: "Accept".into(),
        value: "application/json".into(),
    }];
    if body.is_some() {
        headers.push(CheckvistHeader {
            name: "Content-Type".into(),
            value: "application/json".into(),
        });
    }
    if let Some(token) = token.filter(|token| !token.is_empty()) {
        headers.push(CheckvistHeader {
            name: "X-Client-Token".into(),
            value: token,
        });
    }
    if !user_agent.is_empty() {
        headers.push(CheckvistHeader {
            name: "User-Agent".into(),
            value: user_agent,
        });
    }
    Ok(CheckvistHttpRequest {
        method: method.into(),
        url,
        headers,
        body: body.map(|body| body.to_string()),
    })
}

fn put(
    list_id: &str,
    task_id: i64,
    task: Map<String, Value>,
) -> (&'static str, String, Option<&'static str>, Option<Value>) {
    (
        "PUT",
        format!("/checklists/{list_id}/tasks/{task_id}.json"),
        None,
        Some(json!({ "task": task })),
    )
}

// MARK: - Reading answers

/// A response body as JSON: empty is null, and text that is not JSON is a
/// string (Checkvist answers a login with a bare token sometimes).
pub fn parse_body(text: &str) -> Value {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Null;
    }
    serde_json::from_str(trimmed).unwrap_or_else(|_| Value::String(trimmed.to_string()))
}

/// The token in a login answer: `{"token": "…"}`, or the bare string, quoted
/// or not. Nothing when there is no non-empty token.
#[uniffi::export]
pub fn checkvist_login_token(body: String) -> Option<String> {
    let parsed = parse_body(&body);
    match &parsed {
        Value::Object(_) => parsed.get("token").and_then(Value::as_str).map(str::trim),
        Value::String(text) => Some(text.trim().trim_matches('"').trim()),
        _ => None,
    }
    .filter(|token| !token.is_empty())
    .map(str::to_string)
}

/// A checklist as the Mac keeps it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CheckvistListRow {
    pub id: i64,
    pub name: String,
    pub archived: Option<bool>,
    pub read_only: Option<bool>,
}

/// A note on a task.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CheckvistNoteRow {
    pub id: Option<i64>,
    pub content: String,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

/// A task as the Mac keeps it. `status` is 0 open, 1 closed, 2 invalidated.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CheckvistTaskRow {
    pub id: i64,
    pub content: String,
    pub status: i64,
    pub due: Option<String>,
    pub position: Option<i64>,
    pub parent_id: Option<i64>,
    pub level: Option<i64>,
    pub notes: Option<Vec<CheckvistNoteRow>>,
    pub updated_at: Option<String>,
}

/// A value read as text whatever JSON type Checkvist chose for it, as the
/// Mac's decoder did: numbers and booleans are written out.
fn lossy_string(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(match number.as_i64() {
            Some(integer) => integer.to_string(),
            None => {
                let real = number.as_f64()?;
                // Swift writes a whole real with its `.0`.
                if real.fract() == 0.0 && real.is_finite() {
                    format!("{real:.1}")
                } else {
                    real.to_string()
                }
            }
        }),
        Value::Bool(flag) => Some(if *flag { "true" } else { "false" }.into()),
        _ => None,
    }
}

/// A value read as an integer: a number (a real truncates) or a string that
/// is one.
fn lossy_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|real| real as i64)),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
}

fn note_row(value: &Value) -> Option<CheckvistNoteRow> {
    match value {
        Value::String(text) => Some(CheckvistNoteRow {
            id: None,
            content: text.clone(),
            created_at: None,
            updated_at: None,
        }),
        Value::Object(object) => Some(CheckvistNoteRow {
            id: lossy_int(object.get("id")),
            content: ["comment", "content", "text", "note"]
                .iter()
                .find_map(|key| lossy_string(object.get(*key)))
                .unwrap_or_default(),
            created_at: lossy_string(object.get("created_at")),
            updated_at: lossy_string(object.get("updated_at")),
        }),
        _ => None,
    }
}

fn notes(value: Option<&Value>) -> Option<Vec<CheckvistNoteRow>> {
    match value? {
        Value::Array(items) => items.iter().map(note_row).collect(),
        single @ (Value::Object(_) | Value::String(_)) => note_row(single).map(|note| vec![note]),
        _ => None,
    }
}

/// One task from Checkvist's JSON. Nothing without an id.
pub fn task_row(value: &Value) -> Option<CheckvistTaskRow> {
    let object = value.as_object()?;
    let id = lossy_int(object.get("id"))?;
    let content = lossy_string(object.get("content"))
        .or_else(|| lossy_string(object.get("text")))
        .unwrap_or_default();
    let due = ["due", "due_date", "deadline"]
        .iter()
        .find_map(|key| lossy_string(object.get(*key)))
        .or_else(|| {
            // Any other key that names a due date or deadline, with a value.
            object.iter().find_map(|(key, value)| {
                let lower = key.to_lowercase();
                if !(lower.contains("due") || lower.contains("deadline")) {
                    return None;
                }
                lossy_string(Some(value)).filter(|text| !text.trim().is_empty())
            })
        });
    Some(CheckvistTaskRow {
        id,
        content,
        status: lossy_int(object.get("status")).unwrap_or(0),
        due,
        position: lossy_int(object.get("position")),
        parent_id: lossy_int(object.get("parent_id")),
        level: lossy_int(object.get("level")),
        notes: notes(object.get("notes")),
        updated_at: lossy_string(object.get("updated_at")),
    })
}

fn list_row(value: &Value) -> Option<CheckvistListRow> {
    let object = value.as_object()?;
    Some(CheckvistListRow {
        id: lossy_int(object.get("id"))?,
        name: lossy_string(object.get("name"))?,
        archived: object.get("archived").and_then(Value::as_bool),
        read_only: object.get("read_only").and_then(Value::as_bool),
    })
}

fn unexpected(what: &str) -> CoreError {
    invalid(format!("Unexpected response from Checkvist while {what}."))
}

/// The checklists in a `GET /checklists.json` answer that are not archived,
/// as JSON, for a caller that hands them on as they are.
pub fn list_values(body: &str) -> Result<Vec<Value>, CoreError> {
    let Value::Array(items) = parse_body(body) else {
        return Err(unexpected("listing checklists"));
    };
    Ok(items
        .into_iter()
        .filter(|item| item.is_object() && item.get("archived") != Some(&Value::Bool(true)))
        .collect())
}

/// The checklists in a `GET /checklists.json` answer that are not archived.
#[uniffi::export]
pub fn checkvist_lists(body: String) -> Result<Vec<CheckvistListRow>, CoreError> {
    Ok(list_values(&body)?.iter().filter_map(list_row).collect())
}

/// The tasks in a `GET …/tasks.json` answer, as JSON, parents before their
/// children (see [`depth_first_order`]); closed and invalidated ones only
/// when asked for.
pub fn task_values(body: &str, include_closed: bool) -> Result<Vec<Value>, CoreError> {
    let Value::Array(items) = parse_body(body) else {
        return Err(unexpected("fetching tasks"));
    };
    let mut tasks: Vec<Value> = items.into_iter().filter(Value::is_object).collect();
    if !include_closed {
        tasks.retain(|task| status_of(task) == 0);
    }
    Ok(depth_first_tasks(tasks))
}

/// `tasks` reordered by [`depth_first_order`].
pub fn depth_first_tasks(tasks: Vec<Value>) -> Vec<Value> {
    let shape: Vec<(i64, i64, i64)> = tasks
        .iter()
        .map(|task| {
            (
                lossy_int(task.get("id")).unwrap_or(0),
                parent_id_of(task),
                lossy_int(task.get("position")).unwrap_or(0),
            )
        })
        .collect();
    let mut slots: Vec<Option<Value>> = tasks.into_iter().map(Some).collect();
    depth_first_order(&shape)
        .into_iter()
        .filter_map(|index| slots[index].take())
        .collect()
}

/// The tasks in a `GET …/tasks.json` answer, parents before children.
#[uniffi::export]
pub fn checkvist_tasks(
    body: String,
    include_closed: bool,
) -> Result<Vec<CheckvistTaskRow>, CoreError> {
    Ok(task_values(&body, include_closed)?
        .iter()
        .filter_map(task_row)
        .collect())
}

/// The task a create answered with, which Checkvist may send bare, wrapped
/// in `task`, or as the first of a `tasks` array or a bare array.
#[uniffi::export]
pub fn checkvist_created_task(body: String) -> Option<CheckvistTaskRow> {
    let parsed = parse_body(&body);
    let candidate = match &parsed {
        Value::Array(items) => items.first(),
        Value::Object(object) => match (object.get("task"), object.get("tasks")) {
            (Some(task @ Value::Object(_)), _) => Some(task),
            (_, Some(Value::Array(items))) if !object.contains_key("id") => items.first(),
            _ => Some(&parsed),
        },
        _ => None,
    }?;
    task_row(candidate)
}

/// The checklist a create answered with, bare or wrapped in `checklist`.
#[uniffi::export]
pub fn checkvist_created_list(body: String) -> Option<CheckvistListRow> {
    let parsed = parse_body(&body);
    list_row(&parsed).or_else(|| parsed.get("checklist").and_then(list_row))
}

/// A task's status: 0 open, 1 closed, 2 invalidated.
pub fn status_of(task: &Value) -> i64 {
    lossy_int(task.get("status")).unwrap_or(0)
}

/// A task's parent, 0 at the root (or when Checkvist sends null).
pub fn parent_id_of(task: &Value) -> i64 {
    lossy_int(task.get("parent_id")).unwrap_or(0)
}

/// Parents before children, siblings by `position`, given each task's
/// `(id, parent id, position)` with 0 for the root; the answer is indices into
/// `tasks`. Tasks whose parent is missing follow, by the missing id, their own
/// subtrees in the same order, so nothing Checkvist sent is lost. A parent
/// cycle stops the walk rather than recursing forever.
pub fn depth_first_order(tasks: &[(i64, i64, i64)]) -> Vec<usize> {
    use std::collections::{BTreeSet, HashMap, HashSet};
    let mut children: HashMap<i64, Vec<usize>> = HashMap::new();
    for (index, (_, parent, _)) in tasks.iter().enumerate() {
        children.entry(*parent).or_default().push(index);
    }
    for siblings in children.values_mut() {
        // Stable: equal positions keep the order Checkvist sent.
        siblings.sort_by_key(|index| tasks[*index].2);
    }
    let ids: HashSet<i64> = tasks.iter().map(|task| task.0).collect();

    let mut ordered = Vec::with_capacity(tasks.len());
    let mut visited: HashSet<i64> = HashSet::new();
    let mut emitted = vec![false; tasks.len()];
    fn walk(
        parent: i64,
        tasks: &[(i64, i64, i64)],
        children: &HashMap<i64, Vec<usize>>,
        visited: &mut HashSet<i64>,
        emitted: &mut [bool],
        ordered: &mut Vec<usize>,
    ) {
        if !visited.insert(parent) {
            return;
        }
        let Some(kids) = children.get(&parent) else {
            return;
        };
        for &child in kids {
            if emitted[child] {
                continue;
            }
            emitted[child] = true;
            ordered.push(child);
            walk(tasks[child].0, tasks, children, visited, emitted, ordered);
        }
    }
    walk(
        0,
        tasks,
        &children,
        &mut visited,
        &mut emitted,
        &mut ordered,
    );
    let missing: BTreeSet<i64> = tasks
        .iter()
        .map(|task| task.1)
        .filter(|parent| *parent != 0 && !ids.contains(parent))
        .collect();
    for parent in missing {
        walk(
            parent,
            tasks,
            &children,
            &mut visited,
            &mut emitted,
            &mut ordered,
        );
    }
    ordered
}

/// `root_id` and every task under it, the root first and then its
/// descendants in the order `tasks` holds them. Walks by ancestry rather than
/// by a contiguous run, so an answer out of hierarchy order still yields the
/// whole branch.
pub fn project_tasks(tasks: &[Value], root_id: i64) -> Result<Vec<Value>, CoreError> {
    let id_of = |task: &Value| lossy_int(task.get("id"));
    let Some(root) = tasks.iter().find(|task| id_of(task) == Some(root_id)) else {
        return Err(invalid(format!(
            "Task {root_id} was not found in the source list."
        )));
    };
    let mut result = vec![root.clone()];
    let mut included = vec![root_id];
    loop {
        let before = included.len();
        for task in tasks {
            let Some(id) = id_of(task) else {
                return Err(invalid("Task response is missing an ID."));
            };
            if included.contains(&id) || !included.contains(&parent_id_of(task)) {
                continue;
            }
            included.push(id);
            result.push(task.clone());
        }
        if included.len() == before {
            break;
        }
    }
    Ok(result)
}

/// The workspace import's seeds for Checkvist tasks: one per task id (the
/// first wins), ordered by parent then position, each source id
/// `source_prefix` and the task's id, notes joined by blank lines.
#[uniffi::export]
pub fn checkvist_import_seeds(
    source_prefix: String,
    tasks: Vec<CheckvistTaskRow>,
) -> Vec<crate::imports::ImportedTaskSeed> {
    let mut seen = std::collections::HashSet::new();
    let mut unique: Vec<&CheckvistTaskRow> =
        tasks.iter().filter(|task| seen.insert(task.id)).collect();
    unique.sort_by_key(|task| (task.parent_id.unwrap_or(0), task.position.unwrap_or(0)));
    unique
        .into_iter()
        .map(|task| crate::imports::ImportedTaskSeed {
            source_id: format!("{source_prefix}{}", task.id),
            parent_source_id: task
                .parent_id
                .map(|parent| format!("{source_prefix}{parent}")),
            title: task.content.clone(),
            notes: task
                .notes
                .as_deref()
                .unwrap_or_default()
                .iter()
                .map(|note| note.content.as_str())
                .collect::<Vec<_>>()
                .join("\n\n"),
            status: match task.status {
                0 => "open",
                1 => "completed",
                _ => "cancelled",
            }
            .into(),
            sort_order: task.position.unwrap_or(0),
        })
        .collect()
}

#[cfg(test)]
mod tests;
