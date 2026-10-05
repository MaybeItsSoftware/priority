//! A direct Checkvist API client.
//!
//! Talks to the API rather than to the running app, so every command here works
//! whether or not Priority is open. Mirrors `CheckvistClient`, the client
//! embedded in `Takt/Plugins/MCP/MCPServer.swift`.

use crate::config::Config;
use crate::error::{Result, ToolError};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::time::Duration;

pub const USER_AGENT: &str = "TaktMCP/0.3";
pub const DEFAULT_BASE_URL: &str = "https://checkvist.com";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub struct CheckvistConfig {
    pub username: String,
    pub remote_key: String,
    pub default_list_id: String,
    pub base_url: String,
}

impl CheckvistConfig {
    /// Environment first, then the CLI's own config file — see `config.rs` for
    /// why that order, and why this never consults the app's keychain item.
    pub fn resolve(config: &Config) -> Self {
        let value = |env_key, config_key| config.resolve(env_key, config_key).0.unwrap_or_default();
        CheckvistConfig {
            username: value("CHECKVIST_USERNAME", "username"),
            remote_key: value("CHECKVIST_REMOTE_KEY", "remote_key"),
            default_list_id: value("CHECKVIST_LIST_ID", "list_id"),
            base_url: config
                .resolve("CHECKVIST_BASE_URL", "base_url")
                .0
                .unwrap_or_else(|| DEFAULT_BASE_URL.into()),
        }
    }

    pub fn has_credentials(&self) -> bool {
        !self.username.is_empty() && !self.remote_key.is_empty()
    }
}

pub struct CheckvistClient {
    pub config: CheckvistConfig,
    agent: ureq::Agent,
    token: RefCell<Option<String>>,
}

impl CheckvistClient {
    pub fn new(config: CheckvistConfig) -> Self {
        CheckvistClient {
            config,
            agent: ureq::AgentBuilder::new()
                .timeout(REQUEST_TIMEOUT)
                .user_agent(USER_AGENT)
                .build(),
            token: RefCell::new(None),
        }
    }

    fn build_url(&self, path: &str) -> String {
        let base = self.config.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }

    fn request(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Value>,
        require_auth: bool,
    ) -> Result<Value> {
        // One retry only, and only for 401: a token can expire between calls,
        // but a second rejection means the credentials themselves are wrong and
        // retrying would just lock the account out slower.
        let mut retry_unauthorized = true;
        loop {
            let mut request = self.agent.request(method, &self.build_url(path));
            request = request.set("Accept", "application/json");
            for (key, value) in query {
                request = request.query(key, value);
            }
            if require_auth {
                request = request.set("X-Client-Token", &self.ensure_token()?);
            }

            let outcome = match &body {
                Some(payload) => request.send_json(payload.clone()),
                None => request.call(),
            };

            let (status, parsed) = match outcome {
                Ok(response) => {
                    let status = response.status();
                    (status, parse_body(response))
                }
                Err(ureq::Error::Status(status, response)) => (status, parse_body(response)),
                Err(ureq::Error::Transport(transport)) => {
                    return Err(ToolError::new(format!("Network error: {transport}")));
                }
            };

            if status == 401 && require_auth && retry_unauthorized {
                *self.token.borrow_mut() = None;
                retry_unauthorized = false;
                continue;
            }

            if !(200..300).contains(&status) {
                return Err(ToolError::http(
                    format!("Checkvist API request failed with status {status}."),
                    Some(status),
                    Some(parsed),
                ));
            }

            return Ok(parsed);
        }
    }

    fn ensure_token(&self) -> Result<String> {
        if let Some(token) = self.token.borrow().clone() {
            return Ok(token);
        }
        self.login()?;
        self.token
            .borrow()
            .clone()
            .ok_or_else(|| ToolError::new("Authentication failed."))
    }

    pub fn login(&self) -> Result<()> {
        if !self.config.has_credentials() {
            return Err(ToolError::new(
                "Missing credentials. Set CHECKVIST_USERNAME and CHECKVIST_REMOTE_KEY.",
            ));
        }
        let payload = json!({
            "username": self.config.username,
            "remote_key": self.config.remote_key,
        });
        let response = self.request("POST", "/auth/login.json", &[], Some(payload), false)?;

        let token = match &response {
            Value::Object(_) => response.get("token").and_then(Value::as_str).map(str::trim),
            Value::String(text) => Some(text.trim().trim_matches('"')),
            _ => None,
        }
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ToolError::new("Authentication response did not include a token."))?;

