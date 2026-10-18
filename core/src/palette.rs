//! Choosing and ordering what a palette shows, for the phones' Find sheet.
//!
//! The phones have one place to go anywhere and do anything — the Find tab —
//! which is the Mac's command palette (⇧⌘P), list navigator (⌘P) and search
//! (⌘F) in one field. Its commands come from the catalogue, restricted to
//! [`phone_palette_commands`], and every row it shows — command, list or
//! filter list — is ordered by [`palette_rank`], so a query lands on the same
//! row on Android and the iPhone.
//!
//! The scoring is the Mac's `WorkspaceCommandQuery` (`Sources/TaktCore`),
//! ported: a subsequence match where word starts and runs score, gaps cost,
//! and the best alignment wins; a typed key outranks any title; the detail
//! line (a command's group, a list's folder) is worth less than the title.

use crate::keymap::{self, CommandEntry, CommandSurface};

/// One row a palette could show.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaletteCandidate {
    pub title: String,
    /// Matched for less than the title: a command's group, a list's folder.
    pub detail: String,
    /// Keys the row answers to, in the catalogue's spelling. Typing one
    /// exactly is the most specific query there is.
    pub keys: Vec<String>,
    /// Added to the row's score: how recently it was used, or how near the
    /// surface it is. Orders the rows when nothing has been typed.
    pub boost: i64,
}

/// How many recently run commands are remembered, and boosted.
pub const RECENT_LIMIT: usize = 20;

/// The most recent command is worth a little more than a surface; the
/// twentieth, a nudge. Enough to reorder close matches, not to lift a poor
/// match over a good one.
const RECENT_STEP: i64 = 12;

/// The indices of the candidates that match `query`, best first. An empty
/// query matches everything, ordered by boost. Ties keep their given order.
#[uniffi::export]
pub fn palette_rank(query: String, candidates: Vec<PaletteCandidate>) -> Vec<u32> {
    rank(&query, &candidates)
}

pub fn rank(query: &str, candidates: &[PaletteCandidate]) -> Vec<u32> {
    let needle = query.trim().to_lowercase();
    let mut scored: Vec<(usize, i64)> = candidates
        .iter()
        .enumerate()
        .filter_map(|(index, candidate)| {
            if needle.is_empty() {
                return Some((index, candidate.boost));
            }
            text_score(&needle, candidate).map(|score| (index, score + candidate.boost))
        })
        .collect();
    // Stable, so the given order breaks ties.
    scored.sort_by_key(|entry| std::cmp::Reverse(entry.1));
    scored.into_iter().map(|(index, _)| index as u32).collect()
}

/// The ids of `commands` that match `query`, best first, the ones in
/// `recents` (most recent first) lifted.
#[uniffi::export]
pub fn palette_rank_commands(
    query: String,
    commands: Vec<CommandEntry>,
    recents: Vec<String>,
) -> Vec<String> {
    let candidates: Vec<PaletteCandidate> = commands
        .iter()
        .map(|command| PaletteCandidate {
            title: command.title.clone(),
            detail: [
                command.group.as_str(),
                command.note.as_deref().unwrap_or(""),
            ]
            .join(" ")
            .trim()
            .to_string(),
            keys: command.keys.clone(),
            boost: recent_boost(&command.id, &recents),
        })
        .collect();
    rank(&query, &candidates)
        .into_iter()
        .map(|index| commands[index as usize].id.clone())
        .collect()
}

/// `recents` with `id` moved to the front and the list capped: what a client
/// stores after running a command from the palette.
#[uniffi::export]
pub fn palette_recording(id: String, recents: Vec<String>) -> Vec<String> {
    std::iter::once(id.clone())
        .chain(recents.into_iter().filter(|recent| *recent != id))
        .take(RECENT_LIMIT)
        .collect()
}

fn recent_boost(id: &str, recents: &[String]) -> i64 {
    recents
        .iter()
        .take(RECENT_LIMIT)
        .position(|recent| recent == id)
        .map_or(0, |index| (RECENT_LIMIT - index) as i64 * RECENT_STEP)
}

