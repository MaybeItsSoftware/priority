//! Text handled the way Swift's `String` handles it, for engines ported from
//! Swift whose results have to match the copy they replaced.
//!
//! Three differences from Rust's own string methods matter: Swift compares
//! strings by canonical equivalence (a precomposed `é` equals `e` plus a
//! combining accent), it splits and counts by grapheme cluster, so `\r\n` is
//! one `Character` that is not `\n`, and Foundation's whitespace and newline
//! sets are Unicode's White_Space between them.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// Swift's `==` on two strings: canonical equivalence rather than bytes.
pub(crate) fn same(a: &str, b: &str) -> bool {
    a == b || a.nfc().eq(b.nfc())
}

/// `same` for optional strings, as Swift compares `String?`.
pub(crate) fn same_optional(a: Option<&str>, b: Option<&str>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => same(a, b),
        _ => false,
    }
}

/// Swift's `hasPrefix`, which compares `Character` by `Character`: the prefix
/// has to end on a grapheme boundary of the candidate, and compare equal
/// under canonical equivalence.
pub(crate) fn has_prefix(candidate: &str, prefix: &str) -> bool {
    let candidate: String = candidate.nfc().collect();
    let prefix: String = prefix.nfc().collect();
    let mut candidate = candidate.graphemes(true);
    prefix
        .graphemes(true)
        .all(|grapheme| candidate.next() == Some(grapheme))
}

/// Swift's `String.count`: grapheme clusters.
pub(crate) fn character_count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`: Foundation's
/// whitespace and newline sets together are exactly Unicode's White_Space,
/// which is what `str::trim` strips.
pub(crate) fn trim(text: &str) -> &str {
    text.trim()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_equivalents_compare_equal() {
        assert!(same("caf\u{e9}", "cafe\u{301}"));
        assert!(!same("cafe", "caf\u{e9}"));
        assert!(same_optional(None, None));
        assert!(!same_optional(Some(""), None));
    }

    #[test]
    fn a_prefix_has_to_end_on_a_character_boundary() {
        assert!(has_prefix("Due Friday\nmore", "Due Friday"));
        assert!(!has_prefix("cafe\u{301}", "cafe"));
        assert!(has_prefix("cafe\u{301} au lait", "caf\u{e9}"));
        assert!(has_prefix("anything", ""));
    }

    #[test]
    fn trim_strips_spaces_and_newlines() {
        assert_eq!(trim("\u{3000}a\u{2028}"), "a");
    }
}
