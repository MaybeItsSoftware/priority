//! A task's planning and its one codec: the JSON stored in
//! `task_metadata.planningJSON` (start, due date, requirement groups, minimum
//! block, single sitting), its normalisation, and the reasons a planning edit
//! is refused. Replaces Swift's synthesised `Codable` decoding of
//! `TaskPlanning` and Kotlin's `TaskPlanning.toJson`/`fromJson`; both
//! platforms' `TaskPlanning` wrap the functions here.
//!
//! The JSON is what Swift's default `JSONEncoder` writes for `TaskPlanning`:
//! absent optionals are omitted, `startAt` is seconds since 2001-01-01 written
//! shortest (`100`, `812345678.123`), and `/` is escaped as `\/`. Swift's
//! encoder orders the keys by hash, differently in every process, so there is
//! no order of its to match; the fields are written in declaration order, as
//! the core's writes and Kotlin's port always have. Decoding is as strict as
//! Swift's `JSONDecoder`: unknown keys and `null` are ignored, a value of the
//! wrong type refuses the whole blob.

use rusqlite::Connection;
use serde_json::{Map, Value};

use crate::CoreError;
use crate::rows;

/// 2001-01-01T00:00:00Z in Unix milliseconds: Foundation's reference date.
const REFERENCE_DATE_MS: i64 = 978_307_200_000;

/// When and how a task can be worked on. All groups of requirements must be
/// met, and any condition in a group meets it. `TaskPlanning`.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct Planning {
    pub start_at_ms: Option<i64>,
    /// A calendar date, `yyyy-MM-dd`, the task is due by the end of.
    pub due_date: Option<String>,
    pub requirement_groups: Option<Vec<Vec<String>>>,
    pub minimum_block_seconds: Option<i64>,
    pub requires_single_sitting: Option<bool>,
}

impl Planning {
    /// Empty groups and a false single-sitting flag are the same as none, and
    /// a planning with nothing in it is no planning. `TaskPlanning.normalized`.
    pub fn normalized(&self) -> Option<Planning> {
        let mut result = self.clone();
        if result
            .requirement_groups
            .as_ref()
            .is_some_and(Vec::is_empty)
        {
            result.requirement_groups = None;
        }
        if result.requires_single_sitting == Some(false) {
            result.requires_single_sitting = None;
        }
        (result != Planning::default()).then_some(result)
    }

    /// The JSON Swift's `JSONEncoder` writes for this planning. Built by hand:
    /// `serde_json` sorts object keys, and its `preserve_order` feature would
    /// unify into the CLI and unsort the JSON it prints.
    pub fn to_json(&self) -> String {
        let mut fields = Vec::new();
        if let Some(start) = self.start_at_ms {
            fields.push(format!("\"startAt\":{}", reference_seconds(start)));
        }
        if let Some(due) = &self.due_date {
            fields.push(format!("\"dueDate\":{}", Value::from(due.clone())));
        }
        if let Some(groups) = &self.requirement_groups {
            fields.push(format!(
                "\"requirementGroups\":{}",
                Value::from(groups.clone())
            ));
        }
        if let Some(minimum) = self.minimum_block_seconds {
            fields.push(format!("\"minimumBlockSeconds\":{minimum}"));
        }
        if let Some(single) = self.requires_single_sitting {
            fields.push(format!("\"requiresSingleSitting\":{single}"));
        }
        format!("{{{}}}", fields.join(",")).replace('/', "\\/")
    }

    /// Reads the stored JSON as Swift's `JSONDecoder` does, refusing a blob
    /// that is not an object or holds a field of the wrong type.
    pub fn from_json(text: &str) -> Result<Planning, CoreError> {
        let value: Value = serde_json::from_str(text).map_err(|error| unreadable(&error))?;
        let Value::Object(object) = value else {
            return Err(unreadable(&"it is not an object"));
        };
        Ok(Planning {
            start_at_ms: field(&object, "startAt", |value| {
                let seconds = value.as_f64()?;
                let ms = (seconds * 1000.0).round();
                in_i64(ms).and_then(|ms| ms.checked_add(REFERENCE_DATE_MS))
            })?,
            due_date: field(&object, "dueDate", |value| {
                value.as_str().map(str::to_string)
            })?,
            requirement_groups: field(&object, "requirementGroups", |value| {
                value
                    .as_array()?
                    .iter()
                    .map(|group| {
                        group
                            .as_array()?
                            .iter()
                            .map(|id| id.as_str().map(str::to_string))
                            .collect::<Option<Vec<_>>>()
                    })
                    .collect::<Option<Vec<_>>>()
            })?,
            minimum_block_seconds: field(&object, "minimumBlockSeconds", whole_number)?,
            requires_single_sitting: field(&object, "requiresSingleSitting", Value::as_bool)?,
        })
    }
}

