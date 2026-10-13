//! Filter lists: saved, named rule sets evaluated over every task.
//!
//! A filter list is not a place tasks live; it is a question asked of all of
//! them — "tagged work and due this week", "high priority and not blocked".
//! Its rules are stored as JSON in `filter_lists.rulesJSON` and evaluated
//! here, so the Mac, the phones and the CLI cannot disagree about which tasks
//! one shows.
//!
//! **The definition.** A [`FilterDefinition`] says which tasks are shown by
//! status (`show`: open, done or all), whether every rule must hold or any
//! one (`match_mode`), and the rules. A rule is a field, an operator and a
//! value, all strings, so it crosses to every client and into JSON without a
//! per-platform enum to keep in step; [`filter_rule_catalog`] is the
//! vocabulary, and the clients build their editors from it. A definition
//! with no rules matches every task its `show` admits.
//!
//! **The scope.** Only tasks a board could draw are considered: in a list
//! that is neither archived nor completed, not a list item, not a list's
//! visible root (an imported wrapper), and not inside a closed or archived
//! list item. Within that, a task matches when its status is one `show`
//! admits and the rules hold.
//!
//! **Built in.** Today and Everything ship as definitions
//! ([`builtin_filter_lists`]) rather than rows: Everything is "open tasks", and
//! Today is "open tasks planned for today or due by today". The Mac still
//! draws Today as the day and Everything through its combined board; these
//! are the same questions for a client, such as the CLI, that has only the
//! evaluator. Inbox stays a real list: it is where new tasks land.
//!
//! **Unknown rules.** A rule this build does not know — written by a newer
//! client — is skipped when evaluating rather than refused, so an older
//! device shows a broader list instead of an empty one. Saving one is
//! refused ([`validate`]), so nothing written here is unreadable.
//!
//! Rows are journalled, so creating, editing and deleting are undoable, and
//! synced like lists. Ids are random; there is nothing to merge two devices'
//! filter lists on.

use std::collections::{HashMap, HashSet};

use chrono::{Duration, NaiveDate};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use serde::{Deserialize, Serialize};

use crate::CoreError;
use crate::board::{self, BoardRead};
use crate::habits::local_day;
use crate::journal;
use crate::lists::new_id;
use crate::periodic;
use crate::planning::Planning;
use crate::records::{TaskRow, optional_ms, required_ms};
use crate::time::{decode_strings, non_empty_name, stored};
use crate::workspace::CoreWorkspace;

/// The id Today's built-in definition goes by.
pub const BUILTIN_TODAY_ID: &str = "builtin:today";
/// The id Everything's built-in definition goes by.
pub const BUILTIN_EVERYTHING_ID: &str = "builtin:everything";
/// The one rule of a definition whose stored JSON did not read. It matches
/// nothing, unlike a rule that is merely unknown.
const UNREADABLE: &str = "unreadable";

/// One condition: `field` compared by `op` with `value` (empty when the
/// operator takes none). See [`filter_rule_catalog`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FilterRule {
    pub field: String,
    pub op: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
}

/// What a filter list shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct FilterDefinition {
    /// "all" (every rule holds) or "any" (at least one does).
    #[serde(rename = "match", default = "all")]
    pub match_mode: String,
    /// "open", "done" (completed or cancelled) or "all".
    #[serde(default = "open")]
    pub show: String,
    #[serde(default)]
    pub rules: Vec<FilterRule>,
}

fn all() -> String {
    "all".into()
}

fn open() -> String {
    "open".into()
}

impl Default for FilterDefinition {
    fn default() -> Self {
        Self {
            match_mode: all(),
            show: open(),
            rules: Vec::new(),
        }
    }
}

/// A row of `filter_lists`, its rules decoded; or a built-in definition,
/// which has no row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FilterListRow {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    /// An SF Symbol name on Apple platforms; clients without it draw their
    /// own default.
    pub icon: Option<String>,
    pub color_hex: Option<String>,
    pub definition: FilterDefinition,
    pub sort_order: i64,
    /// Today and Everything: shipped, not stored, and not editable.
    pub is_builtin: bool,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// One operator a field takes, and what kind of value it needs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterOpSpec {
    pub op: String,
    /// What an editor shows for it, after the field's label.
    pub label: String,
    /// "none", "text", "tag", "number", "days", "minutes", "date"
    /// (`yyyy-MM-dd`), "lists" (list ids, comma separated), "folder" (a
    /// folder id) or "column" (a board column id).
    pub value_kind: String,
}

/// A field a rule can test, and its operators.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterFieldSpec {
    pub field: String,
    pub label: String,
    pub ops: Vec<FilterOpSpec>,
}

