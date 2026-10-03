//! Turning [`App`] into widgets.
//!
//! Split from `state.rs` so the layout logic stays testable: every function
//! here takes state and produces widgets, and `mod.rs` owns the terminal.

use crate::tui::state::{self, App, Row, Tab};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, List, ListItem, ListState, Paragraph, Tabs, Wrap};

const ACCENT: Color = Color::Cyan;
const MUTED: Color = Color::DarkGray;

pub fn draw(frame: &mut Frame, app: &App) {
    let [tab_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    frame.render_widget(tab_bar(app), tab_area);
    render_body(frame, app, body_area);
    frame.render_widget(footer(app), footer_area);

    if app.show_help {
        render_help(frame, frame.area());
    }
}

fn tab_bar(app: &App) -> Tabs<'static> {
    let titles: Vec<Line> = Tab::ORDER
        .iter()
        .map(|tab| {
            Line::from(vec![
                Span::styled(tab.title().to_string(), Style::default()),
                // The jump key alongside the title, so the binding is
                // discoverable without opening help.
                Span::styled(format!(" {}", tab.jump_key()), Style::default().fg(MUTED)),
            ])
        })
        .collect();

    let selected = Tab::ORDER
        .iter()
        .position(|tab| *tab == app.tab)
        .unwrap_or(0);
    Tabs::new(titles)
        .select(selected)
        .highlight_style(Style::default().fg(ACCENT).add_modifier(Modifier::BOLD))
        .divider(Span::styled("│", Style::default().fg(MUTED)))
}

fn render_body(frame: &mut Frame, app: &App, area: Rect) {
    let rows = app.rows();
    let items: Vec<ListItem> = rows.iter().map(|row| list_item(app, row)).collect();

    let mut state = ListState::default();
    if rows.get(app.selected).is_some_and(Row::is_selectable) {
        state.select(Some(app.selected));
    }

    let block = Block::bordered()
        .title(Line::from(title_for(app)).style(Style::default().fg(ACCENT)))
        .border_style(Style::default().fg(MUTED));

    let list = List::new(items)
        .block(block)
        .highlight_symbol("▎")
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED));

    frame.render_stateful_widget(list, area, &mut state);
}

fn title_for(app: &App) -> String {
    match app.tab {
        Tab::All => match app.scope_title() {
            Some(title) => format!(" {} ", truncate(&title, 60)),
            None => " All ".into(),
        },
        Tab::Daily => match state::day_summary(&app.data) {
            Some(summary) => format!(" {summary} "),
            None => " Daily ".into(),
        },
        tab => format!(" {} ", tab.title()),
    }
}

fn list_item<'a>(app: &App, row: &Row) -> ListItem<'a> {
    match row {
        Row::Header(text) => ListItem::new(Line::from(Span::styled(
            text.clone(),
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        ))),

        Row::Note(text) => ListItem::new(Line::from(Span::styled(
            text.clone(),
            Style::default().fg(MUTED),
        ))),

        Row::Task {
            index,
            depth,
            badge,
        } => {
            let Some(task) = app.data.task(*index) else {
                return ListItem::new("");
            };
            let done = crate::checkvist::status_of(task) != 0;

            // A disclosure marker rather than a bare indent: without it, a
            // collapsed parent looks exactly like a leaf.
            let marker = if !state::has_children(&app.data, task) {
                "  "
            } else if app.expanded.contains(&state::id_of(task)) {
                "▾ "
            } else {
                "▸ "
            };

            let mut spans = vec![
                Span::styled("  ".repeat(*depth), Style::default()),
                Span::styled(marker.to_string(), Style::default().fg(MUTED)),
                Span::styled(
                    format!("{} ", state::status_marker(task)),
                    Style::default().fg(if done { MUTED } else { Color::Reset }),
                ),
                Span::styled(
                    state::display_content(task),
                    if done {
                        Style::default()
                            .fg(MUTED)
                            .add_modifier(Modifier::CROSSED_OUT)
                    } else {
                        Style::default()
                    },
                ),
            ];

            if let Some(badge) = badge {
                spans.push(Span::styled(
                    format!("  {badge}"),
                    Style::default().fg(Color::Yellow),
                ));
            }

            let tags = state::tags_of(task);
            if !tags.is_empty() {
                let rendered = tags
                    .iter()
                    .map(|tag| format!("#{tag}"))
                    .collect::<Vec<_>>()
                    .join(" ");
                spans.push(Span::styled(
                    format!("  {rendered}"),
                    Style::default().fg(Color::Blue),
                ));
            }

            ListItem::new(Line::from(spans))
        }

        Row::Daily { index } => {
            let Some(daily) = app.data.daily(*index) else {
                return ListItem::new("");
            };
            let done = daily.get("done") == Some(&serde_json::Value::Bool(true));
            let due_today = daily.get("due_today") == Some(&serde_json::Value::Bool(true));
            let title = daily
                .get("title")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let schedule = daily
                .get("schedule")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");

            // Blank rather than a bullet when it isn't expected today: it is
            // neither done nor outstanding, and a marker would imply otherwise.
            let (marker, style) = match (due_today, done) {
                (_, true) => ("✓ ", Style::default().fg(Color::Green)),
                (true, false) => ("· ", Style::default()),
                (false, false) => ("  ", Style::default().fg(MUTED)),
            };

            ListItem::new(Line::from(vec![
                Span::styled(marker, style),
                Span::styled(format!("{title:<32}"), style),
                Span::styled(schedule.to_string(), Style::default().fg(MUTED)),
            ]))
        }
    }
}

