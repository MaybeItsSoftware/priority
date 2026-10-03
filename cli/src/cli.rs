//! The command-line surface.
//!
//! Every subcommand here is a thin translation into a [`crate::tools`] call and
//! a rendering of the result. Nothing is implemented twice: `takt daily
//! add` and the `daily_add` MCP tool are the same code path with different
//! spellings, so a fix to one is a fix to both.

use crate::checkvist::{CheckvistClient, CheckvistConfig, DEFAULT_BASE_URL};
use crate::config::{Config, Source};
use crate::error::{Result, ToolError};
use crate::local::LocalState;
use crate::mcp;
use crate::tools::{ToolOutcome, Tools};
use clap::{Args, Parser, Subcommand};
use serde_json::{Map, Value, json};

#[derive(Parser)]
#[command(
    name = "takt",
    version,
    about = "Takt from the command line: Checkvist lists, dailies, and your day log.",
    long_about = "Takt from the command line.\n\n\
        Talks to the Checkvist API directly and reads Takt's local state \
        (dailies, day log, priorities) straight off disk, so it works whether or \
        not the app is running. Writes to the dailies and the day log take the \
        same file lock the app does.\n\n\
        Every command is one of the tools the MCP server exposes; `takt \
        tools` lists them and `takt call` invokes one by name.",
    after_help = "Run `takt auth login` once to store your Checkvist credentials in \
        ~/.config/takt/config.json. They are this CLI's own — separate from the app's, \
        which live in the login keychain. CHECKVIST_USERNAME, CHECKVIST_REMOTE_KEY and \
        CHECKVIST_LIST_ID override the file if set. The dailies, log and metadata commands \
        need no credentials at all."
)]
pub struct Cli {
    /// Checkvist list to work in. Defaults to $CHECKVIST_LIST_ID.
    #[arg(long, short = 'l', global = true, value_name = "ID")]
    pub list_id: Option<String>,

    /// Print the raw tool payload as JSON instead of the readable rendering.
    #[arg(long, global = true)]
    pub json: bool,

    /// Omitted entirely, `priority` opens the terminal UI.
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand)]
pub enum Command {
    /// List your non-archived checklists.
    Lists,

    /// Create a new checklist.
    NewList {
        /// Name of the list.
        #[arg(required = true, num_args = 1.., value_name = "NAME")]
        name: Vec<String>,
    },

    /// Place tasks on the Eisenhower matrix.
    ///
    /// Each placement is `TASK_ID:URGENCY:IMPORTANCE`, both axes -9 to 9.
    /// `0:0` removes a placement. Needs Takt to be closed.
    Matrix {
        /// One or more `TASK_ID:URGENCY:IMPORTANCE` triples.
        #[arg(required = true, num_args = 1.., value_name = "TASK:U:I")]
        placements: Vec<String>,
    },

    /// Show a list's tasks as a tree.
    Tasks {
        /// Include closed and invalidated tasks.
        #[arg(long, short = 'a')]
        all: bool,
        /// Skip notes, for a smaller and faster response.
        #[arg(long)]
        no_notes: bool,
    },

    /// Search a list by content, tag and/or due date.
    Search {
        /// Substring of the task content, case-insensitive.
        #[arg(long, short = 'q', value_name = "TEXT")]
        query: Option<String>,
        /// Tag to match, with or without the leading '#'.
        #[arg(long, short = 't', value_name = "TAG")]
        tag: Option<String>,
        /// Only tasks due strictly before this YYYY-MM-DD date.
        #[arg(long, value_name = "DATE")]
        due_before: Option<String>,
        /// Include closed and invalidated tasks.
        #[arg(long, short = 'a')]
        all: bool,
        /// Maximum number of matches to show.
        #[arg(long, default_value_t = 50)]
        limit: i64,
    },

    /// Add a task.
    Add {
        /// The task content. Checkvist's own syntax (^due, #tag) is parsed.
        #[arg(required = true, num_args = 1.., value_name = "CONTENT")]
        content: Vec<String>,
        /// Add under this task instead of at the list root.
        #[arg(long, short = 'p', value_name = "TASK_ID")]
        parent: Option<i64>,
        /// 1-based position among its siblings.
        #[arg(long, value_name = "N")]
        position: Option<i64>,
        /// Due date, in any form Checkvist accepts.
        #[arg(long, short = 'd', value_name = "DUE")]
        due: Option<String>,
    },

    /// Change a task's content and/or due date.
    Update {
        task_id: i64,
        #[arg(long, short = 'c', value_name = "TEXT")]
        content: Option<String>,
        #[arg(long, short = 'd', value_name = "DUE")]
        due: Option<String>,
    },

    /// Append a note to a task.
    Note {
        task_id: i64,
        #[arg(required = true, num_args = 1.., value_name = "NOTE")]
        note: Vec<String>,
    },

    /// Reorder a task among its siblings. Position is 1-based.
    Move { task_id: i64, position: i64 },

    /// Move a task under a different parent, or to the list root.
    Reparent {
        task_id: i64,
        /// New parent. Omit to promote the task to the list root.
        #[arg(long, short = 'p', value_name = "TASK_ID")]
        parent: Option<i64>,
    },

    /// Complete a task.
    Done { task_id: i64 },

    /// Reopen a completed task.
    Reopen { task_id: i64 },

    /// Mark a task "won't do".
    Invalidate { task_id: i64 },

    /// Delete a task.
    Rm { task_id: i64 },

    /// What actually happened on recent days.
    Log {
        /// How many logical days back to include, ending today.
        #[arg(long, short = 'd', default_value_t = 1, value_name = "N")]
        days: i64,
    },

    /// What the focus timer is doing right now.
    Focus,

    /// Focused time already recorded, newest first.
    Focused {
        /// How many logical days back to include, ending today.
        #[arg(long, short = 'd', default_value_t = 1, value_name = "N")]
        days: i64,
    },

    /// Show your dailies with today's schedule and tick state.
    Dailies,

    /// Create, change or tick a daily.
    Daily {
        #[command(subcommand)]
        command: DailyCommand,
    },

