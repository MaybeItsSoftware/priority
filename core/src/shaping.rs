//! Small rules the screens share: where the Blocked label goes, how the day
//! is rearranged by hand, and what the day's estimates still owe.
//!
//! Each was written twice or three times, in Swift's `TaktCore` (with the
//! iPhone borrowing it) and in Kotlin's `:core` or the Android app. Every call
//! takes plain values and answers with indices or numbers, so nothing a
//! screen draws crosses back.

/// Which rows get the "Blocked" label: in each group, the first of the run of
/// blocked rows the group ends with.
///
/// `groups[i]` is the group row `i` belongs to (an outline parent's
/// children, a board column's cards) and `blocked[i]` whether it is drawn as
/// blocked; the rows are in drawing order, and a group's rows need not be
/// contiguous. A blocked row with an unblocked one after it in its group (a
/// stale read, say) is not labelled, since a label there would head a
/// section that is not all blocked. The answer is row indices, ascending.
#[uniffi::export]
pub fn blocked_section_labels(groups: Vec<u32>, blocked: Vec<bool>) -> Vec<u32> {
    use std::collections::{HashMap, HashSet};
    if !blocked.iter().any(|flag| *flag) {
        return Vec::new();
    }
    // Walked from the end: a group's run is open until a row of it that is
    // not blocked closes it.
    let mut run_start: HashMap<u32, u32> = HashMap::new();
    let mut closed: HashSet<u32> = HashSet::new();
    for (index, group) in groups.iter().enumerate().rev() {
        if closed.contains(group) {
            continue;
        }
        if blocked.get(index).copied().unwrap_or(false) {
            run_start.insert(*group, index as u32);
        } else {
            closed.insert(*group);
        }
    }
    let mut labelled: Vec<u32> = run_start.into_values().collect();
    labelled.sort_unstable();
    labelled
}

/// Where the section labels go when siblings are drawn in three sections:
/// open work, then blocked, then buried (`buried`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SiblingSectionLabels {
    /// The rows to draw the "Blocked" label above.
    pub blocked: Vec<u32>,
    /// The rows to draw the "Buried" label above.
    pub buried: Vec<u32>,
}

/// [`blocked_section_labels`] for siblings that may end with buried rows
/// after their blocked ones. In each group the "Buried" label heads the run
/// of buried rows the group ends with, and the "Blocked" label heads the run
/// of blocked rows the rest of it ends with. A row that is both is buried.
///
/// `groups`, `blocked` and `buried` are per row, in drawing order, as for
/// [`blocked_section_labels`]. The answer is row indices, ascending.
#[uniffi::export]
pub fn sibling_section_labels(
    groups: Vec<u32>,
    blocked: Vec<bool>,
    buried: Vec<bool>,
) -> SiblingSectionLabels {
    let is_buried = |index: usize| buried.get(index).copied().unwrap_or(false);
    // The blocked label is placed among the rows that are not buried, then
    // mapped back to the rows' own indices.
    let kept: Vec<usize> = (0..groups.len())
        .filter(|&index| !is_buried(index))
        .collect();
    let blocked_labels = blocked_section_labels(
        kept.iter().map(|&index| groups[index]).collect(),
        kept.iter()
            .map(|&index| blocked.get(index).copied().unwrap_or(false))
            .collect(),
    )
    .into_iter()
    .map(|label| kept[label as usize] as u32)
    .collect();
    SiblingSectionLabels {
        blocked: blocked_labels,
        buried: blocked_section_labels(groups.clone(), (0..groups.len()).map(is_buried).collect()),
    }
}