fn spec(field: &str, label: &str, ops: &[(&str, &str, &str)]) -> FilterFieldSpec {
    FilterFieldSpec {
        field: field.into(),
        label: label.into(),
        ops: ops
            .iter()
            .map(|(op, label, kind)| FilterOpSpec {
                op: (*op).into(),
                label: (*label).into(),
                value_kind: (*kind).into(),
            })
            .collect(),
    }
}

/// Every field a rule can test, in the order an editor offers them.
#[uniffi::export]
pub fn filter_rule_catalog() -> Vec<FilterFieldSpec> {
    let dates: &[(&str, &str, &str)] = &[
        ("overdue", "is overdue", "none"),
        ("today", "is today", "none"),
        ("within", "is within (days, overdue included)", "days"),
        ("before", "is before", "date"),
        ("on", "is on", "date"),
        ("after", "is after", "date"),
        ("any", "is set", "none"),
        ("none", "is not set", "none"),
    ];
    vec![
        spec(
            "tag",
            "Tag",
            &[
                ("has", "has", "tag"),
                ("lacks", "does not have", "tag"),
                ("any", "has any tag", "none"),
                ("none", "has no tags", "none"),
            ],
        ),
        spec("due", "Due date", dates),
        spec(
            "start",
            "Start date",
            &[
                ("started", "has passed", "none"),
                ("later", "is still to come", "none"),
                ("within", "is within (days)", "days"),
                ("before", "is before", "date"),
                ("on", "is on", "date"),
                ("after", "is after", "date"),
                ("any", "is set", "none"),
                ("none", "is not set", "none"),
            ],
        ),
        spec(
            "priority",
            "Priority",
            &[
                ("at-least", "is at least as urgent as", "number"),
                ("at-most", "is no more urgent than", "number"),
                ("is", "is", "number"),
                ("any", "is set", "none"),
                ("none", "is not set", "none"),
            ],
        ),
        spec(
            "list",
            "List",
            &[
                ("in", "is one of", "lists"),
                ("not-in", "is not one of", "lists"),
            ],
        ),
        spec(
            "folder",
            "Folder",
            &[
                ("in", "is inside", "folder"),
                ("not-in", "is not inside", "folder"),
            ],
        ),
        spec(
            "today",
            "Planned for today",
            &[("is", "yes", "none"), ("is-not", "no", "none")],
        ),
        spec(
            "blocked",
            "Blocked",
            &[("is", "yes", "none"), ("is-not", "no", "none")],
        ),
        spec(
            "waiting",
            "Waiting on",
            &[
                ("is", "is waiting", "none"),
                ("is-not", "is not waiting", "none"),
                ("on", "is waiting on", "text"),
            ],
        ),
        spec(
            "estimate",
            "Estimate",
            &[
                ("at-least", "is at least (minutes)", "minutes"),
                ("at-most", "is at most (minutes)", "minutes"),
                ("any", "is set", "none"),
                ("none", "is not set", "none"),
            ],
        ),
        spec(
            "text",
            "Title or notes",
            &[
                ("contains", "contains", "text"),
                ("lacks", "does not contain", "text"),
            ],
        ),
        spec(
            "column",
            "Board column",
            &[("is", "is", "column"), ("is-not", "is not", "column")],
        ),
    ]
}

/// Today and Everything as definitions, in sidebar order.
#[uniffi::export]
pub fn builtin_filter_lists() -> Vec<FilterListRow> {
    let row = |id: &str, name: &str, icon: &str, order: i64, definition| FilterListRow {
        id: id.into(),
        workspace_id: String::new(),
        name: name.into(),
        icon: Some(icon.into()),
        color_hex: None,
        definition,
        sort_order: order,
        is_builtin: true,
        created_at_ms: 0,
        updated_at_ms: 0,
    };
    let rule = |field: &str, op: &str, value: &str| FilterRule {
        field: field.into(),
        op: op.into(),
        value: value.into(),
    };
    vec![
        row(
            BUILTIN_TODAY_ID,
            "Today",
            "sun.max",
            0,
            FilterDefinition {
                match_mode: "any".into(),
                show: open(),
                rules: vec![rule("today", "is", ""), rule("due", "within", "0")],
            },
        ),
        row(
            BUILTIN_EVERYTHING_ID,
            "Everything",
            "tray.full",
            1,
            FilterDefinition::default(),
        ),
    ]
}

/// A definition read from its stored JSON. Lenient about what it does not
/// know (see the module notes), strict about JSON that is not a definition.
#[uniffi::export]
pub fn parse_filter_definition(json: String) -> Result<FilterDefinition, CoreError> {
    let invalid = |detail: String| CoreError::InvalidFilter {
        detail: format!("That is not a filter definition: {detail}."),
    };
    let value: serde_json::Value =
        serde_json::from_str(&json).map_err(|error| invalid(error.to_string()))?;
    if !value.is_object() {
        return Err(invalid("it is not a JSON object".into()));
    }
    serde_json::from_value(value).map_err(|error| invalid(error.to_string()))
}