    /// Takt's own per-task state: priority ranks, recurrence, start dates.
    Metadata,

    /// The app's local workspace: folders, lists and tasks, read and edited.
    ///
    /// Ids are the workspace's UUIDs, not Checkvist's. Every change is one
    /// step in Takt's Undo menu, labelled "MCP: …", and a running app
    /// picks it up within about a second.
    #[command(visible_alias = "workspace")]
    Ws {
        #[command(subcommand)]
        command: WsCommand,
    },

    /// Store, check or clear this CLI's Checkvist credentials.
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },

    /// Run as an MCP stdio server.
    Mcp,

    /// List the tools this binary exposes.
    Tools,

    /// Call a tool by name with raw JSON arguments.
    Call {
        /// Tool name, as listed by `takt tools`.
        name: String,
        /// Arguments as a JSON object. Defaults to {}.
        #[arg(default_value = "{}", value_name = "JSON")]
        arguments: String,
    },
}

#[derive(Subcommand)]
pub enum AuthCommand {
    /// Save your Checkvist credentials, after checking that they work.
    Login {
        /// Your Checkvist account email. Prompted for if omitted.
        #[arg(long, short = 'u', value_name = "EMAIL")]
        username: Option<String>,
        /// Your API remote key, from checkvist.com/auth/profile. Prompted for
        /// without echo if omitted.
        #[arg(long, short = 'k', value_name = "KEY")]
        remote_key: Option<String>,
        /// Also set the default list.
        #[arg(long, value_name = "ID")]
        list_id: Option<String>,
        /// Save without checking the credentials against the API first.
        #[arg(long)]
        no_verify: bool,
    },
    /// Set the default list used when --list-id is not given.
    SetList {
        #[arg(value_name = "ID")]
        list_id: String,
    },
    /// Show where the config lives and which values are in effect.
    Status,
    /// Forget the stored remote key.
    Logout {
        /// Delete the whole config file rather than just the key.
        #[arg(long)]
        all: bool,
    },
    /// Print the config file path and nothing else.
    Path,
}

#[derive(Subcommand)]
pub enum DailyCommand {
    /// Create a daily.
    Add {
        #[arg(required = true, num_args = 1.., value_name = "TITLE")]
        title: Vec<String>,
        #[command(flatten)]
        weekdays: WeekdayArg,
        /// Repeat every N days from today rather than on fixed weekdays — the
        /// schedule that rotates through the week instead of sitting in it.
        #[arg(long, value_name = "N", conflicts_with = "weekdays")]
        every_days: Option<i64>,
    },
    /// Rename, reschedule, archive or unarchive a daily.
    Update {
        daily_id: String,
        #[arg(long, short = 't', value_name = "TITLE")]
        title: Option<String>,
        #[command(flatten)]
        weekdays: WeekdayArg,
        /// Switch to repeating every N days. Passing --weekdays instead puts it
        /// back on fixed weekdays.
        #[arg(long, value_name = "N", conflicts_with = "weekdays")]
        every_days: Option<i64>,
        /// Archive it. History that references it still renders with a title.
        #[arg(long, conflicts_with = "unarchive")]
        archive: bool,
        /// Bring an archived daily back.
        #[arg(long)]
        unarchive: bool,
    },
    /// Tick a daily for today.
    Tick {
        daily_id: String,
        /// Un-tick it instead.
        #[arg(long)]
        off: bool,
    },
}

#[derive(Subcommand)]
pub enum WsCommand {
    /// Folders, lists and nested lists, with their ids.
    Tree {
        /// Include archived lists and nested lists.
        #[arg(long)]
        archived: bool,
    },
    /// One list's tasks as a tree.
    Tasks {
        list_id: String,
        /// Only this task's subtree.
        #[arg(long, short = 'p', value_name = "TASK_ID")]
        parent: Option<String>,
        /// Include completed and cancelled tasks.
        #[arg(long, short = 'a')]
        all: bool,
    },
    /// Create a task. Needs --list or --parent.
    Add {
        #[arg(required = true, num_args = 1.., value_name = "TITLE")]
        title: Vec<String>,
        #[arg(long = "list", value_name = "LIST_ID")]
        list: Option<String>,
        /// Create it as a subtask of this task.
        #[arg(long, short = 'p', value_name = "TASK_ID")]
        parent: Option<String>,
        #[arg(long, short = 'n', value_name = "TEXT")]
        notes: Option<String>,
        /// An external link. Repeat for several.
        #[arg(long = "link", value_name = "URL")]
        links: Vec<String>,
        /// Kanban column id: backlog, in-progress, this-week, waiting-on, today.
        #[arg(long, short = 'c', value_name = "COLUMN")]
        column: Option<String>,
        /// Make it a nested list rather than a task.
        #[arg(long)]
        nested_list: bool,
        /// First among its siblings rather than last.
        #[arg(long)]
        top: bool,
    },
    /// Change a task's title, notes, links, status or column.
    Update {
        task_id: String,
        #[arg(long, short = 't', value_name = "TITLE")]
        title: Option<String>,
        #[arg(long, short = 'n', value_name = "TEXT")]
        notes: Option<String>,
        /// Replace the links with these. Repeat for several.
        #[arg(long = "link", value_name = "URL", conflicts_with = "no_links")]
        links: Vec<String>,
        /// Remove every link.
        #[arg(long)]
        no_links: bool,
        /// open, completed or cancelled.
        #[arg(long, short = 's', value_name = "STATUS")]
        status: Option<String>,
        /// Kanban column id. An empty string clears it.
        #[arg(long, short = 'c', value_name = "COLUMN")]
        column: Option<String>,
        /// task, or list to make it a nested list in place.
        #[arg(long, value_name = "KIND")]
        kind: Option<String>,
        /// Pin a nested list to the sidebar.
        #[arg(long, conflicts_with = "unpin")]
        pin: bool,
        /// Unpin a nested list from the sidebar.
        #[arg(long)]
        unpin: bool,
    },
    /// Complete a task.
    Done { task_id: String },
    /// Reopen a task.
    Reopen { task_id: String },
    /// Move a task (and its subtree) under a new parent, to a list's top
    /// level, and/or to a 1-based position among its siblings.
    Move {
        task_id: String,
        #[arg(long, short = 'p', value_name = "TASK_ID")]
        parent: Option<String>,
        #[arg(long = "list", value_name = "LIST_ID", conflicts_with = "parent")]
        list: Option<String>,
        #[arg(long, value_name = "N")]
        position: Option<i64>,
    },
    /// Promote a task to a standalone list of its own.
    ToList {
        task_id: String,
        /// Put the new list in this folder rather than at the top level.
        #[arg(long, short = 'f', value_name = "FOLDER_ID")]
        folder: Option<String>,
    },
    /// Delete a task and its subtree.
    Rm { task_id: String },
    /// Create a folder.
    NewFolder {
        #[arg(required = true, num_args = 1.., value_name = "NAME")]
        name: Vec<String>,
        #[arg(long, short = 'p', value_name = "FOLDER_ID")]
        parent: Option<String>,
    },
    /// Create a list.
    NewList {
        #[arg(required = true, num_args = 1.., value_name = "NAME")]
        name: Vec<String>,
        #[arg(long, short = 'f', value_name = "FOLDER_ID")]
        folder: Option<String>,
    },
    /// Move a list into a folder, or to the top level without --folder.
    MoveList {
        list_id: String,
        #[arg(long, short = 'f', value_name = "FOLDER_ID")]
        folder: Option<String>,
    },
}

