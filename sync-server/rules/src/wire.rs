//! The bodies a sync cycle sends and receives (docs/sync.md, "Wire
//! protocol"): `POST /v1/push` and `GET /v1/changes`. The server decodes a
//! push and encodes a page with these; the Rust core, which every client calls,
//! encodes a push and decodes a page with the same structs, so the two ends
//! cannot drift apart.
//!
//! A value is a JSON `null`, number or string, as SQLite stores it. The server
//! keeps it as JSON (`serde_json::Value`) and never looks inside; the core
//! turns it into a column value.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// `POST /v1/push`'s body.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PushRequest {
    pub changes: Vec<WireChange>,
}

/// One row's change in a push.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WireChange {
    pub table: String,
    pub id: String,
    pub op: WireOp,
    pub hlc: String,
    /// The columns of an upsert. Left out of a delete.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Map<String, Value>>,
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WireOp {
    Upsert,
    Delete,
}

/// `POST /v1/push`'s answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushResponse {
    pub accepted: usize,
    pub cursor: i64,
}

/// `GET /v1/changes`'s answer: one page of the account's feed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangesResponse {
    pub rows: Vec<ChangedRow>,
    pub cursor: i64,
    pub has_more: bool,
}

/// A row as the server holds it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChangedRow {
    pub table: String,
    pub id: String,
    pub deleted: bool,
    #[serde(default)]
    pub values: Map<String, Value>,
    /// The newest of the row's column stamps and its delete stamp.
    #[serde(default)]
    pub hlc: Option<String>,
}

/// Every error the server sends: `{"error": "..."}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_delete_leaves_its_values_out_and_an_upsert_keeps_them() {
        let request = PushRequest {
            changes: vec![
                WireChange {
                    table: "tasks".into(),
                    id: "a".into(),
                    op: WireOp::Upsert,
                    hlc: "0000000000001-0000-d".into(),
                    values: Some(Map::from_iter([("title".into(), json!("Buy milk"))])),
                },
                WireChange {
                    table: "tasks".into(),
                    id: "b".into(),
                    op: WireOp::Delete,
                    hlc: "0000000000002-0000-d".into(),
                    values: None,
                },
            ],
        };
        assert_eq!(
            serde_json::to_value(&request).unwrap(),
            json!({ "changes": [
                { "table": "tasks", "id": "a", "op": "upsert", "hlc": "0000000000001-0000-d",
                  "values": { "title": "Buy milk" } },
                { "table": "tasks", "id": "b", "op": "delete", "hlc": "0000000000002-0000-d" },
            ] })
        );
        let back: PushRequest =
            serde_json::from_value(serde_json::to_value(&request).unwrap()).unwrap();
        assert_eq!(back, request);
    }

    #[test]
    fn a_page_is_camel_case_and_reads_back() {
        let page: ChangesResponse = serde_json::from_str(
            r#"{"rows":[{"table":"tasks","id":"a","deleted":true,"values":{},"hlc":null}],"cursor":7,"hasMore":true}"#,
        )
        .unwrap();
        assert!(page.has_more);
        assert_eq!(page.cursor, 7);
        assert_eq!(page.rows[0].hlc, None);
        assert_eq!(
            serde_json::to_value(&page).unwrap()["hasMore"],
            json!(true),
            "the server writes hasMore"
        );
        // A row without values or a stamp still reads.
        let bare: ChangedRow =
            serde_json::from_str(r#"{"table":"t","id":"i","deleted":false}"#).unwrap();
        assert!(bare.values.is_empty());
    }
}
