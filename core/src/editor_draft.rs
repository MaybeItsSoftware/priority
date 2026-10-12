//! The task editor's draft: the rules behind the inspector's fields between
//! a read and a save.
//!
//! The Mac and iPhone (`TaskEditorDraft.swift`) and Android
//! (`TaskEditorDraft.kt`) each kept a draft over the core's editor snapshot,
//! and each had the same three rules written out: how an estimate typed in
//! minutes reads, how a stored estimate is shown, and what happens to each
//! field when a save lands underneath an open edit. They are here once.
//! Comparing two fields stays with each platform, which holds them in its own
//! types (dates to the nanosecond, typed requirement groups); what crosses is
//! the answers to those comparisons, and what comes back is what to do.

use std::sync::LazyLock;

use regex_lite::Regex;

use crate::CoreError;
use crate::theme::json::swift_description;

static MINUTES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$").expect("a valid pattern"));

/// Minutes as typed (`45`, `1.5`, `.25`), to whole seconds rounded half away
/// from zero; nothing when blank. Refuses anything else, a negative or a
/// value too large to hold.
#[uniffi::export]
pub fn editor_parse_minutes(raw: String) -> Result<Option<i64>, CoreError> {
    let value = raw.trim();
    if value.is_empty() {
        return Ok(None);
    }
    if !MINUTES.is_match(value) {
        return Err(CoreError::InvalidEstimate);
    }
    let minutes: f64 = value.parse().map_err(|_| CoreError::InvalidEstimate)?;
    let seconds = (minutes * 60.0).round();
    if !seconds.is_finite() || seconds >= i64::MAX as f64 {
        return Err(CoreError::InvalidEstimate);
    }
    Ok(Some(seconds as i64))
}

/// A stored number of seconds as the editor shows it in minutes: a whole
/// number of minutes plainly when `whole_minutes_plainly` (`45`), and
/// otherwise as Swift prints the quotient (`1.5`, `2.0`, `0.25`).
#[uniffi::export]
pub fn editor_minutes_text(seconds: i64, whole_minutes_plainly: bool) -> String {
    if whole_minutes_plainly && seconds % 60 == 0 {
        return (seconds / 60).to_string();
    }
    swift_description(seconds as f64 / 60.0)
}

/// One field of an open draft, compared by the platform holding it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EditorFieldComparison {
    /// The draft's value equals the newly saved one.
    pub draft_matches_saved: bool,
    /// The draft's value equals the one it was opened from.
    pub draft_matches_baseline: bool,
    /// The saved value equals the one the draft was opened from.
    pub saved_matches_baseline: bool,
    /// The field is already marked as conflicting.
    pub in_conflict: bool,
}

/// The estimate's own check: the minutes shown can read the same while the
/// seconds underneath differ, so an edited estimate is held to the seconds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorEstimateCheck {
    /// Which of the comparisons is the estimate.
    pub field_index: u32,
    pub draft_text: String,
    pub saved_text: String,
    pub baseline_seconds: Option<i64>,
    pub saved_seconds: Option<i64>,
}

/// What to do with one field when a save lands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EditorFieldOutcome {
    /// Take the saved value: the field was untouched in the draft.
    pub follow_saved: bool,
    /// Mark the field conflicting (`true`), clear it (`false`), or leave it.
    pub conflict: Option<bool>,
}

/// Folds a save into an open draft, field by field: a field that now agrees
/// with the save is settled; one the draft changed (or that already
/// conflicted) conflicts if the save changed it too; any other follows the
/// save. An edited estimate whose seconds the save changed conflicts unless
/// what was typed reads as exactly the saved seconds.
#[uniffi::export]
pub fn editor_reconcile(
    fields: Vec<EditorFieldComparison>,
    estimate: Option<EditorEstimateCheck>,
) -> Vec<EditorFieldOutcome> {
    fields
        .iter()
        .enumerate()
        .map(|(index, field)| {
            let mut outcome = if field.draft_matches_saved {
                EditorFieldOutcome {
                    follow_saved: false,
                    conflict: Some(false),
                }
            } else if !field.draft_matches_baseline || field.in_conflict {
                EditorFieldOutcome {
                    follow_saved: false,
                    conflict: (!field.saved_matches_baseline).then_some(true),
                }
            } else {
                EditorFieldOutcome {
                    follow_saved: true,
                    conflict: None,
                }
            };
            if let Some(check) = estimate
                .as_ref()
                .filter(|check| check.field_index as usize == index)
            {
                let (text, matches_baseline) = if outcome.follow_saved {
                    (&check.saved_text, field.saved_matches_baseline)
                } else {
                    (&check.draft_text, field.draft_matches_baseline)
                };
                if !matches_baseline && check.saved_seconds != check.baseline_seconds {
                    let parsed = editor_parse_minutes(text.clone());
                    let converged = match parsed {
                        Ok(parsed) => {
                            parsed == check.saved_seconds
                                && (text.trim().is_empty() || parsed.is_some())
                        }
                        Err(_) => false,
                    };
                    outcome.conflict = Some(!converged);
                }
            }
            outcome
        })
        .collect()
}

#[cfg(test)]
mod tests;