#[derive(Args)]
pub struct WeekdayArg {
    /// Which days it's expected on: "mon,wed,fri", "weekdays", "every day",
    /// or Calendar numbers where 1 is Sunday.
    #[arg(long, short = 'w', value_name = "DAYS")]
    weekdays: Option<String>,
}

impl WeekdayArg {
    fn parse(&self) -> Result<Option<Vec<i64>>> {
        let Some(spec) = &self.weekdays else {
            return Ok(None);
        };
        parse_weekdays(spec).map(Some)
    }
}

/// Accepts what a person would actually type. The tool layer only speaks
/// `Calendar` numbers (1 = Sunday), so this is the only place the friendly
/// spellings exist — everything downstream sees the same integers an MCP client
/// would have sent.
pub fn parse_weekdays(spec: &str) -> Result<Vec<i64>> {
    let mut weekdays: Vec<i64> = Vec::new();
    let mut push = |day: i64| {
        if !weekdays.contains(&day) {
            weekdays.push(day);
        }
    };

    for token in spec
        .split([',', ' ', '+'])
        .filter(|token| !token.is_empty())
    {
        match token.to_lowercase().as_str() {
            "every" | "everyday" | "all" | "daily" | "day" | "days" => (1..=7).for_each(&mut push),
            "weekdays" | "weekday" | "week" => (2..=6).for_each(&mut push),
            "weekends" | "weekend" => [1, 7].into_iter().for_each(&mut push),
            other => {
                let day = match other.get(..3).unwrap_or(other) {
                    "sun" => 1,
                    "mon" => 2,
                    "tue" => 3,
                    "wed" => 4,
                    "thu" => 5,
                    "fri" => 6,
                    "sat" => 7,
                    _ => other
                        .parse::<i64>()
                        .ok()
                        .filter(|day| (1..=7).contains(day))
                        .ok_or_else(|| {
                            ToolError::new(format!(
                                "Cannot read {other:?} as a weekday. Use names (mon, tue), \
                                 groups (weekdays, weekends, every day), or numbers 1-7 \
                                 where 1 is Sunday."
                            ))
                        })?,
                };
                push(day);
            }
        }
    }

    if weekdays.is_empty() {
        return Err(ToolError::new("No weekdays given."));
    }
    weekdays.sort_unstable();
    Ok(weekdays)
}

