//! Text handled the way Swift's `String` handles it, for engines ported from
//! Swift whose results have to match the copy they replaced.
//!
//! Three differences from Rust's own string methods matter: Swift compares
//! strings by canonical equivalence (a precomposed `é` equals `e` plus a
//! combining accent), it splits and counts by grapheme cluster, so `\r\n` is
//! one `Character` that is not `\n`, and Foundation's `.whitespaces` set is
//! the horizontal spaces only, without the line breaks `char::is_whitespace`
//! includes.

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

/// Swift's `split(separator: "\n", omittingEmptySubsequences: false)`. A
/// `\r\n` is one `Character` that is not `\n`, so it does not split.
pub(crate) fn lines(text: &str) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' && (index == 0 || bytes[index - 1] != b'\r') {
            lines.push(&text[start..index]);
            start = index + 1;
        }
    }
    lines.push(&text[start..]);
    lines
}

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators.
pub(crate) fn is_horizontal_space(character: char) -> bool {
    matches!(
        character,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Foundation's `CharacterSet.newlines`.
pub(crate) fn is_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_spaces(text: &str) -> &str {
    text.trim_matches(is_horizontal_space)
}

/// `trimmingCharacters(in: .newlines)`.
pub(crate) fn trim_newlines(text: &str) -> &str {
    text.trim_matches(is_newline)
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`. The union of the two
/// sets above is exactly Unicode's White_Space, which is what `str::trim`
/// strips.
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
    fn a_windows_line_ending_does_not_split() {
        assert_eq!(lines("a\r\nb\nc"), vec!["a\r\nb", "c"]);
        assert_eq!(lines("\n"), vec!["", ""]);
        assert_eq!(lines(""), vec![""]);
    }

    #[test]
    fn spaces_trim_without_newlines() {
        assert_eq!(trim_spaces("\t a \n"), "a \n");
        assert_eq!(trim_newlines("\n a \r\n"), " a ");
        assert_eq!(trim("\u{3000}a\u{2028}"), "a");
    }
}
