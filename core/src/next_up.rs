//! The day and the focus ladder in one read, so only what is shown crosses.
//!
//! The Mac used to read every candidate (`focus::candidates`) into Swift, plan
//! the day there, and hand every candidate back across for the ranking, which
//! returned them all again. At a few thousand open tasks that was three
//! crossings of every candidate per write, where the work itself was a few
//! milliseconds. Here the candidates are read, the day planned and the ladder
//! ranked without leaving the core, and the ladder is cut to what a client
//! draws.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use chrono_tz::Tz;
use rusqlite::Connection;

use crate::CoreError;
use crate::focus::{self, Candidate, FocusContext};
use crate::periodic;
use crate::ranking::{self, Blocked, Scored};

/// One task in the day and what put it there. `DayPlanEntry`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DayEntry {
    pub id: String,
    /// `DayPlanReason`'s raw value: running, planned, overdue, dueToday or
    /// startsToday.
    pub reason: String,
}

/// The day and the ladder. `WorkspaceNextUpSnapshot`'s ranking half.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NextUp {
    pub day_plan: Vec<DayEntry>,
    /// The ladder, best first. With a limit, its head and every task in the
    /// day, in ladder order; without one, all of it.
    pub ranked: Vec<Scored>,
    /// How long the whole ladder is, whatever was returned.
    pub ranked_count: u64,
    pub blocked: Vec<Blocked>,
    pub next_evaluation_at_ms: Option<i64>,
}

const TODAY_COLUMN: &str = "today";

/// Reads the candidates, plans the day from all of them and ranks them.
/// `ladder_limit` keeps the ladder's first so many entries, plus any task in
/// the day further down, which a client looks up by id.
pub fn next_up(
    connection: &Connection,
    now_ms: i64,
    zone: &str,
    context: &FocusContext,
    running_id: Option<&str>,
    ladder_limit: Option<u32>,
) -> Result<NextUp, CoreError> {
    let candidates = focus::candidates(connection, now_ms, zone)?;
    // The day is gathered from every candidate rather than from the ranked
    // ones: a task due today that a condition rules out is still today's.
    let day_plan = roll_up_cards(connection, plan(&candidates, running_id, now_ms, zone))?;
    let ranking = ranking::evaluate(&candidates, now_ms, zone, context);
    let ranked_count = ranking.ranked.len() as u64;
    let ranked = match ladder_limit {
        None => ranking.ranked,
        Some(limit) => {
            let in_day: HashSet<&str> = day_plan.iter().map(|e| e.id.as_str()).collect();
            ranking
                .ranked
                .into_iter()
                .enumerate()
                .filter(|(index, scored)| {
                    *index < limit as usize || in_day.contains(scored.candidate.id.as_str())
                })
                .map(|(_, scored)| scored)
                .collect()
        }
    };
    Ok(NextUp {
        day_plan,
        ranked,
        ranked_count,
        blocked: ranking.blocked,
        next_evaluation_at_ms: ranking.next_evaluation_at_ms,
    })
}

