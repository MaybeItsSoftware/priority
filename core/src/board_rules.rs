//! The board's and the matrix's rules the clients drew themselves: which
//! subtasks stand as cards of their own in another column, the id a new
//! column takes from its title, and how the matrix sorts cards into its
//! quadrants. The Mac and iPhone (`WorkspaceScopeShaping.board`,
//! `MatrixQuadrantIndex`, the column editors) and Android (`BoardShaping`)
//! each had a copy. Every call takes plain values and answers with indices or
//! one string, so nothing a screen draws crosses back; each runs once per
//! refresh, never per frame.

/// Which rows are subtasks filed in another column than their parent's card,
/// so that the board draws them as cards of their own there.
///
/// The rows are the board's tree in drawing order. `parents[i]` is the index
/// of row `i`'s parent among them, or -1; `filed[i]` the column row `i` is
/// filed in, as a code the caller assigned (-1 unfiled); `eligible[i]`
/// whether the row may stand on its own at all (not a card already, not a
/// list, not hidden). A row's column is the one it is filed in, else its
/// parent's, else `fallback` (the first stock column). A row is cross-column
/// when it is eligible, has a parent and is filed in a column other than its
/// parent's. The answer is row indices, ascending.
#[uniffi::export]
pub fn board_cross_column(
    parents: Vec<i32>,
    filed: Vec<i32>,
    eligible: Vec<bool>,
    fallback: i32,
) -> Vec<u32> {
    let count = parents.len().min(filed.len()).min(eligible.len());
    let mut effective: Vec<Option<i32>> = vec![None; count];
    let parent_of = |index: usize| -> Option<usize> {
        usize::try_from(parents[index])
            .ok()
            .filter(|&parent| parent < count)
    };
    let column_of = |start: usize, effective: &mut Vec<Option<i32>>| -> i32 {
        // Walk up to the first row that is filed or already known, then fill
        // the chain in on the way back. A cycle (a corrupt read) ends at the
        // fallback rather than looping.
        let mut chain = Vec::new();
        let mut current = Some(start);
        let mut answer = fallback;
        while let Some(index) = current {
            if let Some(known) = effective[index] {
                answer = known;
                break;
            }
            if filed[index] >= 0 {
                answer = filed[index];
                chain.push(index);
                break;
            }
            if chain.len() > count {
                break;
            }
            chain.push(index);
            current = parent_of(index);
        }
        for index in chain {
            effective[index] = Some(answer);
        }
        answer
    };
    (0..count)
        .filter(|&index| {
            if !eligible[index] || filed[index] < 0 {
                return false;
            }
            let Some(parent) = parent_of(index) else {
                return false;
            };
            filed[index] != column_of(parent, &mut effective)
        })
        .map(|index| index as u32)
        .collect()
}

/// The id a new column takes from its title, unique among `taken`: lowercase,
/// every run of anything but `a-z` and `0-9` a dash, dashes trimmed, `column`
/// when nothing is left, then `-2`, `-3`… until unused.
#[uniffi::export]
pub fn board_column_id(title: String, taken: Vec<String>) -> String {
    let mut base = String::new();
    let mut dash = false;
    for character in title.to_lowercase().chars() {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            if dash && !base.is_empty() {
                base.push('-');
            }
            dash = false;
            base.push(character);
        } else {
            dash = true;
        }
    }
    if base.is_empty() {
        base = "column".to_string();
    }
    if !taken.contains(&base) {
        return base;
    }
    (2..)
        .map(|counter| format!("{base}-{counter}"))
        .find(|candidate| !taken.contains(candidate))
        .unwrap_or(base)
}

/// The matrix's cards sorted into its quadrants, as row indices.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MatrixArrangement {
    /// Cards missing either coordinate, in the order given.
    pub unplaced: Vec<u32>,
    /// The four quadrants in reading order: do now, schedule, delegate,
    /// eliminate.
    pub quadrants: Vec<Vec<u32>>,
}

/// Which quadrant a position falls in, in reading order (0 do now, 1
/// schedule, 2 delegate, 3 eliminate); none while either axis is unset. An
/// axis counts when it is above zero, so the boards' 0 and 1 and the
/// inspectors' -5 and 5 land in the same quadrant.
#[uniffi::export]
pub fn matrix_quadrant(urgency: Option<i32>, importance: Option<i32>) -> Option<u32> {
    let (urgent, important) = (urgency? > 0, importance? > 0);
    Some(match (urgent, important) {
        (true, true) => 0,
        (false, true) => 1,
        (true, false) => 2,
        (false, false) => 3,
    })
}

/// Sorts cards into the matrix: within a quadrant the ones dropped at a point
/// come first by `rank`, lowest first, then the rest in the order given.
#[uniffi::export]
pub fn matrix_arrangement(
    urgency: Vec<Option<i32>>,
    importance: Vec<Option<i32>>,
    rank: Vec<Option<i32>>,
) -> MatrixArrangement {
    let count = urgency.len().min(importance.len()).min(rank.len());
    let mut unplaced = Vec::new();
    let mut quadrants: Vec<Vec<u32>> = vec![Vec::new(); 4];
    for index in 0..count {
        match matrix_quadrant(urgency[index], importance[index]) {
            Some(quadrant) => quadrants[quadrant as usize].push(index as u32),
            None => unplaced.push(index as u32),
        }
    }
    for quadrant in &mut quadrants {
        // Stable, so ties and the unranked keep the order given.
        quadrant.sort_by_key(|&index| rank[index as usize].map_or((1, 0), |rank| (0, rank)));
    }
    MatrixArrangement {
        unplaced,
        quadrants,
    }
}

#[cfg(test)]
mod tests;
