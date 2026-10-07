//! Where the terminal remembers which tasks are open.
//!
//! Its own file in its own config directory, for the same reason the CLI keeps
//! its own credentials: the app's preferences are reachable only by something
//! carrying the app's code signature, and writing into them from here would
//! also mean fighting `cfprefsd` for a value the app has cached. So the two
//! front ends remember their outlines separately — expanding a task in the
//! terminal does not expand it in the popover.

use serde_json::{Map, Value, json};
use std::collections::HashSet;
use std::path::PathBuf;

pub struct OutlineStore {
    /// `None` disables persistence — what tests use, and what happens when
    /// there is no list to scope the state to.
    path: Option<PathBuf>,
    list_id: String,
}

impl OutlineStore {
    pub fn disabled() -> Self {
        OutlineStore {
            path: None,
            list_id: String::new(),
        }
    }

    /// Alongside `config.json`, so `$PRIORITY_CONFIG_PATH` moves both together
    /// and a test or the smoke check can't touch the real one.
    pub fn beside_config(config_path: &std::path::Path, list_id: &str) -> Self {
        if list_id.trim().is_empty() {
            return Self::disabled();
        }
        OutlineStore {
            path: config_path.parent().map(|dir| dir.join("outline.json")),
            list_id: list_id.trim().to_string(),
        }
    }

    pub fn load(&self) -> HashSet<i64> {
        let Some(path) = &self.path else {
            return HashSet::new();
        };
        // A missing or malformed file is an empty outline, never an error: this
        // is view state, and refusing to start the UI over it would be absurd.
        let Some(stored) = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        else {
            return HashSet::new();
        };
        stored
            .get(&self.list_id)
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(Value::as_i64).collect())
            .unwrap_or_default()
    }

    /// Read-modify-write, so switching lists doesn't forget the others.
    pub fn save(&self, expanded: &HashSet<i64>) {
        let Some(path) = &self.path else { return };
        let mut stored = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .and_then(|value| match value {
                Value::Object(values) => Some(values),
                _ => None,
            })
            .unwrap_or_else(Map::new);

        if expanded.is_empty() {
            stored.remove(&self.list_id);
        } else {
            let mut ids: Vec<i64> = expanded.iter().copied().collect();
            ids.sort_unstable();
            stored.insert(self.list_id.clone(), json!(ids));
        }

        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(encoded) = serde_json::to_string_pretty(&Value::Object(stored)) {
            let _ = std::fs::write(path, encoded);
        }
    }
}