/// `None` when the row does not match at all.
fn text_score(needle: &str, candidate: &PaletteCandidate) -> Option<i64> {
    let keys: Vec<String> = candidate
        .keys
        .iter()
        .map(|key| key.to_lowercase())
        .collect();
    if keys.iter().any(|key| key == needle) {
        return Some(1_000);
    }
    // One letter is also the start of the sequences it opens.
    if keys
        .iter()
        .any(|key| keymap::is_sequence(key) && key.starts_with(needle))
    {
        return Some(900);
    }
    let mut best: Option<i64> = None;
    if let Some(fuzzy) = palette_fuzzy_score(needle.to_string(), candidate.title.clone()) {
        // Shorter titles win a tie: "add" means "Add a task" before it means
        // "Add a task above".
        best = Some(400 + fuzzy - candidate.title.chars().count() as i64 / 4);
    }
    if needle.chars().count() > 1 && keys.iter().any(|key| key.contains(needle)) {
        best = Some(best.unwrap_or(0).max(350));
    }
    if let Some(fuzzy) = palette_fuzzy_score(needle.to_string(), candidate.detail.clone()) {
        best = Some(best.unwrap_or(0).max(100 + fuzzy / 2));
    }
    best
}

const MATCH_SCORE: i64 = 16;
const START_BONUS: i64 = 32;
const WORD_START_BONUS: i64 = 24;
const CONTIGUITY_BONUS: i64 = 20;
const GAP_PENALTY: i64 = 2;
const LEADING_PENALTY: i64 = 1;

/// How well `needle` matches `haystack` as a subsequence, or `None` when it
/// does not. Each matched character scores; one that starts a word, or the
/// text, scores more; one that follows the previous match directly scores
/// more again; every character skipped between two matches costs a little.
/// Spaces in the needle are dropped.
#[uniffi::export]
pub fn palette_fuzzy_score(needle: String, haystack: String) -> Option<i64> {
    let query: Vec<char> = needle
        .to_lowercase()
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    let text: Vec<char> = haystack.to_lowercase().chars().collect();
    if query.is_empty() {
        return Some(0);
    }
    if query.len() > text.len() {
        return None;
    }
    let unreachable = i64::MIN / 4;
    let char_score = |index: usize| {
        if index == 0 {
            return MATCH_SCORE + START_BONUS;
        }
        let previous = text[index - 1];
        MATCH_SCORE
            + if previous.is_alphanumeric() {
                0
            } else {
                WORD_START_BONUS
            }
    };
    let mut row = vec![unreachable; text.len()];
    for (index, character) in text.iter().enumerate() {
        if *character == query[0] {
            row[index] = char_score(index) - (index.min(10) as i64) * LEADING_PENALTY;
        }
    }
    for character in query.iter().skip(1) {
        let mut next = vec![unreachable; text.len()];
        let mut gapped = unreachable;
        for index in 0..text.len() {
            if index >= 2 && row[index - 2] > unreachable {
                gapped = gapped.max(row[index - 2]);
            }
            if index >= 2 && gapped > unreachable {
                gapped -= GAP_PENALTY;
            }
            if text[index] != *character {
                continue;
            }
            let adjacent = if index >= 1 && row[index - 1] > unreachable {
                row[index - 1] + CONTIGUITY_BONUS
            } else {
                unreachable
            };
            let best = adjacent.max(gapped);
            if best > unreachable {
                next[index] = best + char_score(index);
            }
        }
        row = next;
    }
    let best = row.into_iter().max().unwrap_or(unreachable);
    (best > unreachable).then_some(best)
}

/// The catalogue commands the phones' palette offers, with the title a phone
/// shows where the Mac's wording names a desktop thing (a panel, a dock).
const PHONE_CATALOGUE: [(&str, Option<&str>); 10] = [
    ("taskNew", None),
    ("goToday", None),
    ("goInbox", None),
    ("goEverything", None),
    ("goFocus", Some("Open Focus")),
    ("goTimeline", Some("Open Review")),
    ("listNew", None),
    ("folderNew", None),
    ("windowUndo", None),
    ("windowRedo", None),
];

/// The phones' own commands: what the Mac does through a window or its menu
/// bar rather than a catalogue row.
const PHONE_OWN: [(&str, &str, &str); 3] = [
    ("phoneGoLists", "Go to Lists", "Go"),
    ("phoneHistory", "Show the undo history", "Window"),
    ("phoneSettings", "Open settings", "Window"),
];

