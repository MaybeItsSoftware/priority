use serde_json::Value;
use std::fmt;

/// Anything a tool can fail with that the user should see.
///
/// Deliberately one type rather than a hierarchy: every failure here — a bad
/// argument, a missing credential, a Checkvist refusal, an unwritable file —
/// ends up in the same two places, an `isError` MCP result or a line on stderr,
/// and none of the callers branch on the kind. `status` and `body` carry the
/// HTTP detail when there is one.
#[derive(Debug)]
pub struct ToolError {
    pub message: String,
    pub status: Option<u16>,
    pub body: Option<Value>,
}

impl ToolError {
    pub fn new(message: impl Into<String>) -> Self {
        ToolError {
            message: message.into(),
            status: None,
            body: None,
        }
    }

    pub fn http(message: impl Into<String>, status: Option<u16>, body: Option<Value>) -> Self {
        ToolError {
            message: message.into(),
            status,
            body,
        }
    }

    /// The `{status, body}` object the MCP server attaches to a failed call.
    /// Both keys are always present, and null when absent, so a client can
    /// read them without checking for them first.
    pub fn detail(&self) -> Value {
        serde_json::json!({
            "status": self.status.map(Value::from).unwrap_or(Value::Null),
            "body": self.body.clone().unwrap_or(Value::Null),
        })
    }
}

impl fmt::Display for ToolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl std::error::Error for ToolError {}

pub type Result<T> = std::result::Result<T, ToolError>;
