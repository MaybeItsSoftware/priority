//! Priority's MCP stdio server.
//!
//! This is now the only one. There were three — a Swift server embedded in the
//! app and a Python fallback script alongside this — and holding them equal
//! from the outside cost more than it bought, since none could import another.
//! The app ships this binary instead (`Priority.app/Contents/Helpers/priority`)
//! and `Priority --mcp-server` hands the process over to it, which is why the
//! bare flag is accepted in `main.rs` and why the environment outranks the
//! config file in `config.rs`: configurations written for the old server keep
//! working untouched.
//!
//! Exposing the tools here is a dispatch table rather than an implementation —
//! this and `cli.rs` both go through [`crate::tools::Tools::call`].
//! `scripts/mcp_smoke_check.py` checks the handover; `cargo test` checks the
//! behaviour.

use crate::tools::Tools;
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Read, Stdin, Write};

const JSONRPC_VERSION: &str = "2.0";
const DEFAULT_PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "priority-mcp";
const SERVER_VERSION: &str = "0.3.0";

const JSONRPC_PARSE_ERROR: i64 = -32700;
const JSONRPC_INVALID_REQUEST: i64 = -32600;
const JSONRPC_METHOD_NOT_FOUND: i64 = -32601;
const JSONRPC_INVALID_PARAMS: i64 = -32602;

struct JsonRpcError {
    code: i64,
    message: String,
}

impl JsonRpcError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        JsonRpcError {
            code,
            message: message.into(),
        }
    }
}

#[derive(PartialEq)]
enum Framing {
    /// The MCP stdio transport: one JSON object per line, no headers.
    Newline,
    /// LSP-style, still accepted for anything already wired up that way.
    ContentLength,
}

pub struct Server {
    tools: Tools,
    reader: BufReader<Stdin>,
    protocol_version: String,
    framing: Framing,
}

impl Server {
    pub fn new(tools: Tools) -> Self {
        Server {
            tools,
            reader: BufReader::new(std::io::stdin()),
            protocol_version: DEFAULT_PROTOCOL_VERSION.into(),
            // The right default before any request has been read; switched if a
            // peer uses headers, and replies mirror whichever arrived.
            framing: Framing::Newline,
        }
    }

    pub fn run(&mut self) {
        loop {
            match self.read_message() {
                Ok(None) => return,
                Ok(Some(message)) => {
                    let id = message.get("id").cloned();
                    if let Err(error) = self.handle(&message)
                        && let Some(id) = id.filter(|id| !id.is_null())
                    {
                        self.send(json!({
                            "jsonrpc": JSONRPC_VERSION,
                            "id": id,
                            "error": { "code": error.code, "message": error.message },
                        }));
                    }
                }
                Err(error) => {
                    // A frame we could not parse has no id to answer against,
                    // so it is reported without one rather than dropped.
                    self.send(json!({
                        "jsonrpc": JSONRPC_VERSION,
                        "id": Value::Null,
                        "error": { "code": error.code, "message": error.message },
                    }));
                }
            }
        }
    }

    fn handle(&mut self, message: &Value) -> Result<(), JsonRpcError> {
        let Some(object) = message.as_object() else {
            return Err(JsonRpcError::new(
                JSONRPC_INVALID_REQUEST,
                "Request must be an object.",
            ));
        };
        if object.get("jsonrpc").and_then(Value::as_str) != Some(JSONRPC_VERSION) {
            return Err(JsonRpcError::new(
                JSONRPC_INVALID_REQUEST,
                "Unsupported JSON-RPC version.",
            ));
        }
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            return Err(JsonRpcError::new(
                JSONRPC_INVALID_REQUEST,
                "Missing method.",
            ));
        };

        let params = object.get("params");
        // A message without an id is a notification: it is acted on, but never
        // answered.
        let id = object.get("id").filter(|id| !id.is_null()).cloned();