/// Translates a subcommand into `(tool name, arguments)`.
///
/// Returning the pair rather than calling straight through is what lets
/// `takt tools` and the MCP server share one dispatch table, and keeps the
/// CLI honest: if a command cannot be expressed as a tool call, it does not
/// belong here.
pub fn resolve(cli: &Cli) -> Result<(String, Map<String, Value>)> {
    let mut arguments = Map::new();
    if let Some(list_id) = &cli.list_id {
        arguments.insert("list_id".into(), json!(list_id));
    }

    let Some(command) = &cli.command else {
        return Err(ToolError::new("No command given."));
    };

    let name = match command {
        // Not tool calls: they configure or introspect this binary rather than
        // touching any data, so they are handled before dispatch.
        Command::Mcp | Command::Tools | Command::Auth { .. } => {
            unreachable!("handled before dispatch")
        }

        Command::Call {
            name,
            arguments: raw,
        } => {
            let parsed: Value = serde_json::from_str(raw)
                .map_err(|err| ToolError::new(format!("Arguments must be a JSON object: {err}")))?;
            let Value::Object(parsed) = parsed else {
                return Err(ToolError::new("Arguments must be a JSON object."));
            };
            // Explicit arguments win over the global --list-id.
            arguments.extend(parsed);
            return Ok((name.clone(), arguments));
        }

        Command::Lists => "task_lists",

        Command::NewList { name } => {
            arguments.insert("name".into(), json!(name.join(" ")));
            "list_create"
        }

        Command::Tasks { all, no_notes } => {
            arguments.insert("include_closed".into(), json!(all));
            arguments.insert("with_notes".into(), json!(!no_notes));
            "task_fetch"
        }

        Command::Search {
            query,
            tag,
            due_before,
            all,
            limit,
        } => {
            insert_if_some(&mut arguments, "query", query.as_deref());
            insert_if_some(&mut arguments, "tag", tag.as_deref());
            insert_if_some(&mut arguments, "due_before", due_before.as_deref());
            arguments.insert("include_closed".into(), json!(all));
            arguments.insert("limit".into(), json!(limit));
            "task_search"
        }

        Command::Add {
            content,
            parent,
            position,
            due,
        } => {
            arguments.insert("content".into(), json!(content.join(" ")));
            if let Some(parent) = parent {
                arguments.insert("location".into(), json!("specific"));
                arguments.insert("parent_task_id".into(), json!(parent));
            }
            if let Some(position) = position {
                arguments.insert("position".into(), json!(position));
            }
            insert_if_some(&mut arguments, "due", due.as_deref());
            "task_add"
        }

        Command::Update {
            task_id,
            content,
            due,
        } => {
            arguments.insert("task_id".into(), json!(task_id));
            insert_if_some(&mut arguments, "content", content.as_deref());
            insert_if_some(&mut arguments, "due", due.as_deref());
            "task_update"
        }

        Command::Note { task_id, note } => {
            arguments.insert("task_id".into(), json!(task_id));
            arguments.insert("note".into(), json!(note.join(" ")));
            "task_note_add"
        }

        Command::Move { task_id, position } => {
            arguments.insert("task_id".into(), json!(task_id));
            arguments.insert("position".into(), json!(position));
            "task_move"
        }

        Command::Reparent { task_id, parent } => {
            arguments.insert("task_id".into(), json!(task_id));
            // Omitted means the list root, which is exactly the tool's contract.
            if let Some(parent) = parent {
                arguments.insert("parent_task_id".into(), json!(parent));
            }
            "task_reparent"
        }

        Command::Done { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            "task_complete"
        }
        Command::Reopen { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            "task_reopen"
        }
        Command::Invalidate { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            "task_invalidate"
        }
        Command::Rm { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            "task_delete"
        }

        Command::Log { days } => {
            arguments.insert("days".into(), json!(days));
            "daily_log_fetch"
        }

        Command::Focus => "focus_status",

        Command::Focused { days } => {
            arguments.insert("days".into(), json!(days));
            "focus_history"
        }

        Command::Dailies => "dailies_list",
        Command::Metadata => "task_metadata",

        Command::Matrix { placements } => {
            let parsed = placements
                .iter()
                .map(|raw| {
                    let parts: Vec<&str> = raw.split(':').collect();
                    let [task, urgency, importance] = parts.as_slice() else {
                        return Err(ToolError::new(format!(
                            "expected TASK_ID:URGENCY:IMPORTANCE, got `{raw}`"
                        )));
                    };
                    let number = |text: &str, field: &str| {
                        text.parse::<f64>().map_err(|_| {
                            ToolError::new(format!("`{text}` is not a number for {field}"))
                        })
                    };
                    Ok(json!({
                        "task_id": number(task, "task_id")? as i64,
                        "urgency": number(urgency, "urgency")?,
                        "importance": number(importance, "importance")?,
                    }))
                })
                .collect::<Result<Vec<_>>>()?;
            arguments.insert("placements".into(), json!(parsed));
            "task_matrix_set"
        }

        Command::Daily { command } => match command {
            DailyCommand::Add {
                title,
                weekdays,
                every_days,
            } => {
                arguments.insert("title".into(), json!(title.join(" ")));
                if let Some(weekdays) = weekdays.parse()? {
                    arguments.insert("active_weekdays".into(), json!(weekdays));
                }
                if let Some(interval) = every_days {
                    arguments.insert("interval_days".into(), json!(interval));
                }
                "daily_add"
            }
            DailyCommand::Update {
                daily_id,
                title,
                weekdays,
                every_days,
                archive,
                unarchive,
            } => {
                arguments.insert("daily_id".into(), json!(daily_id));
                insert_if_some(&mut arguments, "title", title.as_deref());
                if let Some(weekdays) = weekdays.parse()? {
                    arguments.insert("active_weekdays".into(), json!(weekdays));
                }
                if let Some(interval) = every_days {
                    arguments.insert("interval_days".into(), json!(interval));
                }
                if *archive || *unarchive {
                    arguments.insert("archived".into(), json!(*archive));
                }
                "daily_update"
            }
            DailyCommand::Tick { daily_id, off } => {
                arguments.insert("daily_id".into(), json!(daily_id));
                arguments.insert("done".into(), json!(!off));
                "daily_tick"
            }
        },

        Command::Ws { command } => {
            // The global --list-id is a Checkvist list. Workspace commands
            // name their own, so it must not leak in as one of theirs.
            arguments.remove("list_id");
            resolve_workspace(command, &mut arguments)
        }
    };

    Ok((name.to_string(), arguments))
}

