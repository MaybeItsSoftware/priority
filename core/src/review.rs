//! The phones' Review screen: one day of focus as a timeline, and the
//! progress charts over a period.
//!
//! The iPhone's `ReviewModel` and Android's `ReviewModels.kt` each shaped
//! these from the same rows. Both now call here and keep only their view
//! types.
//!
//! The timeline's blocks are drawn one by one, so they cross anyway and
//! `review_timeline` takes them and hands back indices, as `progress.rs`
//! does. The progress charts draw one bar a day, so
//! `CoreWorkspace::review_progress` reads the period's completions, creations
//! and blocks itself and only the days cross.

use std::collections::HashMap;

use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::Tz;
use rusqlite::Connection;

use crate::CoreError;
use crate::periodic;
use crate::progress::{
    self, FocusTimelineEntry, TimelineBlock, TimelineLayout, TimelineSummary, WorkBlockSeconds,
};
use crate::rows;
use crate::workspace::CoreWorkspace;

fn local_date(ms: i64, zone: Tz) -> NaiveDate {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .with_timezone(&zone)
        .date_naive()
}

// -- the timeline ---------------------------------------------------------------

/// A block of the day as the timeline is given it: a logged block, or the
/// one running now. `TimelineDay.Input`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewTimelineBlock {
    pub id: String,
    /// The task the block belongs to, kept across renames and deletion.
    pub task_key: String,
    pub seconds: i64,
    /// When the block was logged. Ignored for the running block, which ends
    /// now.
    pub ended_at_ms: i64,
    pub is_live: bool,
}

/// An award as the timeline counts it: it shares its block's id.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReviewAwardPoints {
    pub id: String,
    pub points: f64,
}

/// One day of focus, shaped. Every index is into the blocks given.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReviewTimeline {
    /// The blocks the day shows, in the order given: logged blocks with time
    /// in them, then the running block when it is today's and has started.
    pub kept: Vec<u32>,
    pub layout: TimelineLayout,
    /// Most time first, ties by key; a summary's place is its hue.
    pub summaries: Vec<TimelineSummary>,
    pub total_seconds: i64,
    /// The awards of the logged blocks kept.
    pub points: f64,
}

/// Lays out the day containing `day_ms` from its blocks, groups them by
/// task and adds up their points. `TimelineDay.build`.
#[uniffi::export]
pub fn review_timeline(
    blocks: Vec<ReviewTimelineBlock>,
    awards: Vec<ReviewAwardPoints>,
    day_ms: i64,
    now_ms: i64,
    zone: String,
) -> ReviewTimeline {
    let tz = periodic::zone(&zone);
    let today = local_date(day_ms, tz) == local_date(now_ms, tz);
    let mut kept: Vec<u32> = Vec::new();
    for (index, block) in blocks.iter().enumerate() {
        if block.is_live && !today {
            continue;
        }
        if block.seconds > 0 {
            kept.push(index as u32);
        }
    }
    let ended_at = |block: &ReviewTimelineBlock| {
        if block.is_live {
            now_ms
        } else {
            block.ended_at_ms
        }
    };
    let mut layout = progress::focus_day_layout(
        kept.iter()
            .map(|index| {
                let block = &blocks[*index as usize];
                TimelineBlock {
                    id: block.id.clone(),
                    seconds: block.seconds,
                    ended_at_ms: ended_at(block),
                }
            })
            .collect(),
        day_ms,
        zone,
    );
    for placement in &mut layout.placements {
        placement.block = kept[placement.block as usize];
    }
    let mut summaries = progress::focus_day_summaries(
        kept.iter()
            .map(|index| {
                let block = &blocks[*index as usize];
                FocusTimelineEntry {
                    key: block.task_key.clone(),
                    seconds: block.seconds,
                }
            })
            .collect(),
    );
    for summary in &mut summaries {
        summary.latest = kept[summary.latest as usize];
    }
    let mut points_by_id: HashMap<&str, f64> = HashMap::new();
    for award in &awards {
        points_by_id
            .entry(award.id.as_str())
            .or_insert(award.points);
    }
    let points = kept
        .iter()
        .map(|index| &blocks[*index as usize])
        .filter(|block| !block.is_live)
        .filter_map(|block| points_by_id.get(block.id.as_str()))
        .sum();
    ReviewTimeline {
        total_seconds: kept
            .iter()
            .map(|index| blocks[*index as usize].seconds)
            .sum(),
        kept,
        layout,
        summaries,
        points,
    }
}