/// A definition as `rulesJSON` stores it.
#[uniffi::export]
pub fn filter_definition_json(definition: FilterDefinition) -> String {
    serde_json::to_string(&definition).expect("a definition always serialises")
}

/// `definition` tidied — values trimmed, tags without `#`, list ids without
/// blanks — or the first reason it cannot be saved.
#[uniffi::export]
pub fn validate_filter_definition(
    definition: FilterDefinition,
) -> Result<FilterDefinition, CoreError> {
    validate(&definition)
}

/// A one-line reading of `definition`, for a subtitle or the CLI:
/// "Open tasks where tag has work and due is within 7 days".
#[uniffi::export]
pub fn describe_filter_definition(definition: FilterDefinition) -> String {
    let what = match definition.show.as_str() {
        "done" => "Finished tasks",
        "all" => "All tasks",
        _ => "Open tasks",
    };
    if definition.rules.is_empty() {
        return what.to_string();
    }
    let catalog = filter_rule_catalog();
    let joiner = if definition.match_mode == "any" {
        " or "
    } else {
        " and "
    };
    let parts: Vec<String> = definition
        .rules
        .iter()
        .map(|rule| describe_rule(rule, &catalog))
        .collect();
    format!("{what} where {}", parts.join(joiner))
}

/// One rule in words, "due is within 7 days", as `describe_filter_definition`
/// joins them.
pub(crate) fn describe_rule(rule: &FilterRule, catalog: &[FilterFieldSpec]) -> String {
    let field = catalog.iter().find(|spec| spec.field == rule.field);
    let op = field.and_then(|spec| spec.ops.iter().find(|op| op.op == rule.op));
    match (field, op) {
        (Some(field), Some(op)) => {
            let label = op.label.split(" (").next().unwrap_or(&op.label);
            let mut text = format!("{} {}", field.label.to_lowercase(), label);
            if op.value_kind != "none" {
                text.push(' ');
                text.push_str(&rule.value);
                if op.value_kind == "days" {
                    text.push_str(" days");
                } else if op.value_kind == "minutes" {
                    text.push_str(" minutes");
                }
            }
            text
        }
        _ => format!("{} {} {}", rule.field, rule.op, rule.value)
            .trim()
            .to_string(),
    }
}

pub(crate) fn validate(definition: &FilterDefinition) -> Result<FilterDefinition, CoreError> {
    let invalid = |detail: String| CoreError::InvalidFilter { detail };
    if !matches!(definition.match_mode.as_str(), "all" | "any") {
        return Err(invalid(format!(
            "Match \"{}\" is not all or any.",
            definition.match_mode
        )));
    }
    if !matches!(definition.show.as_str(), "open" | "done" | "all") {
        return Err(invalid(format!(
            "Show \"{}\" is not open, done or all.",
            definition.show
        )));
    }
    let catalog = filter_rule_catalog();
    let mut rules = Vec::with_capacity(definition.rules.len());
    for rule in &definition.rules {
        let field = catalog
            .iter()
            .find(|spec| spec.field == rule.field)
            .ok_or_else(|| invalid(format!("There is no filter field \"{}\".", rule.field)))?;
        let op = field
            .ops
            .iter()
            .find(|op| op.op == rule.op)
            .ok_or_else(|| {
                invalid(format!(
                    "{} cannot be compared by \"{}\".",
                    field.label, rule.op
                ))
            })?;
        let raw = rule.value.trim();
        let value = match op.value_kind.as_str() {
            "none" => String::new(),
            "number" | "days" | "minutes" => {
                let number: i64 = raw.parse().map_err(|_| {
                    invalid(format!(
                        "{} {} needs a whole number.",
                        field.label, op.label
                    ))
                })?;
                if number < 0 && op.value_kind != "number" {
                    return Err(invalid(format!(
                        "{} {} cannot be negative.",
                        field.label, op.label
                    )));
                }
                number.to_string()
            }
            "date" => {
                NaiveDate::parse_from_str(raw, "%Y-%m-%d").map_err(|_| {
                    invalid(format!(
                        "{} {} needs a date written as yyyy-mm-dd.",
                        field.label, op.label
                    ))
                })?;
                raw.to_string()
            }
            "tag" => {
                let tag = normalized_tag(raw);
                if tag.is_empty() {
                    return Err(invalid(format!(
                        "{} {} needs a tag.",
                        field.label, op.label
                    )));
                }
                tag
            }
            "lists" => {
                let ids: Vec<&str> = raw
                    .split(',')
                    .map(str::trim)
                    .filter(|id| !id.is_empty())
                    .collect();
                if ids.is_empty() {
                    return Err(invalid(format!(
                        "{} {} needs at least one list.",
                        field.label, op.label
                    )));
                }
                ids.join(",")
            }
            _ => {
                if raw.is_empty() {
                    return Err(invalid(format!(
                        "{} {} needs a value.",
                        field.label, op.label
                    )));
                }
                raw.to_string()
            }
        };
        rules.push(FilterRule {
            field: rule.field.clone(),
            op: rule.op.clone(),
            value,
        });
    }
    Ok(FilterDefinition {
        match_mode: definition.match_mode.clone(),
        show: definition.show.clone(),
        rules,
    })
}