fn resolve_workspace(command: &WsCommand, arguments: &mut Map<String, Value>) -> &'static str {
    match command {
        WsCommand::Tree { archived } => {
            arguments.insert("include_archived".into(), json!(archived));
            "workspace_tree"
        }
        WsCommand::Tasks {
            list_id,
            parent,
            all,
        } => {
            arguments.insert("list_id".into(), json!(list_id));
            insert_if_some(arguments, "parent_task_id", parent.as_deref());
            arguments.insert("include_closed".into(), json!(all));
            "workspace_tasks"
        }
        WsCommand::Add {
            title,
            list,
            parent,
            notes,
            links,
            column,
            nested_list,
            top,
        } => {
            arguments.insert("title".into(), json!(title.join(" ")));
            insert_if_some(arguments, "list_id", list.as_deref());
            insert_if_some(arguments, "parent_task_id", parent.as_deref());
            insert_if_some(arguments, "notes", notes.as_deref());
            if !links.is_empty() {
                arguments.insert("external_links".into(), json!(links));
            }
            insert_if_some(arguments, "kanban_column", column.as_deref());
            if *nested_list {
                arguments.insert("kind".into(), json!("list"));
            }
            if *top {
                arguments.insert("at_top".into(), json!(true));
            }
            "workspace_task_add"
        }
        WsCommand::Update {
            task_id,
            title,
            notes,
            links,
            no_links,
            status,
            column,
            kind,
            pin,
            unpin,
        } => {
            arguments.insert("task_id".into(), json!(task_id));
            insert_if_some(arguments, "title", title.as_deref());
            insert_if_some(arguments, "notes", notes.as_deref());
            if *no_links || !links.is_empty() {
                arguments.insert("external_links".into(), json!(links));
            }
            insert_if_some(arguments, "status", status.as_deref());
            insert_if_some(arguments, "kanban_column", column.as_deref());
            insert_if_some(arguments, "kind", kind.as_deref());
            if *pin || *unpin {
                arguments.insert("pinned".into(), json!(*pin));
            }
            "workspace_task_update"
        }
        WsCommand::Done { task_id } | WsCommand::Reopen { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            let status = if matches!(command, WsCommand::Done { .. }) {
                "completed"
            } else {
                "open"
            };
            arguments.insert("status".into(), json!(status));
            "workspace_task_update"
        }
        WsCommand::Move {
            task_id,
            parent,
            list,
            position,
        } => {
            arguments.insert("task_id".into(), json!(task_id));
            insert_if_some(arguments, "parent_task_id", parent.as_deref());
            insert_if_some(arguments, "list_id", list.as_deref());
            if let Some(position) = position {
                arguments.insert("position".into(), json!(position));
            }
            "workspace_task_move"
        }
        WsCommand::ToList { task_id, folder } => {
            arguments.insert("task_id".into(), json!(task_id));
            insert_if_some(arguments, "folder_id", folder.as_deref());
            "workspace_task_to_list"
        }
        WsCommand::Rm { task_id } => {
            arguments.insert("task_id".into(), json!(task_id));
            "workspace_task_delete"
        }
        WsCommand::NewFolder { name, parent } => {
            arguments.insert("name".into(), json!(name.join(" ")));
            insert_if_some(arguments, "parent_folder_id", parent.as_deref());
            "workspace_folder_create"
        }
        WsCommand::NewList { name, folder } => {
            arguments.insert("name".into(), json!(name.join(" ")));
            insert_if_some(arguments, "folder_id", folder.as_deref());
            "workspace_list_create"
        }
        WsCommand::MoveList { list_id, folder } => {
            arguments.insert("list_id".into(), json!(list_id));
            insert_if_some(arguments, "folder_id", folder.as_deref());
            "workspace_list_move"
        }
    }
}

fn insert_if_some(arguments: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value {
        arguments.insert(key.into(), json!(value));
    }
}

// -- rendering ---------------------------------------------------------------

pub fn print_tools() {
    let definitions = mcp::tool_definitions();
    println!("{} tools\n", definitions.len());
    for tool in &definitions {
        let name = tool.get("name").and_then(Value::as_str).unwrap_or("");
        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("");
        println!("  {name:<16}  {description}");
    }
    println!("\nCall one directly:  takt call <name> '{{\"key\": \"value\"}}'");
}

pub fn render(tool: &str, outcome: &ToolOutcome, as_json: bool) {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&outcome.payload).unwrap_or_else(|_| "null".into())
        );
        return;
    }

    println!("{}\n", outcome.title);
    let payload = &outcome.payload;
    match tool {
        "task_lists" => render_lists(payload),
        "task_fetch" | "task_search" => render_tasks(payload),
        "daily_log_fetch" => render_log(payload),
        "dailies_list" => render_dailies(payload),
        "task_metadata" => render_metadata(payload),
        "task_matrix_set" => render_matrix_set(payload),
        "daily_add" | "daily_update" => render_daily(payload),
        "daily_tick" => render_tick(payload),
        "focus_status" => render_focus(payload),
        "focus_history" => render_focused(payload),
        "workspace_tree" => render_workspace_tree(payload),
        "workspace_tasks" => render_workspace_tasks(payload),
        "workspace_task_add" | "workspace_task_update" | "workspace_task_move" => {
            render_workspace_task(payload, 0)
        }
        _ => render_task(payload),
    }
}

fn render_focus(payload: &Value) {
    if payload["running"] != Value::Bool(true) {
        return println!("  Nothing running.");
    }
    let task = payload["task"].as_str().unwrap_or("(unknown task)");
    let clock = payload["clock"].as_str().unwrap_or("");
    let state = if payload["overrun"] == Value::Bool(true) {
        format!("{clock} over")
    } else {
        format!("{clock} left")
    };
    println!("  {task}");
    println!(
        "  {state}{}",
        if payload["paused"] == Value::Bool(true) {
            match payload["paused_at"].as_str() {
                Some(at) => format!("  — paused since {at}"),
                None => "  — paused".into(),
            }
        } else {
            String::new()
        }
    );
    let queued: Vec<&Value> = payload["queue"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|item| item["state"] == json!("queued"))
                .collect()
        })
        .unwrap_or_default();
    if !queued.is_empty() {
        println!("\n  Next:");
        for item in queued {
            println!("    {}", item["task"].as_str().unwrap_or("(unknown task)"));
        }
    }
}

fn render_focused(payload: &Value) {
    let blocks = payload["blocks"].as_array().cloned().unwrap_or_default();
    if blocks.is_empty() {
        return println!("  (nothing recorded)");
    }
    for block in &blocks {
        let at = block["recorded_at"].as_str().unwrap_or("");
        let seconds = block["seconds"].as_i64().unwrap_or(0);
        println!(
            "  {at}  {:>5}m  {}",
            seconds / 60,
            block["task"].as_str().unwrap_or("")
        );
    }
    println!("\n  {} total", payload["total"].as_str().unwrap_or(""));
}

fn render_lists(payload: &Value) {
    let Some(lists) = payload.as_array() else {
        return render_fallback(payload);
    };
    if lists.is_empty() {
        return println!("  (no lists)");
    }
    for list in lists {
        let id = list.get("id").map(text_of).unwrap_or_default();
        let name = list.get("name").and_then(Value::as_str).unwrap_or("");
        let open = list.get("task_count").map(text_of).unwrap_or_default();
        println!(
            "  {id:>8}  {name}{}",
            if open.is_empty() {
                String::new()
            } else {
                format!("  ({open} tasks)")
            }
        );
    }
}