        let result = match method {
            "notifications/initialized" => return Ok(()),
            "initialize" => {
                if let Some(requested) = params
                    .and_then(|params| params.get("protocolVersion"))
                    .and_then(Value::as_str)
                    .filter(|version| !version.is_empty())
                {
                    self.protocol_version = requested.to_string();
                }
                json!({
                    "protocolVersion": self.protocol_version,
                    "serverInfo": { "name": SERVER_NAME, "version": SERVER_VERSION },
                    "capabilities": { "tools": {} },
                })
            }
            "ping" | "logging/setLevel" => json!({}),
            "tools/list" => json!({ "tools": tool_definitions() }),
            "resources/list" => json!({ "resources": [] }),
            "prompts/list" => json!({ "prompts": [] }),
            "tools/call" => {
                let Some(params) = params.and_then(Value::as_object) else {
                    return Err(JsonRpcError::new(
                        JSONRPC_INVALID_PARAMS,
                        "tools/call params must be an object.",
                    ));
                };
                let name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty())
                    .ok_or_else(|| JsonRpcError::new(JSONRPC_INVALID_PARAMS, "Missing tool name."))?
                    .to_string();
                let arguments = match params.get("arguments") {
                    None | Some(Value::Null) => Map::new(),
                    Some(Value::Object(arguments)) => arguments.clone(),
                    Some(_) => {
                        return Err(JsonRpcError::new(
                            JSONRPC_INVALID_PARAMS,
                            "Tool arguments must be an object.",
                        ));
                    }
                };
                self.call_tool(&name, &arguments)
            }
            other => {
                return Err(JsonRpcError::new(
                    JSONRPC_METHOD_NOT_FOUND,
                    format!("Method not found: {other}"),
                ));
            }
        };

        if let Some(id) = id {
            self.send(json!({ "jsonrpc": JSONRPC_VERSION, "id": id, "result": result }));
        }
        Ok(())
    }

    /// A tool failure is a *result* with `isError`, not a JSON-RPC error: the
    /// client is supposed to show the assistant what went wrong so it can try
    /// something else, which a protocol-level error does not do.
    fn call_tool(&self, name: &str, arguments: &Map<String, Value>) -> Value {
        match self.tools.call(name, arguments) {
            Ok(outcome) => json!({
                "content": [{ "type": "text", "text": tool_result_text(&outcome.title, &outcome.payload) }],
            }),
            Err(error) => json!({
                "content": [{
                    "type": "text",
                    "text": tool_result_text(&format!("Error: {error}"), &error.detail()),
                }],
                "isError": true,
            }),
        }
    }

    // -- framing -------------------------------------------------------------

    fn read_message(&mut self) -> Result<Option<Value>, JsonRpcError> {
        loop {
            let Some(line) = self.read_line()? else {
                return Ok(None);
            };
            let trimmed = line.trim().to_string();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.to_lowercase().starts_with("content-length:") {
                return self.read_header_framed(&trimmed).map(Some);
            }
            self.framing = Framing::Newline;
            return parse_body(trimmed.as_bytes()).map(Some);
        }
    }

    fn read_line(&mut self) -> Result<Option<String>, JsonRpcError> {
        let mut buffer = Vec::new();
        match self.reader.read_until(b'\n', &mut buffer) {
            Ok(0) => Ok(None),
            Ok(_) => Ok(Some(String::from_utf8_lossy(&buffer).into_owned())),
            Err(err) => Err(JsonRpcError::new(
                JSONRPC_PARSE_ERROR,
                format!("Could not read input: {err}"),
            )),
        }
    }

    fn read_header_framed(&mut self, first_line: &str) -> Result<Value, JsonRpcError> {
        self.framing = Framing::ContentLength;

        let mut content_length: Option<usize> = None;
        let mut line = first_line.to_string();
        loop {
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                let Some((name, value)) = trimmed.split_once(':') else {
                    return Err(JsonRpcError::new(
                        JSONRPC_PARSE_ERROR,
                        "Malformed header line.",
                    ));
                };
                if name.trim().eq_ignore_ascii_case("content-length") {
                    content_length = Some(value.trim().parse().map_err(|_| {
                        JsonRpcError::new(JSONRPC_PARSE_ERROR, "Invalid Content-Length header.")
                    })?);
                }
            }
            match self.read_line()? {
                None => break,
                Some(next) if next == "\r\n" || next == "\n" => break,
                Some(next) => line = next,
            }
        }

        let content_length = content_length.ok_or_else(|| {
            JsonRpcError::new(JSONRPC_PARSE_ERROR, "Missing Content-Length header.")
        })?;

        let mut body = vec![0_u8; content_length];
        self.reader.read_exact(&mut body).map_err(|_| {
            JsonRpcError::new(
                JSONRPC_PARSE_ERROR,
                "Unexpected EOF while reading message body.",
            )
        })?;
        parse_body(&body)
    }

    fn send(&self, payload: Value) {
        let raw = serde_json::to_vec(&payload).unwrap_or_default();
        let mut stdout = std::io::stdout().lock();
        if self.framing == Framing::ContentLength {
            let _ = write!(stdout, "Content-Length: {}\r\n\r\n", raw.len());
            let _ = stdout.write_all(&raw);
        } else {
            let _ = stdout.write_all(&raw);
            let _ = stdout.write_all(b"\n");
        }
        let _ = stdout.flush();
    }
}