/// A tag as rules compare it: trimmed, without a leading `#`, lowercased.
pub(crate) fn normalized_tag(tag: &str) -> String {
    tag.trim().trim_start_matches('#').trim().to_lowercase()
}

// MARK: - Rows

fn has_table(connection: &Connection) -> Result<bool, CoreError> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'filter_lists')",
        [],
        |row| row.get(0),
    )?)
}

fn from_row(row: &Row) -> rusqlite::Result<FilterListRow> {
    let json: String = row.get("rulesJSON")?;
    Ok(FilterListRow {
        id: row.get("id")?,
        workspace_id: row.get("workspaceId")?,
        name: row.get("name")?,
        icon: row.get("icon")?,
        color_hex: row.get("colorHex")?,
        // A blob that does not read is a filter nobody can evaluate; it shows
        // nothing rather than failing every read of the sidebar.
        definition: serde_json::from_str(&json).unwrap_or_else(|_| FilterDefinition {
            rules: vec![FilterRule {
                field: UNREADABLE.into(),
                op: UNREADABLE.into(),
                value: String::new(),
            }],
            ..FilterDefinition::default()
        }),
        sort_order: row.get("sortOrder")?,
        is_builtin: false,
        created_at_ms: required_ms(row, "createdAt")?,
        updated_at_ms: required_ms(row, "updatedAt")?,
    })
}

/// The workspace's filter lists in sidebar order. Empty on a database not
/// yet migrated to v23.
pub fn filter_lists(
    connection: &Connection,
    workspace_id: &str,
) -> Result<Vec<FilterListRow>, CoreError> {
    if !has_table(connection)? {
        return Ok(Vec::new());
    }
    let mut statement = connection.prepare_cached(
        "SELECT * FROM filter_lists WHERE workspaceId = ?1 ORDER BY sortOrder, createdAt, id",
    )?;
    let rows = statement.query_map([workspace_id], from_row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// One filter list by id, or a built-in one by its id.
pub fn filter_list(connection: &Connection, id: &str) -> Result<Option<FilterListRow>, CoreError> {
    if let Some(builtin) = builtin_filter_lists().into_iter().find(|row| row.id == id) {
        return Ok(Some(builtin));
    }
    if !has_table(connection)? {
        return Ok(None);
    }
    Ok(connection
        .query_row("SELECT * FROM filter_lists WHERE id = ?1", [id], from_row)
        .optional()?)
}

fn require(connection: &Connection, id: &str) -> Result<FilterListRow, CoreError> {
    filter_list(connection, id)?
        .filter(|row| !row.is_builtin)
        .ok_or_else(|| CoreError::MissingFilterList { id: id.to_string() })
}

fn blank_to_none(text: Option<&str>) -> Option<String> {
    text.map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

/// Creates a filter list at the end of the workspace's, and returns it.
pub fn create(
    transaction: &Transaction,
    workspace_id: &str,
    name: &str,
    icon: Option<&str>,
    color_hex: Option<&str>,
    definition: &FilterDefinition,
    now_ms: i64,
) -> Result<FilterListRow, CoreError> {
    let name = non_empty_name(name)?;
    let definition = validate(definition)?;
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?1)",
        [workspace_id],
        |row| row.get(0),
    )?;
    if !exists {
        return Err(CoreError::InvalidFilter {
            detail: format!("No workspace with id {workspace_id}."),
        });
    }
    let sort_order: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM filter_lists WHERE workspaceId = ?1",
        [workspace_id],
        |row| row.get(0),
    )?;
    let id = new_id();
    let now = stored(now_ms);
    transaction.execute(
        "INSERT INTO filter_lists (id, workspaceId, name, icon, colorHex, rulesJSON, sortOrder, createdAt, updatedAt)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)",
        params![
            id,
            workspace_id,
            name,
            blank_to_none(icon),
            blank_to_none(color_hex),
            filter_definition_json(definition),
            sort_order,
            now
        ],
    )?;
    require(transaction, &id)
}