/// An optional field: absent or `null` is none, anything `read` cannot make
/// sense of refuses the blob.
fn field<T>(
    object: &Map<String, Value>,
    key: &str,
    read: impl Fn(&Value) -> Option<T>,
) -> Result<Option<T>, CoreError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => read(value)
            .map(Some)
            .ok_or_else(|| unreadable(&format!("{key} has the wrong type"))),
    }
}

/// An `Int` as Swift decodes one: an integer, or a real with no fraction
/// (`600.0`, `1e3`) that fits.
fn whole_number(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let real = value.as_f64()?;
        (real.fract() == 0.0).then_some(real).and_then(in_i64)
    })
}

fn in_i64(real: f64) -> Option<i64> {
    // i64::MAX is not representable; 2^63 is the first value past it.
    (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0)
        .contains(&real)
        .then_some(real as i64)
}

/// Seconds since the reference date, written shortest as Swift writes a
/// `Double`: `100`, not `100.0`.
fn reference_seconds(ms: i64) -> String {
    let seconds = (ms - REFERENCE_DATE_MS) as f64 / 1000.0;
    format!("{seconds}")
}

fn unreadable(detail: &dyn std::fmt::Display) -> CoreError {
    CoreError::Database {
        detail: format!("A task's planning could not be read: {detail}"),
    }
}

/// Reads stored planning JSON. `JSONDecoder().decode(TaskPlanning.self, …)`.
#[uniffi::export]
pub fn task_planning_decode(json: String) -> Result<Planning, CoreError> {
    Planning::from_json(&json)
}

/// The JSON Swift's `JSONEncoder` writes for a planning.
#[uniffi::export]
pub fn task_planning_encode(planning: Planning) -> String {
    planning.to_json()
}

/// Empty groups and a false single-sitting flag collapse to absent, and a
/// planning with nothing left is none. `TaskPlanning.normalized`.
#[uniffi::export]
pub fn task_planning_normalized(planning: Planning) -> Option<Planning> {
    planning.normalized()
}

/// Why a planning edit was refused. `TaskPlanningError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlanningError {
    InvalidCondition,
    InvalidSchedule,
    InvalidMinimum,
    EstimateRequired,
    InvalidDate,
    Unavailable,
}

/// The sentence a refusal shows: the same text the core's own error carries.
#[uniffi::export]
pub fn task_planning_error_message(error: PlanningError) -> String {
    match error {
        PlanningError::InvalidCondition => CoreError::InvalidCondition,
        PlanningError::InvalidSchedule => CoreError::InvalidSchedule,
        PlanningError::InvalidMinimum => CoreError::InvalidMinimum,
        PlanningError::EstimateRequired => CoreError::EstimateRequired,
        PlanningError::InvalidDate => CoreError::InvalidDate,
        PlanningError::Unavailable => {
            return "This task or planned block is no longer available in the current conditions and time window.".to_string();
        }
    }
    .to_string()
}

/// One task's planning, as `taskPlanningValues` maps it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskPlanningEntry {
    pub task_id: String,
    pub planning: Planning,
}

/// Every task's planning: the stored JSON with the start from its own
/// column, normalised, for the rows that carry either. A blob that cannot be
/// read refuses the whole read, as Swift's decoder did.
/// `WorkspaceStore.taskPlanningValues`.
pub fn planning_values(connection: &Connection) -> Result<Vec<TaskPlanningEntry>, CoreError> {
    let mut result = Vec::new();
    for row in rows::planning_metadata(connection)? {
        let mut planning = match &row.planning_json {
            Some(json) => Planning::from_json(json)?,
            None => Planning::default(),
        };
        planning.start_at_ms = row.start_at_ms;
        if let Some(planning) = planning.normalized() {
            result.push(TaskPlanningEntry {
                task_id: row.task_id,
                planning,
            });
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