fn parse_body(body: &[u8]) -> Result<Value, JsonRpcError> {
    serde_json::from_slice(body)
        .map_err(|_| JsonRpcError::new(JSONRPC_PARSE_ERROR, "Invalid JSON payload."))
}

/// A title line, a blank line, then the payload as sorted-key, two-space JSON.
/// `serde_json::Map` is a `BTreeMap`, so the sorting is inherent rather than a
/// flag that could be forgotten on one call site.
pub fn tool_result_text(title: &str, payload: &Value) -> String {
    let body = serde_json::to_string_pretty(payload).unwrap_or_else(|_| "null".into());
    format!("{title}\n\n{body}")
}

/// The tool surface. The descriptions are what an assistant reads to decide
/// whether to call one, so they carry as much weight as the schemas.
///
/// `scripts/mcp_smoke_check.py` pins the count, which is the cheap half of
/// noticing an accidental removal; `docs/mcp-server.md` lists them.
pub fn tool_definitions() -> Vec<Value> {
    let list_id = || json!({ "type": "string" });
    let with_task_id = json!({
        "type": "object",
        "properties": { "list_id": list_id(), "task_id": { "type": "integer" } },
        "required": ["task_id"],
        "additionalProperties": false,
    });

    vec![
        json!({
            "name": "task_lists",
            "description": "List available task lists (non-archived).",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false },
        }),
        json!({
            "name": "task_fetch",
            "description": "Fetch tasks for a list. Defaults to open tasks only.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "include_closed": { "type": "boolean", "default": false },
                    "with_notes": { "type": "boolean", "default": true },
                },
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_add",
            "description": "Quick-add a task to list root or to a specific parent task ID.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "content": { "type": "string", "minLength": 1 },
                    "location": { "type": "string", "enum": ["default", "specific"], "default": "default" },
                    "parent_task_id": { "type": "integer" },
                    "position": { "type": "integer", "default": 1 },
                    "due": { "type": "string" },
                },
                "required": ["content"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_update",
            "description": "Update task content, due field, and/or tags. An empty tags string removes every tag.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "task_id": { "type": "integer" },
                    "content": { "type": "string" },
                    "due": { "type": "string" },
                    "tags": { "type": "string" },
                },
                "required": ["task_id"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_complete",
            "description": "Mark a task as complete (close).",
            "inputSchema": with_task_id,
        }),
        json!({
            "name": "task_reopen",
            "description": "Reopen a task.",
            "inputSchema": with_task_id,
        }),
        json!({
            "name": "task_invalidate",
            "description": "Invalidate a task.",
            "inputSchema": with_task_id,
        }),
        json!({
            "name": "task_delete",
            "description": "Delete a task.",
            "inputSchema": with_task_id,
        }),
        json!({
            "name": "task_move",
            "description": "Reorder a task among its siblings. Position is 1-based.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "task_id": { "type": "integer" },
                    "position": { "type": "integer", "minimum": 1 },
                },
                "required": ["task_id", "position"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_reparent",
            "description": "Move a task under a different parent. Omit parent_task_id (or pass 0) to move it to the list root.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "task_id": { "type": "integer" },
                    "parent_task_id": { "type": "integer" },
                },
                "required": ["task_id"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "project_move",
            "description": "Move a root task and its complete subtree to another list. The destination copy is verified before the source project is deleted; the result includes an old-to-new task ID map.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source_list_id": { "type": "string", "minLength": 1 },
                    "target_list_id": { "type": "string", "minLength": 1 },
                    "task_id": { "type": "integer" },
                },
                "required": ["source_list_id", "target_list_id", "task_id"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_note_add",
            "description": "Append a note (Checkvist comment) to a task. Notes are read back via task_fetch with with_notes.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "task_id": { "type": "integer" },
                    "note": { "type": "string", "minLength": 1 },
                },
                "required": ["task_id", "note"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "list_create",
            "description": "Create a new checklist.",
            "inputSchema": {
                "type": "object",
                "properties": { "name": { "type": "string", "minLength": 1 } },
                "required": ["name"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_search",
            "description": "Search tasks in a list by content substring, tag, and/or due date. Cheaper than fetching the whole list.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "query": { "type": "string" },
                    "tag": { "type": "string" },
                    "due_before": { "type": "string", "description": "YYYY-MM-DD, exclusive." },
                    "include_closed": { "type": "boolean", "default": false },
                    "limit": { "type": "integer", "default": 50, "minimum": 1 },
                },
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "daily_log_fetch",
            "description": "What actually happened on recent days: completions, focus time, unfinished and deferred tasks, and daily ticks. Local to Priority; read-only.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "days": {
                        "type": "integer",
                        "default": 1,
                        "minimum": 1,
                        "maximum": 90,
                        "description": "How many logical days back to include, ending today.",
                    },
                },
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "dailies_list",
            "description": "The configured dailies (habits) with today's schedule and tick state. Local to Priority; read-only.",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false },
        }),
        json!({
            "name": "task_metadata",
            "description": "Priority-only per-task state that Checkvist does not store: priority ranks, recurrence rules, and start dates. Read-only.",
            "inputSchema": {
                "type": "object",
                "properties": { "list_id": list_id() },
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "task_matrix_set",
            "description": "Place tasks on the Eisenhower matrix (urgency and importance, each -9 to 9; 0,0 removes a placement). Local to Priority. Requires Priority to be closed - a running app overwrites these on its next save.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "list_id": list_id(),
                    "placements": {
                        "type": "array",
                        "description": "One entry per task.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "task_id": { "type": "integer" },
                                "urgency": { "type": "number", "minimum": -9, "maximum": 9 },
                                "importance": { "type": "number", "minimum": -9, "maximum": 9 },
                            },
                            "required": ["task_id", "urgency", "importance"],
                            "additionalProperties": false,
                        },
                    },
                },
                "required": ["placements"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "daily_add",
            "description": "Create a daily (a habit that resets each day, not a task). Local to Priority.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": { "type": "string", "minLength": 1 },
                    "active_weekdays": {
                        "type": "array",
                        "items": { "type": "integer", "minimum": 1, "maximum": 7 },
                        "description": "1 = Sunday. Omit for every day.",
                    },
                    "interval_days": {
                        "type": "integer", "minimum": 1, "maximum": 366,
                        "description": "Repeat every N days from today instead of on fixed weekdays. Not combinable with active_weekdays.",
                    },
                },
                "required": ["title"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "daily_update",
            "description": "Rename a daily, reschedule it (fixed weekdays or an every-N-days cycle), or archive/unarchive it. Archiving keeps history readable rather than deleting.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "daily_id": { "type": "string" },
                    "title": { "type": "string" },
                    "active_weekdays": {
                        "type": "array",
                        "items": { "type": "integer", "minimum": 1, "maximum": 7 },
                        "description": "1 = Sunday. Switches a cycling daily back to fixed weekdays.",
                    },
                    "interval_days": {
                        "type": "integer", "minimum": 1, "maximum": 366,
                        "description": "Repeat every N days instead of on fixed weekdays. Not combinable with active_weekdays.",
                    },
                    "archived": { "type": "boolean" },
                },
                "required": ["daily_id"],
                "additionalProperties": false,
            },
        }),
        json!({
            "name": "daily_tick",
            "description": "Tick or un-tick a daily for today. Recorded against the current logical day, honouring the configured rollover hour.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "daily_id": { "type": "string" },
                    "done": { "type": "boolean", "default": true },
                },
                "required": ["daily_id"],
                "additionalProperties": false,
            },
        }),
    ]
}