/// Saves a filter list's name, icon, colour and rules together, as its sheet
/// does. Writes nothing when nothing changed.
pub fn update(
    transaction: &Transaction,
    id: &str,
    name: &str,
    icon: Option<&str>,
    color_hex: Option<&str>,
    definition: &FilterDefinition,
    now_ms: i64,
) -> Result<FilterListRow, CoreError> {
    let current = require(transaction, id)?;
    let name = non_empty_name(name)?;
    let definition = validate(definition)?;
    let (icon, color_hex) = (blank_to_none(icon), blank_to_none(color_hex));
    if current.name != name
        || current.icon != icon
        || current.color_hex != color_hex
        || current.definition != definition
    {
        transaction.execute(
            "UPDATE filter_lists SET name = ?1, icon = ?2, colorHex = ?3, rulesJSON = ?4, updatedAt = ?5
             WHERE id = ?6",
            params![
                name,
                icon,
                color_hex,
                filter_definition_json(definition),
                stored(now_ms),
                id
            ],
        )?;
    }
    require(transaction, id)
}

/// Renames a filter list, keeping everything else.
pub fn rename(
    transaction: &Transaction,
    id: &str,
    name: &str,
    now_ms: i64,
) -> Result<(), CoreError> {
    let current = require(transaction, id)?;
    update(
        transaction,
        id,
        name,
        current.icon.as_deref(),
        current.color_hex.as_deref(),
        &current.definition,
        now_ms,
    )
    .map(|_| ())
}

/// Deletes a filter list. Its tasks are untouched: it never held any.
pub fn delete(transaction: &Transaction, id: &str) -> Result<(), CoreError> {
    require(transaction, id)?;
    transaction.execute("DELETE FROM filter_lists WHERE id = ?1", [id])?;
    Ok(())
}

/// Moves a filter list to `index` among the workspace's, renumbering them.
pub fn move_to(
    transaction: &Transaction,
    id: &str,
    index: u32,
    now_ms: i64,
) -> Result<(), CoreError> {
    let moving = require(transaction, id)?;
    let mut order: Vec<FilterListRow> = filter_lists(transaction, &moving.workspace_id)?
        .into_iter()
        .filter(|row| row.id != id)
        .collect();
    order.insert((index as usize).min(order.len()), moving);
    let now = stored(now_ms);
    for (position, row) in order.iter().enumerate() {
        if row.sort_order != position as i64 {
            transaction.execute(
                "UPDATE filter_lists SET sortOrder = ?1, updatedAt = ?2 WHERE id = ?3",
                params![position as i64, now, row.id],
            )?;
        }
    }
    Ok(())
}

// MARK: - Evaluation

/// What the rules read about one task.
pub(crate) struct Facts {
    pub(crate) parent_id: Option<String>,
    pub(crate) id: String,
    pub(crate) list_id: String,
    pub(crate) title: String,
    pub(crate) notes: String,
    pub(crate) status: String,
    pub(crate) due_at_ms: Option<i64>,
    pub(crate) due_date: Option<NaiveDate>,
    pub(crate) start_at_ms: Option<i64>,
    pub(crate) estimate_seconds: Option<i64>,
    pub(crate) priority: Option<i64>,
    pub(crate) tags: Vec<String>,
    pub(crate) column: Option<String>,
    pub(crate) waiting_on: Option<String>,
}

/// What the rules read about the workspace: the clock, which tasks are
/// blocked, and the folders each list sits inside.
pub(crate) struct Context {
    pub(crate) now_ms: i64,
    pub(crate) zone: Tz,
    pub(crate) today: NaiveDate,
    pub(crate) blocked: HashSet<String>,
    pub(crate) folders_of_list: HashMap<String, Vec<String>>,
}

pub(crate) fn context(
    connection: &Connection,
    now_ms: i64,
    zone: &str,
) -> Result<Context, CoreError> {
    let zone = periodic::zone(zone);
    let blocked = crate::dependencies::blocked_task_ids(connection)?
        .into_iter()
        .collect();
    let mut parent_of: HashMap<String, Option<String>> = HashMap::new();
    {
        let mut statement =
            connection.prepare_cached("SELECT id, parentFolderId FROM list_folders")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        for row in rows {
            let (id, parent): (String, Option<String>) = row?;
            parent_of.insert(id, parent);
        }
    }
    let mut folders_of_list = HashMap::new();
    let mut statement = connection
        .prepare_cached("SELECT id, folderId FROM task_lists WHERE folderId IS NOT NULL")?;
    let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
    for row in rows {
        let (list, folder): (String, String) = row?;
        let mut chain = Vec::new();
        let mut next = Some(folder);
        // A cycle in the parent chain ends rather than hangs.
        while let Some(id) = next.take() {
            if chain.contains(&id) {
                break;
            }
            next = parent_of.get(&id).cloned().flatten();
            chain.push(id);
        }
        folders_of_list.insert(list, chain);
    }
    Ok(Context {
        now_ms,
        zone,
        today: local_day(now_ms, zone),
        blocked,
        folders_of_list,
    })
}

fn has_column(connection: &Connection, table: &str, column: &str) -> Result<bool, CoreError> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2)",
        params![table, column],
        |row| row.get(0),
    )?)
}