/// The planned order with `task_id` moved `offset` places, clamped at the
/// ends; nothing when the task is not in the order or cannot move that way,
/// so a caller has nothing to write.
///
/// Only planned rows take part. A derived row (overdue, due today, starting
/// today) is in the day because of a date, and the next read would put it
/// back wherever it was moved.
#[uniffi::export]
pub fn day_arrangement_moving(
    task_id: String,
    offset: i64,
    order: Vec<String>,
) -> Option<Vec<String>> {
    let index = order.iter().position(|id| *id == task_id)?;
    if offset == 0 {
        return None;
    }
    let last = order.len() as i64 - 1;
    let target = (index as i64).saturating_add(offset).clamp(0, last) as usize;
    if target == index {
        return None;
    }
    let mut arranged = order;
    let moved = arranged.remove(index);
    arranged.insert(target, moved);
    Some(arranged)
}

/// The day with its planned slots filled from `order`, in turn, and every
/// other slot as it was; `planned[i]` says whether slot `i` is planned and
/// `ids[i]` is what it holds. Lets the day show a move at once rather than
/// after the next read, which is what keeps a second move pressed quickly
/// moving the same task on from where the first left it. A planned slot left
/// over when `order` runs out keeps its id.
#[uniffi::export]
pub fn day_arrangement_applying(
    order: Vec<String>,
    ids: Vec<String>,
    planned: Vec<bool>,
) -> Vec<String> {
    let mut remaining = order.into_iter();
    ids.into_iter()
        .enumerate()
        .map(|(index, id)| {
            if planned.get(index).copied().unwrap_or(false) {
                remaining.next().unwrap_or(id)
            } else {
                id
            }
        })
        .collect()
}

/// One task on the day, as far as the forecast cares.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DayForecastEntry {
    /// What the task was meant to cost, or nothing when nobody said.
    pub estimate_seconds: Option<i64>,
    /// What it has cost so far, the running block's elapsed time included
    /// when this is the task being worked on.
    pub logged_seconds: i64,
}

/// How much of the day's plan is left and, worked straight through, when it
/// would be done. Deliberately naive: no breaks, no calendar, no hours.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DayForecastSummary {
    /// Every estimate on the day.
    pub estimated_seconds: i64,
    /// Time logged against the day's tasks, estimated or not.
    pub logged_seconds: i64,
    /// What the estimated tasks still owe. A task past its estimate owes
    /// nothing: an overrun on one buys no time back on the others.
    pub remaining_seconds: i64,
    /// Tasks that say nothing about their cost, each making the forecast
    /// optimistic.
    pub unestimated_count: i64,
    /// `now` plus what is left, or nothing when nothing estimated is left.
    pub finish_at_ms: Option<i64>,
}

#[uniffi::export]
pub fn day_forecast(entries: Vec<DayForecastEntry>, now_ms: i64) -> DayForecastSummary {
    let mut estimated = 0i64;
    let mut logged = 0i64;
    let mut remaining = 0i64;
    let mut unestimated = 0i64;
    for entry in entries {
        let spent = entry.logged_seconds.max(0);
        logged += spent;
        match entry.estimate_seconds {
            Some(estimate) if estimate > 0 => {
                estimated += estimate;
                remaining += (estimate - spent).max(0);
            }
            _ => unestimated += 1,
        }
    }
    DayForecastSummary {
        estimated_seconds: estimated,
        logged_seconds: logged,
        remaining_seconds: remaining,
        unestimated_count: unestimated,
        finish_at_ms: (remaining > 0).then(|| now_ms + remaining * 1000),
    }
}

/// The focus context's condition ids with `condition_id` flipped. You are
/// in one place at a time, so turning a location on turns every other
/// location (`location_ids`) off; capabilities ("Floor space", "Quiet")
/// combine freely. Sorted, so the answer is the same however the set was
/// held.
#[uniffi::export]
pub fn focus_context_toggle(
    condition_id: String,
    is_location: bool,
    current: Vec<String>,
    location_ids: Vec<String>,
) -> Vec<String> {
    use std::collections::BTreeSet;
    let mut next: BTreeSet<String> = current.into_iter().collect();
    if !next.remove(&condition_id) {
        if is_location {
            for id in &location_ids {
                next.remove(id);
            }
        }
        next.insert(condition_id);
    }
    next.into_iter().collect()
}