// -- progress over a period -----------------------------------------------------

/// A day of the progress charts. `ProgressDay`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ReviewProgressDay {
    pub day_start_ms: i64,
    pub completed: i64,
    pub added: i64,
    /// Whole minutes of focus logged that day.
    pub focus_minutes: i64,
    pub cumulative_completed: i64,
    pub cumulative_added: i64,
}

/// The period's charts and their totals. `ProgressSummary`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewProgress {
    pub days: Vec<ReviewProgressDay>,
    pub total_completed: i64,
    pub total_added: i64,
    pub focus_minutes: i64,
    /// The first of the days that closed the most, when any closed one.
    pub best_day: Option<u32>,
}

/// The period's days from the moments given: completions, creations and
/// focus blocks bucketed into local days, every day present.
/// `ProgressSummary.build`.
#[uniffi::export]
pub fn summarise_review_progress(
    days: u32,
    completions_ms: Vec<i64>,
    creations_ms: Vec<i64>,
    blocks: Vec<WorkBlockSeconds>,
    now_ms: i64,
    zone: String,
) -> ReviewProgress {
    let tz = periodic::zone(&zone);
    let series =
        progress::task_progress_days(days, completions_ms, creations_ms, now_ms, zone.clone());
    let mut seconds: HashMap<NaiveDate, i64> = HashMap::new();
    for block in &blocks {
        *seconds
            .entry(local_date(block.recorded_at_ms, tz))
            .or_default() += block.seconds;
    }
    let mut cumulative_added = 0;
    let days: Vec<ReviewProgressDay> = series
        .iter()
        .map(|day| {
            cumulative_added += day.added;
            ReviewProgressDay {
                day_start_ms: day.day_start_ms,
                completed: day.completed,
                added: day.added,
                focus_minutes: seconds
                    .get(&local_date(day.day_start_ms, tz))
                    .copied()
                    .unwrap_or(0)
                    / 60,
                cumulative_completed: day.cumulative_completed,
                cumulative_added,
            }
        })
        .collect();
    let mut best_day: Option<u32> = None;
    for (index, day) in days.iter().enumerate() {
        let better = match best_day {
            None => day.completed > 0,
            // Swift's `max(by:)` keeps the first of equal maxima.
            Some(best) => day.completed > days[best as usize].completed,
        };
        if better {
            best_day = Some(index as u32);
        }
    }
    ReviewProgress {
        total_completed: days.iter().map(|day| day.completed).sum(),
        total_added: days.iter().map(|day| day.added).sum(),
        focus_minutes: days.iter().map(|day| day.focus_minutes).sum(),
        days,
        best_day,
    }
}

/// The period's progress from the rows themselves, so no completion, creation
/// or block crosses: only the days do.
pub fn read_review_progress(
    connection: &Connection,
    days: u32,
    now_ms: i64,
    zone: &str,
) -> Result<ReviewProgress, CoreError> {
    let span = progress::task_progress_interval(days, now_ms, zone.to_string());
    let completions = rows::completions_between(connection, span.start_ms, span.end_ms)?;
    let creations = rows::creations_between(connection, span.start_ms, span.end_ms)?;
    let blocks = rows::work_block_seconds_between(connection, span.start_ms, span.end_ms)?;
    Ok(summarise_review_progress(
        days,
        completions,
        creations,
        blocks,
        now_ms,
        zone.to_string(),
    ))
}

#[uniffi::export]
impl CoreWorkspace {
    /// The progress charts over the `days` ending today, read and bucketed
    /// in the core. `ReviewModel.readProgress`.
    pub fn review_progress(
        &self,
        days: u32,
        now_ms: i64,
        zone: String,
    ) -> Result<ReviewProgress, CoreError> {
        read_review_progress(&self.read(), days.max(1), now_ms, &zone)
    }
}

#[cfg(test)]
mod tests;