/// Which tasks [`facts_in`] reads.
pub(crate) enum FactScope<'a> {
    Everything,
    Lists(&'a [String]),
    Task(&'a str),
}

/// Every task `show` admits, as the rules read it. List items are left out:
/// a filter list shows tasks.
fn facts(connection: &Connection, show: &str) -> Result<Vec<Facts>, CoreError> {
    facts_in(connection, show, FactScope::Everything)
}

/// [`facts`], limited to `scope`.
pub(crate) fn facts_in(
    connection: &Connection,
    show: &str,
    scope: FactScope,
) -> Result<Vec<Facts>, CoreError> {
    let (within, values): (String, Vec<&str>) = match scope {
        FactScope::Everything => (String::new(), Vec::new()),
        FactScope::Lists(ids) => {
            if ids.is_empty() {
                return Ok(Vec::new());
            }
            (
                format!(" AND t.listId IN ({})", vec!["?"; ids.len()].join(", ")),
                ids.iter().map(String::as_str).collect(),
            )
        }
        FactScope::Task(id) => (" AND t.id = ?".to_string(), vec![id]),
    };
    let status = match show {
        "done" => "t.status <> 'open'",
        "all" => "1",
        _ => "t.status = 'open'",
    };
    // `waitingOn` arrived in v20; the CLI may read an older database.
    let waiting = if has_column(connection, "task_metadata", "waitingOn")? {
        "m.waitingOn"
    } else {
        "NULL"
    };
    let mut statement = connection.prepare(&format!(
        "SELECT t.id, t.listId, t.title, t.notes, t.status, t.dueAt, t.estimateSeconds,
                m.priority, m.startAt, m.tagsJSON, m.kanbanColumn, m.planningJSON, {waiting},
                t.parentTaskId
         FROM tasks t LEFT JOIN task_metadata m ON m.taskId = t.id
         WHERE COALESCE(t.itemKind, 'task') <> 'list' AND {status}{within}"
    ))?;
    let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
        let planning = row
            .get::<_, Option<String>>(11)?
            .as_deref()
            .and_then(|json| Planning::from_json(json).ok())
            .unwrap_or_default();
        let start = optional_ms(row, 8)?.or(planning.start_at_ms);
        Ok(Facts {
            parent_id: row.get(13)?,
            id: row.get(0)?,
            list_id: row.get(1)?,
            title: row.get::<_, String>(2)?.to_lowercase(),
            notes: row
                .get::<_, Option<String>>(3)?
                .unwrap_or_default()
                .to_lowercase(),
            status: row.get(4)?,
            due_at_ms: optional_ms(row, 5)?,
            due_date: planning
                .due_date
                .as_deref()
                .and_then(|date| NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()),
            start_at_ms: start,
            estimate_seconds: row.get(6)?,
            priority: row.get(7)?,
            tags: row
                .get::<_, Option<String>>(9)?
                .map(|json| decode_strings(&json))
                .unwrap_or_default()
                .iter()
                .map(|tag| normalized_tag(tag))
                .filter(|tag| !tag.is_empty())
                .collect(),
            column: row.get(10)?,
            waiting_on: row.get(12)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

impl Facts {
    /// The day the task is due on, from its deadline or its due date.
    pub(crate) fn due_day(&self, zone: Tz) -> Option<NaiveDate> {
        self.due_at_ms
            .map(|at| local_day(at, zone))
            .into_iter()
            .chain(self.due_date)
            .min()
    }

    fn is_waiting(&self) -> bool {
        self.column.as_deref() == Some("waiting-on")
    }
}

fn number(value: &str) -> Option<i64> {
    value.trim().parse().ok()
}

fn date(value: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(value.trim(), "%Y-%m-%d").ok()
}

fn days_from(today: NaiveDate, days: i64) -> NaiveDate {
    today
        .checked_add_signed(Duration::days(days))
        .unwrap_or(NaiveDate::MAX)
}

/// Whether `rule` holds for `task`; `None` for a rule this build does not
/// know, which is skipped.
pub(crate) fn holds(rule: &FilterRule, task: &Facts, context: &Context) -> Option<bool> {
    let value = rule.value.as_str();
    let compare_day = |day: Option<NaiveDate>| -> Option<bool> {
        Some(match rule.op.as_str() {
            "any" => day.is_some(),
            "none" => day.is_none(),
            "today" => day == Some(context.today),
            "within" => {
                let last = days_from(context.today, number(value)?);
                day.is_some_and(|day| day <= last)
            }
            "before" => day.zip(date(value)).is_some_and(|(day, at)| day < at),
            "on" => day.zip(date(value)).is_some_and(|(day, at)| day == at),
            "after" => day.zip(date(value)).is_some_and(|(day, at)| day > at),
            _ => return None,
        })
    };
    Some(match (rule.field.as_str(), rule.op.as_str()) {
        ("tag", "has") => task.tags.contains(&normalized_tag(value)),
        ("tag", "lacks") => !task.tags.contains(&normalized_tag(value)),
        ("tag", "any") => !task.tags.is_empty(),
        ("tag", "none") => task.tags.is_empty(),
        ("due", "overdue") => {
            let past_deadline = task.due_at_ms.is_some_and(|at| at < context.now_ms);
            let past_day = task.due_date.is_some_and(|day| day < context.today);
            past_deadline || past_day
        }
        ("due", _) => compare_day(task.due_day(context.zone))?,
        ("start", "started") => task.start_at_ms.is_some_and(|at| at <= context.now_ms),
        ("start", "later") => task.start_at_ms.is_some_and(|at| at > context.now_ms),
        ("start", "within") => task.start_at_ms.is_some_and(|at| {
            number(value)
                .is_some_and(|days| local_day(at, context.zone) <= days_from(context.today, days))
        }),
        ("start", _) => compare_day(task.start_at_ms.map(|at| local_day(at, context.zone)))?,
        // 1 is the most urgent, so "at least as urgent as 2" is 1 or 2.
        ("priority", "at-least") => task
            .priority
            .zip(number(value))
            .is_some_and(|(p, n)| p <= n),
        ("priority", "at-most") => task
            .priority
            .zip(number(value))
            .is_some_and(|(p, n)| p >= n),
        ("priority", "is") => task
            .priority
            .zip(number(value))
            .is_some_and(|(p, n)| p == n),
        ("priority", "any") => task.priority.is_some(),
        ("priority", "none") => task.priority.is_none(),
        ("list", "in") => value.split(',').any(|id| id.trim() == task.list_id),
        ("list", "not-in") => !value.split(',').any(|id| id.trim() == task.list_id),
        ("folder", op @ ("in" | "not-in")) => {
            let inside = context
                .folders_of_list
                .get(&task.list_id)
                .is_some_and(|chain| chain.iter().any(|id| id == value.trim()));
            inside == (op == "in")
        }
        ("today", "is") => task.column.as_deref() == Some("today"),
        ("today", "is-not") => task.column.as_deref() != Some("today"),
        ("blocked", "is") => context.blocked.contains(&task.id),
        ("blocked", "is-not") => !context.blocked.contains(&task.id),
        ("waiting", "is") => task.is_waiting(),
        ("waiting", "is-not") => !task.is_waiting(),
        ("waiting", "on") => {
            task.is_waiting()
                && task
                    .waiting_on
                    .as_deref()
                    .is_some_and(|who| who.to_lowercase().contains(&value.trim().to_lowercase()))
        }
        ("estimate", "at-least") => task
            .estimate_seconds
            .zip(number(value))
            .is_some_and(|(seconds, minutes)| seconds >= minutes * 60),
        ("estimate", "at-most") => task
            .estimate_seconds
            .zip(number(value))
            .is_some_and(|(seconds, minutes)| seconds <= minutes * 60),
        ("estimate", "any") => task.estimate_seconds.is_some(),
        ("estimate", "none") => task.estimate_seconds.is_none(),
        ("text", op @ ("contains" | "lacks")) => {
            let needle = value.trim().to_lowercase();
            let found = task.title.contains(&needle) || task.notes.contains(&needle);
            found == (op == "contains")
        }
        ("column", "is") => task.column.as_deref() == Some(value.trim()),
        ("column", "is-not") => task.column.as_deref() != Some(value.trim()),
        (UNREADABLE, _) => false,
        _ => return None,
    })
}

pub(crate) fn matches(definition: &FilterDefinition, task: &Facts, context: &Context) -> bool {
    let shown = match definition.show.as_str() {
        "done" => task.status != "open",
        "all" => true,
        _ => task.status == "open",
    };
    if !shown {
        return false;
    }
    let mut known = definition
        .rules
        .iter()
        .filter_map(|rule| holds(rule, task, context))
        .peekable();
    if known.peek().is_none() {
        return true;
    }
    if definition.match_mode == "any" {
        known.any(|held| held)
    } else {
        known.all(|held| held)
    }
}

/// The ids of every task `definition` matches, before the scope (see the
/// module notes) is applied.
pub fn matching_ids(
    connection: &Connection,
    definition: &FilterDefinition,
    now_ms: i64,
    zone: &str,
) -> Result<HashSet<String>, CoreError> {
    let context = context(connection, now_ms, zone)?;
    Ok(facts(connection, &definition.show)?
        .into_iter()
        .filter(|task| matches(definition, task, &context))
        .map(|task| task.id)
        .collect())
}

/// The lists a filter list draws from: every open list of the workspace, the
/// inbox first, then in their order.
pub fn scope_list_ids(
    connection: &Connection,
    workspace_id: &str,
) -> Result<Vec<String>, CoreError> {
    let mut statement = connection.prepare_cached(
        "SELECT id FROM task_lists
         WHERE workspaceId = ?1 AND isArchived = 0 AND completedAt IS NULL
         ORDER BY systemRole IS NOT 'inbox', sortOrder, createdAt, id",
    )?;
    let rows = statement.query_map([workspace_id], |row| row.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The tasks `definition` shows across the workspace, in board order: list
/// by list, each in outline order.
pub fn tasks(
    connection: &Connection,
    workspace_id: &str,
    definition: &FilterDefinition,
    now_ms: i64,
    zone: &str,
) -> Result<Vec<TaskRow>, CoreError> {
    let only = matching_ids(connection, definition, now_ms, zone)?;
    let lists = scope_list_ids(connection, workspace_id)?;
    board::cards_of(connection, &lists, Some(&only))
}

/// A filter list's board over `list_ids` (the client's open lists in sidebar
/// order): `board::combined_board` with its cards limited to the matches.
pub fn board(
    connection: &Connection,
    definition: &FilterDefinition,
    list_ids: &[String],
    hide_completed_before_ms: Option<i64>,
    now_ms: i64,
    zone: &str,
) -> Result<BoardRead, CoreError> {
    let only = matching_ids(connection, definition, now_ms, zone)?;
    board::combined_board_of(connection, list_ids, hide_completed_before_ms, Some(&only))
}

// MARK: - The handle

#[uniffi::export]
impl CoreWorkspace {
    /// The workspace's filter lists in sidebar order; not the built-in ones
    /// (`builtin_filter_lists`).
    pub fn filter_lists(&self, workspace_id: String) -> Result<Vec<FilterListRow>, CoreError> {
        filter_lists(&self.lock(), &workspace_id)
    }

    /// One filter list, stored or built in.
    pub fn filter_list(&self, id: String) -> Result<Option<FilterListRow>, CoreError> {
        filter_list(&self.lock(), &id)
    }

    /// Creates a filter list as one "New Filter List" step.
    pub fn create_filter_list(
        &self,
        workspace_id: String,
        name: String,
        icon: Option<String>,
        color_hex: Option<String>,
        definition: FilterDefinition,
        now_ms: i64,
    ) -> Result<FilterListRow, CoreError> {
        journal::journalled(&mut self.lock(), "New Filter List", |tx| {
            create(
                tx,
                &workspace_id,
                &name,
                icon.as_deref(),
                color_hex.as_deref(),
                &definition,
                now_ms,
            )
        })
    }

    /// Saves a filter list's name, icon, colour and rules as one "Edit Filter
    /// List" step.
    pub fn update_filter_list(
        &self,
        id: String,
        name: String,
        icon: Option<String>,
        color_hex: Option<String>,
        definition: FilterDefinition,
        now_ms: i64,
    ) -> Result<FilterListRow, CoreError> {
        journal::journalled(&mut self.lock(), "Edit Filter List", |tx| {
            update(
                tx,
                &id,
                &name,
                icon.as_deref(),
                color_hex.as_deref(),
                &definition,
                now_ms,
            )
        })
    }

    /// Renames a filter list as one "Rename Filter List" step.
    pub fn rename_filter_list(
        &self,
        id: String,
        name: String,
        now_ms: i64,
    ) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Rename Filter List", |tx| {
            rename(tx, &id, &name, now_ms)
        })
    }

    /// Deletes a filter list as one "Delete Filter List" step.
    pub fn delete_filter_list(&self, id: String) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Delete Filter List", |tx| delete(tx, &id))
    }

    /// Moves a filter list to `index` as one "Move Filter List" step.
    pub fn move_filter_list(&self, id: String, index: u32, now_ms: i64) -> Result<(), CoreError> {
        journal::journalled(&mut self.lock(), "Move Filter List", |tx| {
            move_to(tx, &id, index, now_ms)
        })
    }

    /// The tasks `definition` shows across the workspace, in board order.
    pub fn filter_list_tasks(
        &self,
        workspace_id: String,
        definition: FilterDefinition,
        now_ms: i64,
        zone: String,
    ) -> Result<Vec<TaskRow>, CoreError> {
        tasks(&self.read(), &workspace_id, &definition, now_ms, &zone)
    }

    /// A filter list's board over `list_ids`, as `combined_board` reads one.
    pub fn filter_list_board(
        &self,
        definition: FilterDefinition,
        list_ids: Vec<String>,
        hide_completed_before_ms: Option<i64>,
        now_ms: i64,
        zone: String,
    ) -> Result<BoardRead, CoreError> {
        board(
            &self.read(),
            &definition,
            &list_ids,
            hide_completed_before_ms,
            now_ms,
            &zone,
        )
    }
}

#[cfg(test)]
mod tests;
