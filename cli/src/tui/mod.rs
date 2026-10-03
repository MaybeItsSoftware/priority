//! A terminal UI with the same tabs as the menu bar app.
//!
//! This is the third front end onto [`crate::tools`], alongside the
//! subcommands and the MCP server. It implements no tool of its own: every key
//! that changes something dispatches the same call an assistant would make, so
//! the terminal cannot do anything the other two can't, or do it differently.
//!
//! The tabs and their keys mirror `RootTaskView` in the app — `q` `w` `e` `r`
//! to jump, `j`/`k` to move, `l`/`h` to open and shut a task's subtasks in
//! place, `]`/`[` to zoom the list into one, `space` to complete. Someone who
//! knows the popover should not have to learn a second set of habits.

pub mod outline;
mod render;
pub mod state;
#[cfg(test)]
mod tests;

use crate::error::{Result, ToolError};
use crate::tools::Tools;
use crate::tui::outline::OutlineStore;
use crate::tui::state::{App, Data, Tab};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use serde_json::{Map, Value, json};
use std::io::IsTerminal;

pub fn run(tools: Tools) -> Result<()> {
    // Refuse rather than take over a pipe. `takt | cat`, a cron job or a
    // CI step would otherwise put an interactive UI somewhere nobody can quit
    // it from, and the terminal-setup call would fail obscurely.
    if !std::io::stdout().is_terminal() {
        return Err(ToolError::new(
            "The terminal UI needs an interactive terminal. \
             Run `takt --help` for the subcommands, which work anywhere.",
        ));
    }

    // No list to scope it to (no credentials yet) means no remembered outline,
    // which is right: the Daily tab is all that works in that state anyway.
    let list_id = tools.client.resolve_list_id(None).unwrap_or_default();
    let outline = OutlineStore::beside_config(&crate::config::Config::default_path(), &list_id);
    let mut app = App::with_outline(load(&tools), outline);

    // `ratatui::init` installs a panic hook that restores the terminal, so a
    // crash can't leave the user in raw mode with no echo.
    let mut terminal = ratatui::init();
    let outcome = event_loop(&mut terminal, &mut app, &tools);
    ratatui::restore();
    outcome
}

fn event_loop(terminal: &mut ratatui::DefaultTerminal, app: &mut App, tools: &Tools) -> Result<()> {
    loop {
        terminal
            .draw(|frame| render::draw(frame, app))
            .map_err(|err| ToolError::new(format!("Could not draw: {err}")))?;

        let event = event::read().map_err(|err| ToolError::new(format!("Input failed: {err}")))?;
        if let Event::Key(key) = event
            && key.kind == KeyEventKind::Press
        {
            handle_key(app, tools, key);
        }

        if app.should_quit {
            return Ok(());
        }
    }
}

// -- loading ------------------------------------------------------------------

/// Fetches everything the tabs need, tolerating a Checkvist failure.
///
/// A missing remote key is the state a fresh install is in, and it must not be
/// fatal: the Daily tab reads local files and stays fully usable, so the error
/// is carried in `Data::task_error` and shown on the tabs that needed it.
fn load(tools: &Tools) -> Data {
    let mut data = Data::default();

    match tools.call("task_fetch", &arguments(&[("with_notes", json!(false))])) {
        Ok(outcome) => data.tasks = outcome.payload.as_array().cloned().unwrap_or_default(),
        Err(error) => data.task_error = Some(error.message),
    }
    if let Ok(outcome) = tools.call("task_metadata", &Map::new()) {
        data.metadata = outcome.payload;
    }
    if let Ok(outcome) = tools.call("dailies_list", &Map::new()) {
        data.dailies = outcome.payload;
    }
    if let Ok(outcome) = tools.call("daily_log_fetch", &arguments(&[("days", json!(1))])) {
        data.today = outcome
            .payload
            .as_array()
            .and_then(|days| days.first().cloned());
    }

    data
}

fn reload_tasks(app: &mut App, tools: &Tools) {
    match tools.call("task_fetch", &arguments(&[("with_notes", json!(false))])) {
        Ok(outcome) => {
            app.data.tasks = outcome.payload.as_array().cloned().unwrap_or_default();
            app.data.task_error = None;
        }
        Err(error) => app.data.task_error = Some(error.message),
    }
    if let Ok(outcome) = tools.call("task_metadata", &Map::new()) {
        app.data.metadata = outcome.payload;
    }
    app.clamp_selection();
}

fn reload_dailies(app: &mut App, tools: &Tools) {
    if let Ok(outcome) = tools.call("dailies_list", &Map::new()) {
        app.data.dailies = outcome.payload;
    }
    if let Ok(outcome) = tools.call("daily_log_fetch", &arguments(&[("days", json!(1))])) {
        app.data.today = outcome
            .payload
            .as_array()
            .and_then(|days| days.first().cloned());
    }
    app.clamp_selection();
}

fn arguments(pairs: &[(&str, Value)]) -> Map<String, Value> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_string(), value.clone()))
        .collect()
}

// -- keys ---------------------------------------------------------------------

