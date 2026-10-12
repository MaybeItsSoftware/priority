//! The rules `TaskEditorDraftTests` (Swift) and `TaskEditorDraftTest`
//! (Kotlin) pinned, at the level the core now owns them; both suites still
//! run over the wrappers.

use super::*;

#[test]
fn minutes_read_as_whole_seconds() {
    assert_eq!(editor_parse_minutes("45".into()).unwrap(), Some(2700));
    assert_eq!(editor_parse_minutes(" 1.5\n".into()).unwrap(), Some(90));
    assert_eq!(editor_parse_minutes(".25".into()).unwrap(), Some(15));
    assert_eq!(editor_parse_minutes("2.".into()).unwrap(), Some(120));
    assert_eq!(editor_parse_minutes("  ".into()).unwrap(), None);
    // Half a second rounds away from zero, as Swift's `rounded()` does.
    assert_eq!(editor_parse_minutes("0.025".into()).unwrap(), Some(2));
}

#[test]
fn anything_else_is_refused() {
    for bad in ["-1", "1e3", "abc", "1.2.3", ".", "+5", "1 5", "１"] {
        assert!(editor_parse_minutes(bad.into()).is_err(), "{bad:?}");
    }
    let huge = "9".repeat(400);
    assert!(editor_parse_minutes(huge).is_err());
}

#[test]
fn stored_seconds_show_as_minutes() {
    assert_eq!(editor_minutes_text(2700, true), "45");
    assert_eq!(editor_minutes_text(90, true), "1.5");
    assert_eq!(editor_minutes_text(120, false), "2.0");
    assert_eq!(editor_minutes_text(61, true), "1.0166666666666666");
}

fn compare(
    saved: bool,
    baseline: bool,
    saved_baseline: bool,
    conflict: bool,
) -> EditorFieldComparison {
    EditorFieldComparison {
        draft_matches_saved: saved,
        draft_matches_baseline: baseline,
        saved_matches_baseline: saved_baseline,
        in_conflict: conflict,
    }
}

fn outcome(follow_saved: bool, conflict: Option<bool>) -> EditorFieldOutcome {
    EditorFieldOutcome {
        follow_saved,
        conflict,
    }
}

#[test]
fn an_untouched_field_follows_the_save() {
    assert_eq!(
        editor_reconcile(vec![compare(false, true, false, false)], None),
        [outcome(true, None)]
    );
}

#[test]
fn an_edited_field_the_save_changed_too_conflicts() {
    assert_eq!(
        editor_reconcile(vec![compare(false, false, false, false)], None),
        [outcome(false, Some(true))]
    );
    // Edited, but the save left it alone: nothing to say.
    assert_eq!(
        editor_reconcile(vec![compare(false, false, true, false)], None),
        [outcome(false, None)]
    );
    // Already conflicting stays so while the save still differs.
    assert_eq!(
        editor_reconcile(vec![compare(false, true, false, true)], None),
        [outcome(false, Some(true))]
    );
}

#[test]
fn agreeing_with_the_save_settles_a_conflict() {
    assert_eq!(
        editor_reconcile(vec![compare(true, false, false, true)], None),
        [outcome(false, Some(false))]
    );
}

#[test]
fn an_edited_estimate_is_held_to_the_seconds() {
    let check = |draft: &str, saved: Option<i64>| EditorEstimateCheck {
        field_index: 1,
        draft_text: draft.into(),
        saved_text: "1.0".into(),
        baseline_seconds: Some(60),
        saved_seconds: saved,
    };
    let fields = vec![
        compare(true, true, true, false),
        // "1.0" typed over "1"; the save changed 60 s to 61 s, shown "1.0".
        compare(true, false, false, false),
    ];
    assert_eq!(
        editor_reconcile(fields.clone(), Some(check("1.0", Some(61))))[1],
        outcome(false, Some(true))
    );
    // Typed exactly what was saved: converged.
    assert_eq!(
        editor_reconcile(fields.clone(), Some(check("1.5", Some(90))))[1],
        outcome(false, Some(false))
    );
    // Cleared, and the save cleared it too.
    assert_eq!(
        editor_reconcile(fields.clone(), Some(check(" ", None)))[1],
        outcome(false, Some(false))
    );
    // Unreadable text never converges.
    assert_eq!(
        editor_reconcile(fields, Some(check("abc", None)))[1],
        outcome(false, Some(true))
    );
}