fn render_tasks(payload: &Value) {
    let Some(tasks) = payload.as_array() else {
        return render_fallback(payload);
    };
    if tasks.is_empty() {
        return println!("  (nothing)");
    }

    // The API order is already parents-before-children, so depth comes from
    // walking each task's parent chain within what was returned.
    let depth_of = |task: &Value| -> usize {
        let mut depth = 0;
        let mut parent = crate::checkvist::parent_id_of(task);
        while parent != 0 && depth < 32 {
            let Some(found) = tasks
                .iter()
                .find(|t| t.get("id").and_then(Value::as_i64) == Some(parent))
            else {
                break;
            };
            parent = crate::checkvist::parent_id_of(found);
            depth += 1;
        }
        depth
    };

    for task in tasks {
        let id = task.get("id").map(text_of).unwrap_or_default();
        let marker = match crate::checkvist::status_of(task) {
            0 => "[ ]",
            1 => "[x]",
            _ => "[~]",
        };
        let content = task.get("content").and_then(Value::as_str).unwrap_or("");
        let due = task
            .get("due")
            .and_then(Value::as_str)
            .filter(|due| !due.is_empty())
            .map(|due| format!("  due {due}"))
            .unwrap_or_default();
        let indent = "  ".repeat(depth_of(task));
        println!("  {id:>8}  {marker} {indent}{content}{due}");

        for note in task
            .get("notes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(comment) = note.get("comment").and_then(Value::as_str) {
                for line in comment.lines() {
                    println!("            |   {indent}{line}");
                }
            }
        }
    }
}

fn render_log(payload: &Value) {
    let Some(days) = payload.as_array() else {
        return render_fallback(payload);
    };
    for (index, day) in days.iter().enumerate() {
        if index > 0 {
            println!();
        }
        let key = day.get("day").and_then(Value::as_str).unwrap_or("");
        let completed = day
            .get("completed_count")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let planned = day
            .get("planned_count")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let unfinished = day
            .get("unfinished_count")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let focus = day
            .get("focus_seconds")
            .and_then(Value::as_i64)
            .unwrap_or(0);

        println!(
            "  {key}   {completed} done / {planned} planned   {unfinished} unfinished   {} focus",
            format_duration(focus)
        );

        for entry in day
            .get("completed")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let title = entry.get("title").and_then(Value::as_str).unwrap_or("");
            let at = entry
                .get("at")
                .and_then(Value::as_str)
                .and_then(|at| at.get(11..16))
                .unwrap_or("     ");
            println!("      {at}  ✓ {title}");
        }
        for (label, key) in [
            ("unfinished", "unfinished_task_ids"),
            ("deferred", "deferred_task_ids"),
            ("won't do", "invalidated_task_ids"),
        ] {
            let ids = day
                .get(key)
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            if !ids.is_empty() {
                let joined = ids.iter().map(text_of).collect::<Vec<_>>().join(", ");
                println!("      {label:>10}: {joined}");
            }
        }

        let dailies = day
            .get("dailies")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        if !dailies.is_empty() {
            let rendered: Vec<String> = dailies
                .iter()
                .map(|daily| {
                    let done = daily.get("done") == Some(&Value::Bool(true));
                    let title = daily.get("title").and_then(Value::as_str).unwrap_or("");
                    format!("{} {title}", if done { "✓" } else { "·" })
                })
                .collect();
            println!("      {:>10}: {}", "dailies", rendered.join("   "));
        }
    }
}

fn render_dailies(payload: &Value) {
    let day = payload.get("day").and_then(Value::as_str).unwrap_or("");
    let Some(dailies) = payload.get("dailies").and_then(Value::as_array) else {
        return render_fallback(payload);
    };
    if dailies.is_empty() {
        return println!("  (no dailies configured)");
    }
    println!("  for {day}\n");
    for daily in dailies {
        let due_today = daily.get("due_today") == Some(&Value::Bool(true));
        let done = daily.get("done") == Some(&Value::Bool(true));
        let marker = match (due_today, done) {
            (_, true) => "✓",
            (true, false) => "·",
            // Not expected today, so neither done nor outstanding.
            (false, false) => " ",
        };
        let title = daily.get("title").and_then(Value::as_str).unwrap_or("");
        let schedule = daily.get("schedule").and_then(Value::as_str).unwrap_or("");
        let id = daily.get("id").and_then(Value::as_str).unwrap_or("");
        println!("  {marker} {title:<32}  {schedule:<16}  {id}");
    }
}

fn render_matrix_set(payload: &Value) {
    let count = |key: &str| payload.get(key).and_then(Value::as_u64).unwrap_or(0);
    println!("  placed   {}", count("placed"));
    println!("  cleared  {}", count("cleared"));
    if let Some(note) = payload.get("note").and_then(Value::as_str) {
        println!("\n{note}");
    }
}

fn render_metadata(payload: &Value) {
    let mut printed = false;
    let mut section = |label: &str, value: Option<&Value>| {
        let Some(Value::Object(entries)) = value else {
            return;
        };
        if entries.is_empty() {
            return;
        }
        printed = true;
        println!("  {label}");
        for (key, item) in entries {
            println!("    {key:>10}  {}", text_of(item));
        }
    };

    section(
        "absolute priority (rank by task)",
        payload.get("absolute_priority_rank"),
    );
    section("recurrence", payload.get("recurrence_rule_by_task_id"));
    section("start dates", payload.get("start_date_by_task_id"));

    if let Some(Value::Object(by_parent)) = payload.get("scoped_priority_rank_by_parent_id")
        && !by_parent.is_empty()
    {
        printed = true;
        println!("  scoped priority (rank by task, per parent)");
        for (parent, ranks) in by_parent {
            let label = if parent == "0" {
                "root".to_string()
            } else {
                format!("under {parent}")
            };
            let joined = ranks
                .as_object()
                .map(|ranks| {
                    ranks
                        .iter()
                        .map(|(task, rank)| format!("{task}#{}", text_of(rank)))
                        .collect::<Vec<_>>()
                        .join("  ")
                })
                .unwrap_or_default();
            println!("    {label:>10}  {joined}");
        }
    }

    if !printed {
        println!("  (nothing recorded for this list)");
    }
}