/// Which tasks make up today, and why. `DayPlanSelector.plan`: the running
/// task, then the Today column in its own order, then the overdue and the due
/// today by deadline, then what starts today by start time. Each task once.
pub fn plan<'a>(
    candidates: &'a [Candidate],
    running_id: Option<&str>,
    now_ms: i64,
    zone: &str,
) -> Vec<DayEntry> {
    let tz = periodic::zone(zone);
    let today = local(now_ms, tz).date_naive();
    let end_of_today = periodic::resolve(
        tz,
        today.and_hms_opt(0, 0, 0).expect("midnight exists") + Duration::days(1),
    )
    .timestamp_millis();

    let mut entries: Vec<DayEntry> = Vec::new();
    let mut claimed: HashSet<&str> = HashSet::new();
    let mut claim = |candidate: &'a Candidate, reason: &str| {
        if claimed.insert(candidate.id.as_str()) {
            entries.push(DayEntry {
                id: candidate.id.clone(),
                reason: reason.to_string(),
            });
        }
    };

    if let Some(running) = running_id.and_then(|id| candidates.iter().find(|c| c.id == id)) {
        claim(running, "running");
    }

    // The column's own arrangement is the one thing here a person chose: a
    // rank given by hand, then the list's order, then the id.
    let mut planned: Vec<&Candidate> = candidates
        .iter()
        .filter(|c| c.kanban_column.as_deref() == Some(TODAY_COLUMN))
        .collect();
    planned.sort_by(|a, b| {
        let rank = match (a.focus_rank, b.focus_rank) {
            (Some(left), Some(right)) => left.cmp(&right),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        };
        rank.then(a.sort_order.cmp(&b.sort_order))
            .then_with(|| a.id.cmp(&b.id))
    });
    for candidate in planned {
        claim(candidate, "planned");
    }

    let mut dated: Vec<(&Candidate, i64)> = candidates
        .iter()
        .filter_map(|c| ranking::effective_deadline(c, tz).map(|at| (c, at)))
        .collect();
    dated.sort_by_key(|(_, at)| *at);
    for (candidate, _) in dated.iter().filter(|(_, at)| *at <= now_ms) {
        claim(candidate, "overdue");
    }
    for (candidate, _) in dated
        .iter()
        .filter(|(_, at)| *at > now_ms && *at <= end_of_today)
    {
        claim(candidate, "dueToday");
    }

    let mut starting: Vec<(&Candidate, i64)> = candidates
        .iter()
        .filter_map(|c| {
            c.start_at_ms
                .filter(|at| local(*at, tz).date_naive() == today)
                .map(|at| (c, at))
        })
        .collect();
    starting.sort_by_key(|(_, at)| *at);
    for (candidate, _) in starting {
        claim(candidate, "startsToday");
    }
    entries
}

/// A task beneath a card planned for today is drawn under that card, as the
/// board draws it, so the day holds the card instead: the topmost open
/// ancestor filed in Today, once, where its first task stood. A parent of
/// open work is never a candidate, so without this a card with subtasks
/// showed only as its loose subtasks. The running task keeps its own row.
fn roll_up_cards(
    connection: &Connection,
    entries: Vec<DayEntry>,
) -> Result<Vec<DayEntry>, CoreError> {
    let mut tree: HashMap<String, (Option<String>, bool, bool)> = HashMap::new();
    let mut statement = connection.prepare(
        "SELECT t.id, t.parentTaskId, t.status = 'open', COALESCE(m.kanbanColumn = ?1, 0)
         FROM tasks t LEFT JOIN task_metadata m ON m.taskId = t.id",
    )?;
    for row in statement.query_map([TODAY_COLUMN], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
        ))
    })? {
        let (id, parent, open, today) = row?;
        tree.insert(id, (parent, open, today));
    }
    let card = |id: &str| -> Option<String> {
        let mut found = None;
        let mut current = tree.get(id).and_then(|(parent, _, _)| parent.clone());
        // Bounded, so a corrupt cycle ends rather than loops.
        for _ in 0..tree.len() {
            let Some(ancestor) = current else { break };
            let Some((parent, open, today)) = tree.get(&ancestor) else {
                break;
            };
            if !open {
                break;
            }
            if *today {
                found = Some(ancestor.clone());
            }
            current = parent.clone();
        }
        found
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut rolled = Vec::with_capacity(entries.len());
    for entry in entries {
        let entry = match (entry.reason != "running")
            .then(|| card(&entry.id))
            .flatten()
        {
            Some(card) => DayEntry {
                id: card,
                reason: "planned".into(),
            },
            None => entry,
        };
        if seen.insert(entry.id.clone()) {
            rolled.push(entry);
        }
    }
    Ok(rolled)
}

fn local(ms: i64, zone: Tz) -> DateTime<Tz> {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&zone)
}

#[cfg(test)]
mod tests;
