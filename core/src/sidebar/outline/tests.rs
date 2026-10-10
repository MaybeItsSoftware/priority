//! `WorkspaceSidebarOutlineTests` and `WorkspaceFolderScopeTests` in Swift,
//! and `WorkspaceSidebarOutlineTest` in Kotlin.

use super::*;
use SidebarRowKind::*;

fn list(id: &str, folder: Option<&str>) -> SidebarList {
    SidebarList {
        id: id.into(),
        folder_id: folder.map(Into::into),
    }
}

fn folder(id: &str, parent: Option<&str>) -> SidebarFolder {
    SidebarFolder {
        id: id.into(),
        parent_folder_id: parent.map(Into::into),
    }
}

fn nested(id: &str, list: &str, depth: u32, is_promoted: bool) -> SidebarNestedList {
    SidebarNestedList {
        id: id.into(),
        list_id: list.into(),
        depth,
        is_promoted,
    }
}

/// The rows as `(kind, subject id, depth)`, the subject spelled out.
fn outline(
    inbox: Option<&str>,
    lists: &[SidebarList],
    folders: &[SidebarFolder],
    nested_lists: &[SidebarNestedList],
    expanded: &[&str],
) -> Vec<(SidebarRowKind, String, u32)> {
    sidebar_outline_rows(
        inbox.map(Into::into),
        lists.to_vec(),
        folders.to_vec(),
        nested_lists.to_vec(),
        expanded.iter().map(|id| id.to_string()).collect(),
        true,
    )
    .into_iter()
    .map(|row| {
        let index = row.subject as usize;
        let subject = match row.kind {
            Today | Everything => String::new(),
            Inbox => inbox.unwrap().to_string(),
            List => lists[index].id.clone(),
            NestedList | PinnedNestedList => nested_lists[index].id.clone(),
            Folder => folders[index].id.clone(),
        };
        (row.kind, subject, row.depth)
    })
    .collect()
}

fn kinds(rows: &[(SidebarRowKind, String, u32)]) -> Vec<(SidebarRowKind, &str)> {
    rows.iter()
        .map(|(kind, subject, _)| (*kind, subject.as_str()))
        .collect()
}

#[test]
fn today_comes_first_then_everything() {
    let rows = outline(Some("inbox"), &[], &[], &[], &[]);
    assert_eq!(
        kinds(&rows),
        [(Today, ""), (Everything, ""), (Inbox, "inbox")]
    );
}

#[test]
fn without_today_everything_comes_first() {
    let rows = sidebar_outline_rows(None, vec![], vec![], vec![], vec![], false);
    assert_eq!(
        rows,
        [SidebarOutlineRow {
            kind: Everything,
            subject: 0,
            depth: 0
        }]
    );
}

#[test]
fn the_order_is_inbox_then_pinned_then_folders_then_loose_lists() {
    let rows = outline(
        Some("inbox"),
        &[list("loose", None), list("filed", Some("work"))],
        &[folder("work", None)],
        &[nested("pin", "inbox", 0, true)],
        &["work"],
    );
    assert_eq!(
        kinds(&rows),
        [
            (Today, ""),
            (Everything, ""),
            (Inbox, "inbox"),
            (NestedList, "pin"),
            (PinnedNestedList, "pin"),
            (Folder, "work"),
            (List, "filed"),
            (List, "loose"),
        ]
    );
}

#[test]
fn a_collapsed_folder_hides_its_contents() {
    let lists = [list("filed", Some("work"))];
    let folders = [folder("work", None)];
    let collapsed = outline(Some("inbox"), &lists, &folders, &[], &[]);
    assert!(!kinds(&collapsed).contains(&(List, "filed")));
    let expanded = outline(Some("inbox"), &lists, &folders, &[], &["work"]);
    assert!(kinds(&expanded).contains(&(List, "filed")));
}

#[test]
fn nesting_is_reported_as_depth() {
    let rows = outline(
        None,
        &[list("filed", Some("inner"))],
        &[folder("outer", None), folder("inner", Some("outer"))],
        &[nested("deep", "filed", 1, false)],
        &["outer", "inner"],
    );
    let depth = |kind: SidebarRowKind, id: &str| {
        rows.iter()
            .find(|(k, s, _)| *k == kind && s == id)
            .map(|row| row.2)
    };
    assert_eq!(depth(Folder, "outer"), Some(0));
    assert_eq!(depth(Folder, "inner"), Some(1));
    assert_eq!(depth(List, "filed"), Some(2));
    assert_eq!(depth(NestedList, "deep"), Some(4));
}

#[test]
fn a_folder_cycle_terminates() {
    let rows = outline(
        None,
        &[],
        &[folder("a", Some("b")), folder("b", Some("a"))],
        &[],
        &["a", "b"],
    );
    assert_eq!(kinds(&rows), [(Today, ""), (Everything, "")]);
}

#[test]
fn a_folder_reached_twice_is_drawn_once() {
    // Two roots of the same id: the second is the same folder again.
    let rows = outline(
        None,
        &[list("a", Some("f"))],
        &[folder("f", None), folder("f", None)],
        &[],
        &["f"],
    );
    assert_eq!(
        kinds(&rows),
        [(Today, ""), (Everything, ""), (Folder, "f"), (List, "a")]
    );
}

fn ids(folder_id: &str, folders: &[SidebarFolder], lists: &[SidebarList]) -> Vec<String> {
    sidebar_list_ids_in_folder(folder_id.into(), folders.to_vec(), lists.to_vec())
}

#[test]
fn a_folder_stands_for_its_own_lists() {
    assert_eq!(
        ids(
            "work",
            &[folder("work", None)],
            &[
                list("a", Some("work")),
                list("b", Some("work")),
                list("loose", None)
            ]
        ),
        ["a", "b"]
    );
}

#[test]
fn sub_folder_lists_are_included_own_first() {
    assert_eq!(
        ids(
            "work",
            &[
                folder("work", None),
                folder("clients", Some("work")),
                folder("deep", Some("clients"))
            ],
            &[
                list("c", Some("deep")),
                list("b", Some("clients")),
                list("a", Some("work"))
            ]
        ),
        ["a", "b", "c"]
    );
}

#[test]
fn a_sibling_folder_is_not_included_and_an_empty_one_stands_for_nothing() {
    let folders = [folder("work", None), folder("home", None)];
    assert_eq!(
        ids(
            "work",
            &folders,
            &[list("a", Some("work")), list("b", Some("home"))]
        ),
        ["a"]
    );
    assert!(ids("work", &folders, &[]).is_empty());
}

#[test]
fn a_cycle_in_the_parent_chain_terminates() {
    let mut found = ids(
        "a",
        &[folder("a", Some("b")), folder("b", Some("a"))],
        &[list("one", Some("a")), list("two", Some("b"))],
    );
    found.sort();
    assert_eq!(found, ["one", "two"]);
}