        *self.token.borrow_mut() = Some(token.to_string());
        Ok(())
    }

    pub fn resolve_list_id(&self, explicit: Option<&str>) -> Result<String> {
        let explicit = explicit.unwrap_or("").trim();
        let list_id = if explicit.is_empty() {
            self.config.default_list_id.as_str()
        } else {
            explicit
        };
        if list_id.is_empty() {
            return Err(ToolError::new(
                "Missing list ID. Set CHECKVIST_LIST_ID or pass list_id.",
            ));
        }
        Ok(list_id.to_string())
    }

    pub fn list_lists(&self) -> Result<Vec<Value>> {
        let response = self.request("GET", "/checklists.json", &[], None, true)?;
        let Value::Array(items) = response else {
            return Err(ToolError::http(
                "Unexpected response while listing checklists.",
                None,
                Some(response),
            ));
        };
        Ok(items
            .into_iter()
            .filter(|item| item.is_object() && item.get("archived") != Some(&Value::Bool(true)))
            .collect())
    }

    pub fn fetch_tasks(
        &self,
        list_id: &str,
        include_closed: bool,
        with_notes: bool,
    ) -> Result<Vec<Value>> {
        let response = self.request(
            "GET",
            &format!("/checklists/{list_id}/tasks.json"),
            &[("with_notes", if with_notes { "true" } else { "false" })],
            None,
            true,
        )?;
        let Value::Array(items) = response else {
            return Err(ToolError::http(
                "Unexpected response while fetching tasks.",
                None,
                Some(response),
            ));
        };

        let mut tasks: Vec<Value> = items.into_iter().filter(Value::is_object).collect();
        if !include_closed {
            tasks.retain(|task| status_of(task) == 0);
        }
        Ok(depth_first_tasks(tasks))
    }

    pub fn create_task(
        &self,
        list_id: &str,
        content: &str,
        parent_id: Option<i64>,
        position: Option<i64>,
        due: Option<&str>,
    ) -> Result<Value> {
        let mut task = serde_json::Map::new();
        task.insert("content".into(), json!(content));
        if let Some(parent_id) = parent_id {
            task.insert("parent_id".into(), json!(parent_id));
        }
        if let Some(position) = position {
            task.insert("position".into(), json!(position));
        }
        if let Some(due) = due {
            task.insert("due".into(), json!(due));
        }

        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks.json"),
            &[("parse", "true")],
            Some(json!({ "task": task })),
            true,
        )?;
        if !response.is_object() {
            return Err(ToolError::http(
                "Unexpected response while creating task.",
                None,
                Some(response),
            ));
        }
        Ok(response)
    }

    pub fn update_task(
        &self,
        list_id: &str,
        task_id: i64,
        content: Option<&str>,
        due: Option<&str>,
        tags: Option<&str>,
    ) -> Result<Value> {
        let mut payload = serde_json::Map::new();
        if let Some(content) = content {
            payload.insert("content".into(), json!(content));
        }
        if let Some(due) = due {
            payload.insert("due".into(), json!(due));
        }
        if let Some(tags) = tags {
            payload.insert("tags".into(), json!(tags));
        }
        if payload.is_empty() {
            return Err(ToolError::new(
                "No updates provided. Pass content, due, and/or tags.",
            ));
        }
        self.put_task(list_id, task_id, Value::Object(payload))
    }

    /// Reorder within the current parent. Checkvist positions are 1-based.
    pub fn move_task(&self, list_id: &str, task_id: i64, position: i64) -> Result<Value> {
        self.put_task(list_id, task_id, json!({ "position": position }))
    }

    /// `parent_id = None` promotes to the list root.
    ///
    /// Sent explicitly as null rather than omitted: omitting the key means
    /// "leave the parent alone", which is a different request.
    pub fn reparent_task(
        &self,
        list_id: &str,
        task_id: i64,
        parent_id: Option<i64>,
    ) -> Result<Value> {
        let parent = parent_id.map_or(Value::Null, Value::from);
        self.put_task(list_id, task_id, json!({ "parent_id": parent }))
    }

    /// Transfer a task and every descendant into another checklist.
    ///
    /// Checkvist's public REST API exposes hierarchy edits inside one checklist,
    /// but not the web app's cross-checklist move action.  We therefore create
    /// a verified equivalent tree in the destination before deleting the source
    /// root.  A failed copy leaves the original untouched; a failed delete leaves
    /// both trees intact rather than risking data loss.
    pub fn move_project_to_list(
        &self,
        source_list_id: &str,
        target_list_id: &str,
        root_task_id: i64,
    ) -> Result<Value> {
        if source_list_id == target_list_id {
            return Err(ToolError::new(
                "source_list_id and target_list_id must be different.",
            ));
        }

        let source_tasks = self.fetch_tasks(source_list_id, true, true)?;
        let project = project_tasks(&source_tasks, root_task_id)?;
        let mut id_map: HashMap<i64, i64> = HashMap::new();
        let mut copied: Vec<Value> = Vec::with_capacity(project.len());

        // Create every item open first. Applying closed/invalidated statuses
        // afterwards avoids a closed parent changing the state of descendants
        // as they are added.
        for task in &project {
            let source_id = task_id(task)?;
            let source_parent = parent_id_of(task);
            let target_parent = id_map.get(&source_parent).copied();
            let created = self.copy_task(target_list_id, task, target_parent)?;
            let target_id = task_id(&created)?;
            id_map.insert(source_id, target_id);
            copied.push(created);
        }

        // Comments are a separate Checkvist resource, so add them only after
        // the complete task tree itself has been created.
        for task in &project {
            let source_id = task_id(task)?;
            let target_id = *id_map
                .get(&source_id)
                .ok_or_else(|| ToolError::new("Internal error mapping copied task."))?;
            for note in notes_of(task) {
                self.add_note(target_list_id, target_id, &note)?;
            }
        }

        // Children first: Checkvist derives a non-leaf task's status from its
        // children, and applying parent status first could overwrite them.
        for task in project.iter().rev() {
            let status = status_of(task);
            if status == 0 {
                continue;
            }
            let source_id = task_id(task)?;
            let target_id = *id_map
                .get(&source_id)
                .ok_or_else(|| ToolError::new("Internal error mapping copied task."))?;
            let action = match status {
                1 => "close",
                2 => "invalidate",
                _ => return Err(ToolError::new("Source task has an unsupported status.")),
            };
            self.task_action(target_list_id, target_id, action)?;
        }

        let target_root_id = *id_map
            .get(&root_task_id)
            .ok_or_else(|| ToolError::new("Internal error mapping copied project root."))?;
        self.verify_copied_project(target_list_id, target_root_id, &project, &id_map)?;

        // This is intentionally last. The source hierarchy remains recoverable
        // until destination structure and task count have been checked.
        self.delete_task(source_list_id, root_task_id)?;

        let id_map: Vec<Value> = project
            .iter()
            .map(|task| {
                let source_id = task_id(task)?;
                let target_id = id_map
                    .get(&source_id)
                    .copied()
                    .ok_or_else(|| ToolError::new("Internal error mapping copied task."))?;
                Ok(json!({ "source_task_id": source_id, "target_task_id": target_id }))
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(json!({
            "source_list_id": source_list_id,
            "target_list_id": target_list_id,
            "source_root_task_id": root_task_id,
            "target_root_task_id": target_root_id,
            "moved_task_count": project.len(),
            "task_id_map": id_map,
        }))
    }

    fn copy_task(
        &self,
        target_list_id: &str,
        source: &Value,
        target_parent_id: Option<i64>,
    ) -> Result<Value> {
        let content = source
            .get("content")
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
            .ok_or_else(|| ToolError::new("Source task is missing content."))?;
        let mut task = serde_json::Map::new();
        task.insert("content".into(), json!(content));
        if let Some(parent_id) = target_parent_id {
            task.insert("parent_id".into(), json!(parent_id));
        }
        if let Some(position) = source.get("position").and_then(Value::as_i64) {
            task.insert("position".into(), json!(position));
        }
        if let Some(due) = source
            .get("due")
            .and_then(Value::as_str)
            .filter(|due| !due.is_empty())
        {
            task.insert("due".into(), json!(due));
        }
        if let Some(tags) = source
            .get("tags_as_text")
            .and_then(Value::as_str)
            .filter(|tags| !tags.is_empty())
        {
            task.insert("tags".into(), json!(tags));
        }
        if let Some(priority) = source.get("priority").and_then(Value::as_i64) {
            task.insert("priority".into(), json!(priority));
        }

        let response = self.request(
            "POST",
            &format!("/checklists/{target_list_id}/tasks.json"),
            // Checkvist treats the presence of `parse` as enabled, including
            // the string value `false`. Omit it entirely to retain literal
            // text such as "#test" while transferring an existing project.
            &[],
            Some(json!({ "task": task })),
            true,
        )?;
        if !response.is_object() {
            return Err(ToolError::http(
                "Unexpected response while copying task.",
                None,
                Some(response),
            ));
        }
        Ok(response)
    }

    fn verify_copied_project(
        &self,
        target_list_id: &str,
        target_root_id: i64,
        source_project: &[Value],
        id_map: &HashMap<i64, i64>,
    ) -> Result<()> {
        let target_tasks = self.fetch_tasks(target_list_id, true, false)?;
        let target_project = project_tasks(&target_tasks, target_root_id)?;
        if target_project.len() != source_project.len() {
            return Err(ToolError::new(format!(
                "Copied project verification failed: expected {} tasks, found {}. Source was not deleted.",
                source_project.len(),
                target_project.len()
            )));
        }
        for source in source_project {
            let source_id = task_id(source)?;
            let target_id = *id_map
                .get(&source_id)
                .ok_or_else(|| ToolError::new("Internal error mapping copied task."))?;
            let Some(target) = target_project
                .iter()
                .find(|candidate| candidate.get("id").and_then(Value::as_i64) == Some(target_id))
            else {
                return Err(ToolError::new(
                    "Copied project verification failed: a copied task is missing. Source was not deleted.",
                ));
            };
            if target.get("content") != source.get("content") {
                return Err(ToolError::new(
                    "Copied project verification failed: task content changed. Source was not deleted.",
                ));
            }
            let expected_parent = parent_id_of(source);
            let actual_parent = parent_id_of(target);
            match id_map.get(&expected_parent) {
                Some(expected_target_parent) if *expected_target_parent == actual_parent => {}
                None if expected_parent == 0 && actual_parent == 0 => {}
                _ => {
                    return Err(ToolError::new(
                        "Copied project verification failed: hierarchy changed. Source was not deleted.",
                    ));
                }
            }
        }
        Ok(())
    }

    fn put_task(&self, list_id: &str, task_id: i64, task: Value) -> Result<Value> {
        let response = self.request(
            "PUT",
            &format!("/checklists/{list_id}/tasks/{task_id}.json"),
            &[],
            Some(json!({ "task": task })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn create_list(&self, name: &str) -> Result<Value> {
        let response = self.request(
            "POST",
            "/checklists.json",
            &[],
            Some(json!({ "checklist": { "name": name } })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    /// Notes are Checkvist "comments" — a separate resource from the task,
    /// which is why `update_task` cannot write them.
    pub fn add_note(&self, list_id: &str, task_id: i64, comment: &str) -> Result<Value> {
        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks/{task_id}/comments.json"),
            &[],
            Some(json!({ "comment": { "comment": comment } })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn task_action(&self, list_id: &str, task_id: i64, action: &str) -> Result<Value> {
        if !matches!(action, "close" | "reopen" | "invalidate") {
            return Err(ToolError::new(format!("Unsupported task action: {action}")));
        }
        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks/{task_id}/{action}.json"),
            &[],
            None,
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn delete_task(&self, list_id: &str, task_id: i64) -> Result<Value> {
        let response = self.request(
            "DELETE",
            &format!("/checklists/{list_id}/tasks/{task_id}.json"),
            &[],
            None,
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }
}

fn parse_body(response: ureq::Response) -> Value {
    let Ok(text) = response.into_string() else {
        return Value::Null;
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Null;
    }
    serde_json::from_str(trimmed).unwrap_or_else(|_| Value::String(trimmed.to_string()))
}

/// Some endpoints answer with a bare `true` or an empty body. Wrapping keeps
/// every tool result an object, matching the other two servers.
fn ok_or_wrapped(response: Value) -> Value {
    if response.is_object() {
        response
    } else {
        json!({ "ok": true, "response": response })
    }
}

pub fn status_of(task: &Value) -> i64 {
    task.get("status").and_then(Value::as_i64).unwrap_or(0)
}

pub fn parent_id_of(task: &Value) -> i64 {
    match task.get("parent_id") {
        Some(Value::Number(number)) => number.as_i64().unwrap_or(0),
        Some(Value::String(text)) => text.parse().unwrap_or(0),
        _ => 0,
    }
}

fn task_id(task: &Value) -> Result<i64> {
    task.get("id")
        .and_then(Value::as_i64)
        .ok_or_else(|| ToolError::new("Task response is missing an ID."))
}

fn notes_of(task: &Value) -> Vec<String> {
    task.get("notes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|note| note.get("comment").and_then(Value::as_str))
        .map(str::to_owned)
        .collect()
}

/// Return the root and its descendants, depth-first. `tasks` is already
/// ordered by [`depth_first_tasks`], but filtering by ancestry rather than by
/// a contiguous range also handles a malformed ordering defensively.
fn project_tasks(tasks: &[Value], root_id: i64) -> Result<Vec<Value>> {
    if !tasks
        .iter()
        .any(|task| task.get("id").and_then(Value::as_i64) == Some(root_id))
    {
        return Err(ToolError::new(format!(
            "Task {root_id} was not found in the source list."
        )));
    }

    let mut result = Vec::new();
    let mut included = vec![root_id];
    // The API can return rows out of hierarchy order when a list has been
    // edited concurrently. Repeat until no further descendant is found.
    while result.len() < tasks.len() {
        let before = result.len();
        for task in tasks {
            let id = task_id(task)?;
            if included.contains(&id) || !included.contains(&parent_id_of(task)) {
                continue;
            }
            included.push(id);
            result.push(task.clone());
        }
        if result.len() == before {
            break;
        }
    }

    // The loop above intentionally skips the root (its parent is external),
    // so prepend it after confirming the traversal found no impossible cycle.
    let root = tasks
        .iter()
        .find(|task| task.get("id").and_then(Value::as_i64) == Some(root_id))
        .expect("root presence checked above")
        .clone();
    result.insert(0, root);
    Ok(result)
}

/// Parents before children, siblings in `position` order — the order the app
/// shows, so a task list read here reads the same as the popover.
pub fn depth_first_tasks(tasks: Vec<Value>) -> Vec<Value> {
    let mut children_by_parent: Vec<(i64, Vec<Value>)> = Vec::new();
    for task in tasks {
        let parent_id = parent_id_of(&task);
        match children_by_parent
            .iter_mut()
            .find(|(id, _)| *id == parent_id)
        {
            Some((_, siblings)) => siblings.push(task),
            None => children_by_parent.push((parent_id, vec![task])),
        }
    }
    for (_, siblings) in &mut children_by_parent {
        siblings.sort_by_key(|task| task.get("position").and_then(Value::as_i64).unwrap_or(0));
    }

    let mut ordered = Vec::new();
    let mut visited: Vec<i64> = Vec::new();
    walk(0, &children_by_parent, &mut ordered, &mut visited);
    ordered
}

fn walk(
    parent_id: i64,
    children_by_parent: &[(i64, Vec<Value>)],
    ordered: &mut Vec<Value>,
    visited: &mut Vec<i64>,
) {
    // A parent cycle would otherwise recurse until the stack runs out. The API
    // should never return one; a malformed list should still produce a partial
    // answer rather than a crash.
    if visited.contains(&parent_id) {
        return;
    }
    visited.push(parent_id);

    let Some((_, children)) = children_by_parent.iter().find(|(id, _)| *id == parent_id) else {
        return;
    };
    for child in children {
        ordered.push(child.clone());
        if let Some(child_id) = child.get("id").and_then(Value::as_i64) {
            walk(child_id, children_by_parent, ordered, visited);
        }
    }
}