/// A saved context, less any condition that no longer exists (`known`).
/// Archived ones stay: archiving hides a condition from new requirements,
/// not from tasks that already need it. Sorted and without repeats.
#[uniffi::export]
pub fn focus_context_restore(saved: Vec<String>, known: Vec<String>) -> Vec<String> {
    use std::collections::{BTreeSet, HashSet};
    let known: HashSet<String> = known.into_iter().collect();
    saved
        .into_iter()
        .filter(|id| known.contains(id))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// When a deferred task comes back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FocusDeferral {
    /// An hour from now.
    AnHour,
    /// 14:00 today, or an hour from now once that has passed.
    ThisAfternoon,
    /// 09:00 tomorrow.
    Tomorrow,
    /// 09:00 a week from today.
    NextWeek,
}

/// The instant a task deferred `deferral` at `now_ms` comes back, with the
/// wall-clock times read in `zone` (an IANA name).
#[uniffi::export]
pub fn focus_deferral_date(deferral: FocusDeferral, now_ms: i64, zone: String) -> i64 {
    use chrono::{Duration, NaiveTime, TimeZone, Utc};
    const HOUR_MS: i64 = 3_600_000;
    let zone = crate::periodic::zone(&zone);
    let Some(now) = Utc.timestamp_millis_opt(now_ms).single() else {
        return now_ms.saturating_add(HOUR_MS);
    };
    let today = now.with_timezone(&zone).date_naive();
    let at = |days: i64, hour: u32| {
        let day = today + Duration::days(days);
        let time = NaiveTime::from_hms_opt(hour, 0, 0).expect("a valid hour");
        crate::periodic::resolve(zone, day.and_time(time)).timestamp_millis()
    };
    match deferral {
        FocusDeferral::AnHour => now_ms + HOUR_MS,
        FocusDeferral::ThisAfternoon => {
            let afternoon = at(0, 14);
            if afternoon > now_ms {
                afternoon
            } else {
                now_ms + HOUR_MS
            }
        }
        FocusDeferral::Tomorrow => at(1, 9),
        FocusDeferral::NextWeek => at(7, 9),
    }
}

/// Where an arrow key leaves a cursor at `current` in `count` rows. A single
/// step wraps, so the far end of a long list is one key away; a bigger jump
/// (a page) stops at the end, because overshooting and landing near the top
/// again would lose your place.
#[uniffi::export]
pub fn cursor_step(current: i64, offset: i64, count: i64) -> i64 {
    if count <= 0 {
        return 0;
    }
    if offset.abs() == 1 {
        return (current + offset).rem_euclid(count);
    }
    current.saturating_add(offset).clamp(0, count - 1)
}

/// The text a character or title is found by: case and accents folded, as
/// Foundation's case- and diacritic-insensitive folding does.
fn find_key(character: char) -> Option<String> {
    use unicode_normalization::UnicodeNormalization;
    if !character.is_alphanumeric() {
        return None;
    }
    Some(
        character
            .to_string()
            .nfd()
            .filter(|c| !unicode_normalization::char::is_combining_mark(*c))
            .flat_map(char::to_lowercase)
            .collect(),
    )
}

/// Vim's `f` and `F` over rows: the index of the next row (or previous, when
/// `forward` is false) whose title begins with `character`, reading a title
/// from its first letter or digit and ignoring case and accents. The walk
/// wraps; with no `current` it starts before the first row (after the last,
/// backwards), so the first match counts. Nothing when no row matches or
/// `character` is not a letter or digit.
#[uniffi::export]
pub fn vim_find(
    titles: Vec<String>,
    current: Option<i64>,
    character: String,
    forward: bool,
) -> Option<i64> {
    let count = titles.len() as i64;
    let mut characters = character.chars();
    let (Some(first), None) = (characters.next(), characters.next()) else {
        return None;
    };
    let target = find_key(first)?;
    if count == 0 {
        return None;
    }
    let initials: Vec<Option<String>> = titles
        .iter()
        .map(|title| {
            title
                .chars()
                .find(|c| c.is_alphanumeric())
                .and_then(find_key)
        })
        .collect();
    let start = current.unwrap_or(if forward { -1 } else { count });
    (1..=count)
        .map(|step| (start + if forward { step } else { -step }).rem_euclid(count))
        .find(|index| initials[*index as usize].as_deref() == Some(target.as_str()))
}