fn footer(app: &App) -> Paragraph<'static> {
    if let Some(buffer) = &app.input {
        let label = if app.tab == Tab::Daily {
            "daily"
        } else {
            "task"
        };
        return Paragraph::new(Line::from(vec![
            Span::styled(format!(" new {label}: "), Style::default().fg(ACCENT)),
            Span::styled(buffer.clone(), Style::default()),
            // A block rather than a real cursor: the list owns the terminal
            // cursor, and moving it would fight the selection highlight.
            Span::styled("▌", Style::default().fg(ACCENT)),
        ]));
    }

    if let Some(status) = &app.status {
        return Paragraph::new(Line::from(Span::styled(
            format!(" {status}"),
            Style::default().fg(Color::Yellow),
        )));
    }

    let hint = match app.tab {
        Tab::Daily => " j/k move · space tick · a add · ? help · esc quit",
        Tab::All => " j/k move · l/h open-shut · ] [ zoom · space done · a add · ? help · esc quit",
        _ => " j/k move · l/h open-shut · space done · a add · ? help · esc quit",
    };
    Paragraph::new(Line::from(Span::styled(hint, Style::default().fg(MUTED))))
}

fn render_help(frame: &mut Frame, area: Rect) {
    let lines = vec![
        Line::from(Span::styled(
            " Takt ",
            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        help_row("q w e r t y d", "Jump to a tab, as in the app"),
        help_row("tab / shift-tab", "Cycle tabs"),
        help_row("j k  ↓ ↑", "Move"),
        help_row("l h  → ←", "Open / shut subtasks; step in and out"),
        help_row("] [", "Zoom into a task, and back out (All)"),
        help_row("space", "Complete a task, or tick a daily"),
        help_row("u", "Reopen a completed task"),
        help_row("x", "Mark won't do"),
        help_row("a", "Add a task, or a daily on the Daily tab"),
        help_row("f5 / ctrl-r", "Refresh from Checkvist"),
        help_row("? ", "This help"),
        help_row("esc", "Close this, or quit"),
        Line::from(""),
        Line::from(Span::styled(
            "  Tabs and keys mirror the menu bar app.",
            Style::default().fg(MUTED),
        )),
    ];

    let popup = centred(60, lines.len() as u16 + 2, area);
    frame.render_widget(Clear, popup);
    frame.render_widget(
        Paragraph::new(lines)
            .block(Block::bordered().border_style(Style::default().fg(ACCENT)))
            .wrap(Wrap { trim: false }),
        popup,
    );
}

fn help_row(keys: &str, what: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("  {keys:<16}"), Style::default().fg(Color::Yellow)),
        Span::styled(what.to_string(), Style::default()),
    ])
}

fn centred(width: u16, height: u16, area: Rect) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect {
        x: area.x + (area.width.saturating_sub(width)) / 2,
        y: area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    }
}

fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    text.chars()
        .take(limit.saturating_sub(1))
        .collect::<String>()
        + "…"
}
