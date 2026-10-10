//! Ported from `corelogic-tests/AFFiNEDocumentMarkdownTests.swift` and
//! `AFFiNEChecklistMarkdownTests.swift`. The day title and the comment
//! markers' removal stay in Swift with the code they test.

use super::*;

fn task(id: i64, title: &str, depth: i64) -> AffineChecklistTask {
    AffineChecklistTask {
        id,
        title: title.into(),
        permalink: Some(format!("https://checkvist.com/checklists/12#t{id}")),
        depth,
    }
}

fn items(markdown: &str) -> Vec<AffineChecklistItem> {
    read(markdown, CHECKLIST_HEADING).items
}

fn ticked(markdown: &str) -> Vec<i64> {
    items(markdown)
        .into_iter()
        .filter(|item| item.is_checked)
        .filter_map(|item| item.task_id)
        .collect()
}

fn checklist(tasks: &[AffineChecklistTask]) -> String {
    section(tasks, &[], CHECKLIST_HEADING)
}

fn merge_log(section: &str, existing: &str) -> String {
    merged(section, DAY_HEADING, existing)
}

// -- Merging --------------------------------------------------------------------

#[test]
fn writing_a_day_twice_replaces_it_rather_than_stacking_it() {
    let first = merge_log("## Log\n\n**1 done**", "");
    assert_eq!(first, "## Log\n\n**1 done**\n");
    let second = merge_log("## Log\n\n**4 done**", &first);
    assert_eq!(second, "## Log\n\n**4 done**\n");
}

#[test]
fn what_the_user_wrote_around_the_block_survives() {
    let existing = "Woke up late.\n\n## Log\n\n**1 done**\n\n## Evening\n\nRead two chapters.";
    assert_eq!(
        merge_log("## Log\n\n**5 done**", existing),
        "Woke up late.\n\n## Log\n\n**5 done**\n\n## Evening\n\nRead two chapters.\n"
    );
}

#[test]
fn a_subheading_inside_the_block_is_replaced_with_it() {
    let existing = "## Log\n\n**1 done**\n\n### Dailies\n\n- [x] Stretch\n\n# Journal\n\nKept.";
    assert_eq!(
        merge_log("## Log\n\n**2 done**", existing),
        "## Log\n\n**2 done**\n\n# Journal\n\nKept.\n"
    );
}

#[test]
fn a_block_is_appended_to_a_document_that_has_none_yet() {
    assert_eq!(
        merge_log("## Log\n\n**3 done**", "Just some notes.\n\n"),
        "Just some notes.\n\n## Log\n\n**3 done**\n"
    );
}

#[test]
fn near_misses_are_not_treated_as_the_block() {
    let existing = "#Log\n\nnot a heading\n\n### Log\n\nnor this one";
    let merged = merge_log("## Log\n\n**1 done**", existing);
    assert_eq!(merged, format!("{existing}\n\n## Log\n\n**1 done**\n"));
}

#[test]
fn a_body_is_none_without_its_heading_and_empty_under_a_bare_one() {
    assert_eq!(body_under("## Log", "prose"), None);
    assert_eq!(
        body_under("## Log", "## Log\n\n## Next"),
        Some(String::new())
    );
    assert_eq!(
        body_under("## Log", "  ## Log  \n\nbody\n\n### sub\nmore\n## Next"),
        Some("body\n\n### sub\nmore".into())
    );
}

// -- Checklist rendering ----------------------------------------------------------

#[test]
fn tasks_render_as_todo_blocks_carrying_their_permalink() {
    assert_eq!(
        checklist(&[
            task(34, "Write the release notes", 0),
            task(35, "Draft the summary", 1)
        ]),
        "## Tasks\n\n\
         - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)\n  \
         - [ ] [Draft the summary](https://checkvist.com/checklists/12#t35)"
    );
}

#[test]
fn a_task_with_no_permalink_is_still_written() {
    let offline = AffineChecklistTask {
        id: -3,
        title: "Offline task".into(),
        permalink: None,
        depth: 0,
    };
    assert_eq!(checklist(&[offline]), "## Tasks\n\n- [ ] Offline task");
}

#[test]
fn an_empty_list_says_so_rather_than_writing_nothing() {
    assert_eq!(checklist(&[]), "## Tasks\n\n_Nothing open._");
}

#[test]
fn a_blank_title_and_brackets_are_written_safely() {
    assert_eq!(
        checklist(&[task(1, " \n ", 0), task(2, "a\\b [c]", 0)]),
        "## Tasks\n\n\
         - [ ] [(untitled)](https://checkvist.com/checklists/12#t1)\n\
         - [ ] [a\\\\b \\[c\\]](https://checkvist.com/checklists/12#t2)"
    );
}

// -- Checklist reading -------------------------------------------------------------

#[test]
fn ticked_boxes_are_read_back_by_task_id() {
    let markdown = "Some notes of my own.\n\n## Tasks\n\n\
        - [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)\n\
        - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)\n  \
        - [X] [Draft the summary](https://checkvist.com/checklists/12#t35)\n\n\
        ## Evening\n\n- [x] [Not ours](https://example.com/x#t99)";
    assert_eq!(ticked(markdown), vec![31, 35]);
    assert_eq!(items(markdown)[2].depth, 1);
}

#[test]
fn an_export_escaped_line_still_resolves_to_its_task() {
    let markdown =
        "## Tasks\n\n- [x] [Ship the DMG \\(v1\\.2\\)](https://checkvist.com/checklists/12#t31)";
    let found = items(markdown);
    assert_eq!(found[0].task_id, Some(31));
    assert_eq!(found[0].title, "Ship the DMG (v1.2)");
    assert_eq!(ticked(markdown), vec![31]);
}