fn render_daily(payload: &Value) {
    let title = payload.get("title").and_then(Value::as_str).unwrap_or("");
    let schedule = payload
        .get("schedule")
        .and_then(Value::as_str)
        .unwrap_or("");
    let id = payload.get("id").and_then(Value::as_str).unwrap_or("");
    let archived = if payload.get("archived") == Some(&Value::Bool(true)) {
        "  (archived)"
    } else {
        ""
    };
    println!("  {title}  —  {schedule}{archived}");
    println!("  {id}");
}

fn render_tick(payload: &Value) {
    let title = payload.get("title").and_then(Value::as_str).unwrap_or("");
    let day = payload.get("day").and_then(Value::as_str).unwrap_or("");
    let done = payload.get("done") == Some(&Value::Bool(true));
    println!("  {} {title}   ({day})", if done { "✓" } else { "·" });
}

fn render_task(payload: &Value) {
    if let Some(id) = payload.get("id") {
        let content = payload.get("content").and_then(Value::as_str).unwrap_or("");
        let due = payload
            .get("due")
            .and_then(Value::as_str)
            .filter(|due| !due.is_empty())
            .map(|due| format!("  due {due}"))
            .unwrap_or_default();
        if !content.is_empty() {
            return println!("  {}  {content}{due}", text_of(id));
        }
        // A list, or anything else with a name rather than content.
        if let Some(name) = payload.get("name").and_then(Value::as_str) {
            return println!("  {}  {name}", text_of(id));
        }
    }
    render_fallback(payload);
}

/// Folders as headings with their lists beneath, then the lists in no folder:
/// the sidebar's shape, with the ids a follow-up command needs.
fn render_workspace_tree(payload: &Value) {
    let empty = Vec::new();
    let folders = payload["folders"].as_array().unwrap_or(&empty);
    let lists = payload["lists"].as_array().unwrap_or(&empty);
    for folder in folders.iter().filter(|f| f["parent_folder_id"].is_null()) {
        render_folder(folder, 1, folders, lists);
    }
    for list in lists.iter().filter(|l| l["folder_id"].is_null()) {
        render_workspace_list(list, 1);
    }
    if let Some(nested) = payload["nested_lists"].as_array().filter(|n| !n.is_empty()) {
        println!("\n  Nested lists");
        for list in nested {
            let pinned = if list["is_promoted"] == json!(true) {
                "  (pinned)"
            } else {
                ""
            };
            println!(
                "    {}  {}{pinned}",
                text_of(&list["title"]),
                text_of(&list["id"])
            );
        }
    }
}

fn render_folder(folder: &Value, depth: usize, folders: &[Value], lists: &[Value]) {
    println!(
        "{}▸ {}  {}",
        "  ".repeat(depth),
        text_of(&folder["name"]),
        text_of(&folder["id"])
    );
    for child in folders
        .iter()
        .filter(|f| f["parent_folder_id"] == folder["id"])
    {
        render_folder(child, depth + 1, folders, lists);
    }
    for list in lists.iter().filter(|l| l["folder_id"] == folder["id"]) {
        render_workspace_list(list, depth + 1);
    }
}

fn render_workspace_list(list: &Value, depth: usize) {
    let marks: String = [
        (list["system_role"] == json!("inbox"), " (inbox)"),
        (list["is_archived"] == json!(true), " (archived)"),
        (!list["completed_at"].is_null(), " (completed)"),
    ]
    .iter()
    .filter(|(on, _)| *on)
    .map(|(_, mark)| *mark)
    .collect();
    println!(
        "{}{}{marks}  [{} open]  {}",
        "  ".repeat(depth),
        text_of(&list["name"]),
        list["open_task_count"],
        text_of(&list["id"])
    );
}

fn render_workspace_tasks(payload: &Value) {
    fn walk(nodes: &Value, depth: usize) {
        for node in nodes.as_array().into_iter().flatten() {
            render_workspace_task(node, depth);
            walk(&node["children"], depth + 1);
        }
    }
    walk(&payload["tasks"], 0);
}

fn render_workspace_task(task: &Value, depth: usize) {
    if task.get("id").is_none() {
        return render_fallback(task);
    }
    let mark = match (task["kind"].as_str(), task["status"].as_str()) {
        (Some("list"), _) => "≡",
        (_, Some("completed")) => "✓",
        (_, Some("cancelled")) => "×",
        _ => "·",
    };
    let column = task["kanban_column"]
        .as_str()
        .map(|column| format!("  [{column}]"))
        .unwrap_or_default();
    let indent = "  ".repeat(depth + 1);
    println!(
        "{indent}{mark} {}{column}  {}",
        text_of(&task["title"]),
        text_of(&task["id"])
    );
    for link in task["external_links"].as_array().into_iter().flatten() {
        println!("{indent}    ↗ {}", text_of(link));
    }
    if let Some(notes) = task["notes"].as_str().filter(|notes| !notes.is_empty()) {
        for line in notes.lines() {
            println!("{indent}    {line}");
        }
    }
}

fn render_fallback(payload: &Value) {
    println!(
        "{}",
        serde_json::to_string_pretty(payload).unwrap_or_else(|_| "null".into())
    );
}

fn text_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn format_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return "none".into();
    }
    let (hours, minutes) = (seconds / 3600, (seconds % 3600) / 60);
    if hours > 0 {
        format!("{hours}h {minutes:02}m")
    } else {
        format!("{minutes}m")
    }
}

pub fn run(tools: Tools, cli: &Cli) -> Result<()> {
    let (name, arguments) = resolve(cli)?;
    let outcome = tools.call(&name, &arguments)?;
    render(&name, &outcome, cli.json);
    Ok(())
}

// -- auth --------------------------------------------------------------------