/// One outline row as a drop reads it: where it sits in the tree.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutlineDropRow {
    pub depth: u32,
    pub parent_id: Option<String>,
    pub list_id: String,
}

/// How a drag in the outline lands in the tree. Every index is into the rows
/// the caller passed, so no id crosses back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OutlineDropPlan {
    /// Placed before its sibling `target`.
    Before { target: u32 },
    /// Moved after the last of its siblings.
    ToEnd,
    /// Joins the children of `anchor`'s parent, in `anchor`'s list: before
    /// `anchor` when `before`, else at the end of those children.
    Reparent { anchor: u32, before: bool },
}

/// Where a row dragged from `source` and dropped at `destination` lands.
///
/// `destination` is the index in `rows`, before the move, that the row is
/// inserted in front of (SwiftUI's `onMove` offset; Compose's reorder passes
/// the same). The moved row takes its visible subtree with it, and a drop
/// inside that block changes nothing. The drop is read from the rows
/// directly above and below where it lands: in front of a sibling it goes
/// before that sibling; after a sibling it goes before the next sibling at
/// that level, or to the end; among another parent's children it joins that
/// parent, before the row it was dropped in front of when that row is at
/// least as deep as the one above, else at the end of the row above's
/// siblings. Two rows are siblings when they share a parent and a list.
/// This is the iPhone's rule, which Android follows too.
#[uniffi::export]
pub fn outline_drop_plan(
    rows: Vec<OutlineDropRow>,
    source: u32,
    destination: u32,
) -> Option<OutlineDropPlan> {
    let source = source as usize;
    let destination = destination as usize;
    let moved = rows.get(source)?;
    let mut end = source + 1;
    while end < rows.len() && rows[end].depth > moved.depth {
        end += 1;
    }
    if destination >= source && destination <= end {
        return None;
    }
    let remaining: Vec<usize> = (0..source).chain(end..rows.len()).collect();
    let adjusted = if destination > source {
        destination - (end - source)
    } else {
        destination
    };
    let sibling = |index: usize| {
        rows[index].parent_id == moved.parent_id && rows[index].list_id == moved.list_id
    };
    let below = remaining.get(adjusted).copied();
    let above = adjusted
        .checked_sub(1)
        .and_then(|index| remaining.get(index).copied());

    if let Some(below) = below.filter(|&index| sibling(index)) {
        return Some(OutlineDropPlan::Before {
            target: below as u32,
        });
    }
    if let Some(above) = above.filter(|&index| sibling(index)) {
        // After the last of its siblings, or after one whose children follow.
        let next = remaining
            .iter()
            .skip(adjusted)
            .copied()
            .find(|&index| rows[index].depth <= rows[above].depth);
        return Some(match next.filter(|&index| sibling(index)) {
            Some(next) => OutlineDropPlan::Before {
                target: next as u32,
            },
            None => OutlineDropPlan::ToEnd,
        });
    }
    // Into another parent's children: the parent of the row it was dropped in
    // front of, or else of the row above.
    match (below, above) {
        (Some(below), None) => Some(OutlineDropPlan::Reparent {
            anchor: below as u32,
            before: true,
        }),
        (Some(below), Some(above)) if rows[below].depth >= rows[above].depth => {
            Some(OutlineDropPlan::Reparent {
                anchor: below as u32,
                before: true,
            })
        }
        (_, Some(above)) => Some(OutlineDropPlan::Reparent {
            anchor: above as u32,
            before: false,
        }),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests;