fn handle_key(app: &mut App, tools: &Tools, key: KeyEvent) {
    if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('c')) {
        app.should_quit = true;
        return;
    }

    // Typing a new task or daily swallows everything else, so `q` inserts a
    // letter rather than jumping to the All tab mid-word.
    if app.input.is_some() {
        handle_input_key(app, tools, key);
        return;
    }

    app.status = None;

    if app.show_help {
        // Any key closes help, so it can never trap someone.
        app.show_help = false;
        if matches!(key.code, KeyCode::Esc | KeyCode::Char('?')) {
            return;
        }
    }

    match key.code {
        KeyCode::Esc => app.should_quit = true,
        KeyCode::Char('?') => app.show_help = true,

        KeyCode::Char(character) if Tab::from_jump_key(character).is_some() => {
            if let Some(tab) = Tab::from_jump_key(character) {
                app.select_tab(tab);
            }
        }
        KeyCode::Tab => {
            let next = app.tab.cycled(1);
            app.select_tab(next);
        }
        KeyCode::BackTab => {
            let next = app.tab.cycled(-1);
            app.select_tab(next);
        }

        KeyCode::Char('j') | KeyCode::Down => app.move_selection(1),
        KeyCode::Char('k') | KeyCode::Up => app.move_selection(-1),
        // `l`/`h` open and shut a task in place, as in the app; `]`/`[` are the
        // pair that changes what the whole list is showing, also as in the app.
        KeyCode::Char('l') | KeyCode::Right => app.expand_or_descend(),
        KeyCode::Char('h') | KeyCode::Left => app.collapse_or_ascend(),
        KeyCode::Char(']') => app.enter_scope(),
        KeyCode::Char('[') => app.exit_scope(),

        KeyCode::Char(' ') => toggle_selected(app, tools),
        KeyCode::Char('u') => act_on_task(app, tools, "task_reopen", "Reopened"),
        KeyCode::Char('x') => act_on_task(app, tools, "task_invalidate", "Marked won't do"),

        KeyCode::Char('a') => app.input = Some(String::new()),

        KeyCode::F(5) => {
            reload_tasks(app, tools);
            reload_dailies(app, tools);
            app.status = Some("Refreshed.".into());
        }
        KeyCode::Char('r') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            reload_tasks(app, tools);
            reload_dailies(app, tools);
            app.status = Some("Refreshed.".into());
        }

        _ => {}
    }
}

fn handle_input_key(app: &mut App, tools: &Tools, key: KeyEvent) {
    match key.code {
        KeyCode::Esc => app.input = None,
        KeyCode::Backspace => {
            if let Some(buffer) = app.input.as_mut() {
                buffer.pop();
            }
        }
        KeyCode::Enter => {
            let text = app.input.take().unwrap_or_default().trim().to_string();
            if text.is_empty() {
                return;
            }
            submit(app, tools, &text);
        }
        KeyCode::Char(character) => {
            if let Some(buffer) = app.input.as_mut() {
                buffer.push(character);
            }
        }
        _ => {}
    }
}

fn submit(app: &mut App, tools: &Tools, text: &str) {
    if app.tab == Tab::Daily {
        match tools.call("daily_add", &arguments(&[("title", json!(text))])) {
            Ok(_) => {
                reload_dailies(app, tools);
                app.status = Some(format!("Added daily “{text}”."));
            }
            Err(error) => app.status = Some(error.message),
        }
        return;
    }

    let mut args = arguments(&[("content", json!(text))]);
    // Adding while scoped puts the task where you're looking, which is what
    // the app's quick-add does too.
    if let Some(parent) = app.scope {
        args.insert("location".into(), json!("specific"));
        args.insert("parent_task_id".into(), json!(parent));
    }
    match tools.call("task_add", &args) {
        Ok(_) => {
            reload_tasks(app, tools);
            app.status = Some(format!("Added “{text}”."));
        }
        Err(error) => app.status = Some(error.message),
    }
}

/// `space` — complete an open task, reopen a closed one, or flip a daily.
fn toggle_selected(app: &mut App, tools: &Tools) {
    if let Some(daily_id) = app.selected_daily_id() {
        let done = app
            .selected_row()
            .and_then(|row| match row {
                state::Row::Daily { index } => app.data.daily(index).cloned(),
                _ => None,
            })
            .and_then(|daily| daily.get("done").and_then(Value::as_bool))
            .unwrap_or(false);

        let args = arguments(&[("daily_id", json!(daily_id)), ("done", json!(!done))]);
        match tools.call("daily_tick", &args) {
            Ok(_) => {
                reload_dailies(app, tools);
                app.status = Some(if done {
                    "Un-ticked.".into()
                } else {
                    "Ticked.".to_string()
                });
            }
            Err(error) => app.status = Some(error.message),
        }
        return;
    }

    let Some(task_id) = app.selected_task_id() else {
        return;
    };
    let closed = app
        .data
        .tasks
        .iter()
        .find(|task| task.get("id").and_then(Value::as_i64) == Some(task_id))
        .map(|task| crate::checkvist::status_of(task) != 0)
        .unwrap_or(false);

    let (tool, label) = if closed {
        ("task_reopen", "Reopened")
    } else {
        ("task_complete", "Completed")
    };
    act_on_task(app, tools, tool, label);
}

fn act_on_task(app: &mut App, tools: &Tools, tool: &str, label: &str) {
    let Some(task_id) = app.selected_task_id() else {
        return;
    };
    match tools.call(tool, &arguments(&[("task_id", json!(task_id))])) {
        Ok(_) => {
            reload_tasks(app, tools);
            app.status = Some(format!("{label}."));
        }
        Err(error) => app.status = Some(error.message),
    }
}