/// Every command the phones' palette offers, in the order it lists them when
/// nothing has been typed. Android and the iPhone each run every one of these
/// ids, which their tests hold them to.
#[uniffi::export]
pub fn phone_palette_commands() -> Vec<CommandEntry> {
    let catalogue = keymap::workspace_command_catalog();
    let mut entries: Vec<CommandEntry> = PHONE_CATALOGUE
        .iter()
        .filter_map(|(id, title)| {
            let mut entry = catalogue.iter().find(|entry| entry.id == *id)?.clone();
            if let Some(title) = title {
                entry.title = title.to_string();
            }
            Some(entry)
        })
        .collect();
    entries.extend(PHONE_OWN.iter().map(|(id, title, group)| CommandEntry {
        id: id.to_string(),
        title: title.to_string(),
        group: group.to_string(),
        keys: Vec::new(),
        surface_keys: Vec::new(),
        surface: CommandSurface::Anywhere,
        motion: false,
        note: None,
    }));
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(title: &str) -> PaletteCandidate {
        PaletteCandidate {
            title: title.to_string(),
            detail: String::new(),
            keys: Vec::new(),
            boost: 0,
        }
    }

    #[test]
    fn fuzzy_prefers_word_starts() {
        let word = palette_fuzzy_score("due".into(), "Clear the due date".into()).unwrap();
        let scattered = palette_fuzzy_score("due".into(), "Do undue things".into()).unwrap();
        assert!(word > scattered);
        assert_eq!(palette_fuzzy_score("xyz".into(), "Add a task".into()), None);
        assert_eq!(palette_fuzzy_score("".into(), "anything".into()), Some(0));
    }

    #[test]
    fn subsequence_reaches_two_word_titles() {
        assert!(palette_fuzzy_score("atk".into(), "Add a task".into()).is_some());
    }

    #[test]
    fn shorter_title_wins_a_tie() {
        let rows = vec![candidate("Add a task above"), candidate("Add a task")];
        assert_eq!(rank("add", &rows), vec![1, 0]);
    }

    #[test]
    fn empty_query_orders_by_boost_and_keeps_ties() {
        let mut rows = vec![candidate("A"), candidate("B"), candidate("C")];
        rows[2].boost = 5;
        assert_eq!(rank("  ", &rows), vec![2, 0, 1]);
    }

    #[test]
    fn exact_key_outranks_title() {
        let mut keyed = candidate("Open Everything");
        keyed.keys = vec!["gh".into()];
        let rows = vec![candidate("gh pages"), keyed];
        assert_eq!(rank("gh", &rows)[0], 1);
        // One letter is the start of a sequence.
        assert_eq!(rank("g", &rows)[0], 1);
    }

    #[test]
    fn detail_matches_for_less() {
        let mut grouped = candidate("Inbox");
        grouped.detail = "Work".into();
        let rows = vec![grouped, candidate("Work log")];
        assert_eq!(rank("work", &rows), vec![1, 0]);
    }

    #[test]
    fn recents_rise_and_recording_caps() {
        let commands = phone_palette_commands();
        let first = rank_ids("", &commands, &[]);
        assert_eq!(first[0], "taskNew");
        let lifted = rank_ids("", &commands, &["windowRedo".to_string()]);
        assert_eq!(lifted[0], "windowRedo");
        let mut recents: Vec<String> = (0..30).map(|n| n.to_string()).collect();
        recents = palette_recording("5".into(), recents);
        assert_eq!(recents.len(), RECENT_LIMIT);
        assert_eq!(recents[0], "5");
        assert_eq!(recents.iter().filter(|id| *id == "5").count(), 1);
    }

    fn rank_ids(query: &str, commands: &[CommandEntry], recents: &[String]) -> Vec<String> {
        palette_rank_commands(query.into(), commands.to_vec(), recents.to_vec())
    }

    #[test]
    fn every_phone_command_is_in_the_catalogue_or_the_phones_own() {
        let commands = phone_palette_commands();
        assert_eq!(commands.len(), PHONE_CATALOGUE.len() + PHONE_OWN.len());
        let goal = rank_ids("focus", &commands, &[]);
        assert_eq!(goal[0], "goFocus");
        let undo = rank_ids("undo", &commands, &[]);
        assert_eq!(undo[0], "windowUndo");
    }
}