pub fn run_auth(mut config: Config, command: &AuthCommand) -> Result<()> {
    match command {
        AuthCommand::Path => {
            println!("{}", config.path.display());
            Ok(())
        }

        AuthCommand::Status => {
            print_auth_status(&config);
            Ok(())
        }

        AuthCommand::SetList { list_id } => {
            config.set("list_id", Some(list_id));
            config.save()?;
            println!("Default list is now {list_id}.");
            warn_if_env_overrides("CHECKVIST_LIST_ID", "default list");
            Ok(())
        }

        AuthCommand::Logout { all } => {
            if *all {
                config.delete()?;
                println!("Removed {}.", config.path.display());
            } else {
                config.set("remote_key", None);
                config.save()?;
                println!("Removed the stored remote key. Username and default list are kept.");
            }
            // An exported variable outlives the file, and would leave the CLI
            // still signed in after a logout that reported success.
            warn_if_env_overrides("CHECKVIST_REMOTE_KEY", "remote key");
            Ok(())
        }

        AuthCommand::Login {
            username,
            remote_key,
            list_id,
            no_verify,
        } => {
            let username = match username {
                Some(value) => value.trim().to_string(),
                None => prompt("Checkvist email: ")?,
            };
            if username.is_empty() {
                return Err(ToolError::new("A username is required."));
            }

            let remote_key = match remote_key {
                Some(value) => value.trim().to_string(),
                None => {
                    println!("Find your remote key at https://checkvist.com/auth/profile");
                    prompt_secret("Checkvist remote key: ")?
                }
            };
            if remote_key.is_empty() {
                return Err(ToolError::new("A remote key is required."));
            }

            let base_url = config
                .resolve("CHECKVIST_BASE_URL", "base_url")
                .0
                .unwrap_or_else(|| DEFAULT_BASE_URL.into());
            let client = CheckvistClient::new(CheckvistConfig {
                username: username.clone(),
                remote_key: remote_key.clone(),
                default_list_id: String::new(),
                base_url: base_url.clone(),
            });

            if !no_verify {
                // Checked *before* writing, so a mistyped key fails here rather
                // than as a puzzling 401 on some later command.
                client.login()?;
                println!("{base_url} accepted the credentials.");
            }

            config.set("username", Some(&username));
            config.set("remote_key", Some(&remote_key));
            if let Some(list_id) = list_id {
                config.set("list_id", Some(list_id));
            }
            config.save()?;
            println!(
                "Saved to {} (owner-only, mode 0600).",
                config.path.display()
            );

            for name in ["CHECKVIST_USERNAME", "CHECKVIST_REMOTE_KEY"] {
                warn_if_env_overrides(name, "value you just saved");
            }

            // Most commands need a list, and the error when none is set reads
            // as a configuration problem rather than a missing step.
            if config.resolve("CHECKVIST_LIST_ID", "list_id").0.is_none() && !no_verify {
                suggest_a_default_list(&client);
            }
            Ok(())
        }
    }
}

fn print_auth_status(config: &Config) {
    println!(
        "config file  {}{}",
        config.path.display(),
        if config.exists() {
            ""
        } else {
            "   (not created yet)"
        }
    );
    println!();

    let row = |label: &str, value: String, source: Source| {
        println!("  {label:<12} {value:<44} {}", source.describe());
    };
    let shown = |value: &Option<String>| value.clone().unwrap_or_else(|| "—".into());

    let (username, source) = config.resolve("CHECKVIST_USERNAME", "username");
    row("username", shown(&username), source);

    let (key, source) = config.resolve("CHECKVIST_REMOTE_KEY", "remote_key");
    // Deliberately never printed. `auth status` is the command someone runs
    // while screen-sharing, and the length is enough to spot a truncated paste.
    row(
        "remote key",
        key.as_ref()
            .map_or("—".into(), |key| format!("set, {} characters", key.len())),
        source,
    );

    let (list_id, source) = config.resolve("CHECKVIST_LIST_ID", "list_id");
    row("default list", shown(&list_id), source);

    let (base_url, source) = config.resolve("CHECKVIST_BASE_URL", "base_url");
    row(
        "base url",
        base_url.unwrap_or_else(|| DEFAULT_BASE_URL.into()),
        if source == Source::Unset {
            Source::Default
        } else {
            source
        },
    );

    println!();
    let local = LocalState::resolve(config);
    let (_, source) = config.resolve("PRIORITY_MCP_STORE_DIR", "store_directory");
    row(
        "store",
        local.store_directory.display().to_string(),
        if source == Source::Unset {
            Source::Default
        } else {
            source
        },
    );

    println!();
    if username.is_none() || key.is_none() {
        println!("Not signed in. Run:  takt auth login");
        println!("The dailies, log and metadata commands work without credentials.");
    } else {
        println!("Signed in. The credentials are this CLI's own — signing in or out");
        println!("here does not affect the Takt app, or the reverse.");
    }
}

fn suggest_a_default_list(client: &CheckvistClient) {
    let Ok(lists) = client.list_lists() else {
        return;
    };
    if lists.is_empty() {
        return;
    }
    println!("\nNo default list set. Yours are:");
    for list in lists.iter().take(10) {
        let id = list.get("id").map(text_of).unwrap_or_default();
        let name = list.get("name").and_then(Value::as_str).unwrap_or("");
        println!("  {id:>8}  {name}");
    }
    println!("\nSet one with:  takt auth set-list <ID>");
}

/// Says so when an exported variable will win over the file that was just
/// written — otherwise the change appears to have had no effect.
fn warn_if_env_overrides(name: &str, description: &str) {
    if std::env::var(name).is_ok_and(|value| !value.trim().is_empty()) {
        println!("NOTE: ${name} is set in this shell and overrides the {description}.");
    }
}

fn prompt(label: &str) -> Result<String> {
    use std::io::Write;
    print!("{label}");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|err| ToolError::new(format!("Could not read input: {err}")))?;
    Ok(line.trim().to_string())
}

fn prompt_secret(label: &str) -> Result<String> {
    rpassword::prompt_password(label)
        .map(|value| value.trim().to_string())
        .map_err(|err| ToolError::new(format!("Could not read the remote key: {err}")))
}