#[test]
fn a_label_containing_a_bracket_does_not_end_the_link_early() {
    let round = checklist(&[task(7, "Fix [urgent] thing", 0)]);
    let found = items(&round);
    assert_eq!(found[0].task_id, Some(7));
    assert_eq!(found[0].title, "Fix [urgent] thing");
}

#[test]
fn items_outside_the_section_are_ignored() {
    let markdown = "- [x] [Above the section](https://checkvist.com/checklists/12#t1)\n\n\
        ## Tasks\n\n- [ ] [In it](https://checkvist.com/checklists/12#t2)";
    let ids: Vec<Option<i64>> = items(markdown).iter().map(|item| item.task_id).collect();
    assert_eq!(ids, vec![Some(2)]);
}

#[test]
fn a_document_with_no_section_reads_as_nothing_rather_than_everything() {
    assert!(items("Just prose.\n\n- [x] a todo").is_empty());
}

#[test]
fn lines_that_are_not_todo_items_are_not_items() {
    for line in ["-[ ] a", "- [y] a", "- [ ]", "1. [ ] a", "- [x", "* text"] {
        let is_item = item_from(line).is_some();
        assert_eq!(is_item, line == "- [ ]", "{line:?}");
    }
    let tabbed = item_from("\t* [x]   spaced  ").unwrap();
    assert_eq!(
        (tabbed.depth, tabbed.title.as_str(), tabbed.is_checked),
        (1, "spaced", true)
    );
    // A link that never closes is read as plain text.
    let open = item_from("- [ ] [label](no close").unwrap();
    assert_eq!(
        (open.task_id, open.title.as_str()),
        (None, "[label](no close")
    );
}

// -- What Takt does not own ---------------------------------------------------------

#[test]
fn hand_written_items_are_carried_through() {
    let markdown = "## Tasks\n\n\
        - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)\n\
        - [ ] buy milk\nremember to call the bank";
    let carried = read(markdown, CHECKLIST_HEADING).unowned_lines;
    assert_eq!(carried, vec!["- [ ] buy milk", "remember to call the bank"]);

    let rewritten = section(
        &[task(34, "Write the release notes", 0)],
        &carried,
        CHECKLIST_HEADING,
    );
    assert_eq!(
        rewritten,
        "## Tasks\n\n\
         - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)\n\n\
         - [ ] buy milk\nremember to call the bank"
    );
}

#[test]
fn our_own_empty_placeholder_is_not_carried_back() {
    assert!(
        read("## Tasks\n\n_Nothing open._", CHECKLIST_HEADING)
            .unowned_lines
            .is_empty()
    );
}

// -- Change detection ----------------------------------------------------------------

#[test]
fn an_unchanged_list_matches_its_export_even_after_escaping() {
    let tasks = [
        task(31, "Ship the DMG (v1.2)", 0),
        task(34, "Review the sync PR", 1),
    ];
    let exported = "## Tasks\n\n\
        - [ ] [Ship the DMG \\(v1\\.2\\)](https://checkvist.com/checklists/12#t31)\n  \
        - [ ] [Review the sync PR](https://checkvist.com/checklists/12#t34)";
    assert!(matches(&items(exported), &tasks));
}

#[test]
fn a_changed_list_does_not_match() {
    let found = items("## Tasks\n\n- [ ] [Ship the DMG](https://checkvist.com/checklists/12#t31)");
    assert!(
        !matches(&found, &[task(31, "Ship the DMG", 0), task(34, "New", 0)]),
        "a task added in Takt is a change"
    );
    assert!(
        !matches(&found, &[task(31, "Ship the DMG v2", 0)]),
        "a reworded task is a change"
    );
    assert!(
        !matches(&found, &[task(31, "Ship the DMG", 1)]),
        "a task that moved under a parent is a change"
    );
    assert!(matches(&found, &[task(31, "Ship the DMG", 0)]));
}

#[test]
fn a_ticked_item_never_matches() {
    let found = items("## Tasks\n\n- [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)");
    assert!(!matches(&found, &[task(31, "Ship the DMG", 0)]));
}

#[test]
fn a_rewrite_is_skipped_only_when_nothing_changed() {
    let existing = "Intro\n\n## Tasks\n\n\
        - [ ] [Ship](https://checkvist.com/checklists/12#t31)\n- [ ] milk\n\n## After\n\nkept";
    let tasks = vec![task(31, "Ship", 0)];
    assert_eq!(
        affine_checklist_rewrite(
            existing.into(),
            tasks.clone(),
            CHECKLIST_HEADING.into(),
            false
        ),
        None
    );
    assert_eq!(
        affine_checklist_rewrite(existing.into(), vec![], CHECKLIST_HEADING.into(), true),
        Some("Intro\n\n## Tasks\n\n- [ ] milk\n\n## After\n\nkept\n".into())
    );
}

// -- Permalinks ---------------------------------------------------------------------

#[test]
fn task_ids_come_off_the_permalink_fragment() {
    assert_eq!(
        task_id_in_permalink("https://checkvist.com/checklists/12#t34"),
        Some(34)
    );
    assert_eq!(task_id_in_permalink("https://elsewhere/x#t9"), Some(9));
    assert_eq!(
        task_id_in_permalink("https://checkvist.com/checklists/12"),
        None
    );
    assert_eq!(task_id_in_permalink("https://example.com/#tasks"), None);
    assert_eq!(task_id_in_permalink("x#t"), None);
    assert_eq!(task_id_in_permalink("x#t99999999999999999999"), None);
}

// -- Line endings -------------------------------------------------------------------

/// Swift splits by `Character`, and `\r\n` is one: a Windows line ending does
/// not end a line, so neither does it here.
#[test]
fn a_windows_line_ending_does_not_split_a_line() {
    assert_eq!(body_under("## Log", "## Log\r\nbody"), None);
}
