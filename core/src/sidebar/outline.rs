//! The sidebar, top to bottom, as one list: the order the view draws and the
//! arrow keys walk. `WorkspaceSidebarOutline` in Swift and Kotlin wraps it.
//!
//! What crosses back names each row by its kind and an index into what was
//! passed in, so a row comes back as three integers and the clients spell the
//! row ids from strings they already hold.

use std::collections::HashSet;

/// A list in the sidebar, and the folder it is filed in.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SidebarList {
    pub id: String,
    pub folder_id: Option<String>,
}

/// A folder, and the folder it sits in.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SidebarFolder {
    pub id: String,
    pub parent_folder_id: Option<String>,
}

/// A list nested inside a task, addressed by the task's id.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SidebarNestedList {
    pub id: String,
    pub list_id: String,
    /// Its depth among the lists above it.
    pub depth: u32,
    pub is_promoted: bool,
}

/// What a row is, and which input its `subject` indexes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SidebarRowKind {
    /// The day, from every list. No subject.
    Today,
    /// No subject.
    Everything,
    /// The inbox. No subject.
    Inbox,
    /// `lists[subject]`.
    List,
    /// `nested_lists[subject]`, in place under its list.
    NestedList,
    /// `nested_lists[subject]` again, as a shortcut at the top.
    PinnedNestedList,
    /// `folders[subject]`.
    Folder,
}

/// One sidebar row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SidebarOutlineRow {
    pub kind: SidebarRowKind,
    /// An index into the input `kind` names; 0 where it names none.
    pub subject: u32,
    /// Indentation: zero for the top-level rows.
    pub depth: u32,
}

/// The rows, top to bottom: Today (when `include_today`) and Everything, the
/// inbox (when `inbox_id` is given) with its nested lists, the pinned nested
/// lists, the folders from the top (each one's lists and their nested lists,
/// then its sub-folders, only while it is in `expanded_folder_ids`), then the
/// lists in no folder. A folder reached twice, through a cycle, is drawn once.
#[uniffi::export]
pub fn sidebar_outline_rows(
    inbox_id: Option<String>,
    lists: Vec<SidebarList>,
    folders: Vec<SidebarFolder>,
    nested_lists: Vec<SidebarNestedList>,
    expanded_folder_ids: Vec<String>,
    include_today: bool,
) -> Vec<SidebarOutlineRow> {
    let mut outline = Outline {
        lists: &lists,
        folders: &folders,
        nested: &nested_lists,
        expanded: expanded_folder_ids.iter().map(String::as_str).collect(),
        visited: HashSet::new(),
        rows: Vec::with_capacity(lists.len() + folders.len() + nested_lists.len() * 2 + 3),
    };
    if include_today {
        outline.push(SidebarRowKind::Today, 0, 0);
    }
    outline.push(SidebarRowKind::Everything, 0, 0);
    if let Some(inbox) = inbox_id.as_deref() {
        outline.push(SidebarRowKind::Inbox, 0, 0);
        outline.nested_under(inbox, 0);
    }
    for (index, nested) in nested_lists.iter().enumerate() {
        if nested.is_promoted {
            outline.push(SidebarRowKind::PinnedNestedList, index, 0);
        }
    }
    for (index, folder) in folders.iter().enumerate() {
        if folder.parent_folder_id.is_none() {
            outline.folder(index, 0);
        }
    }
    for (index, list) in lists.iter().enumerate() {
        if list.folder_id.is_none() {
            outline.list(index, 0);
        }
    }
    outline.rows
}

struct Outline<'a> {
    lists: &'a [SidebarList],
    folders: &'a [SidebarFolder],
    nested: &'a [SidebarNestedList],
    expanded: HashSet<&'a str>,
    visited: HashSet<&'a str>,
    rows: Vec<SidebarOutlineRow>,
}

impl<'a> Outline<'a> {
    fn push(&mut self, kind: SidebarRowKind, subject: usize, depth: u32) {
        self.rows.push(SidebarOutlineRow {
            kind,
            subject: subject as u32,
            depth,
        });
    }

    fn nested_under(&mut self, list_id: &str, depth: u32) {
        let nested = self.nested;
        for (index, entry) in nested.iter().enumerate() {
            if entry.list_id == list_id {
                self.push(SidebarRowKind::NestedList, index, depth + 1 + entry.depth);
            }
        }
    }

    fn list(&mut self, index: usize, depth: u32) {
        let lists = self.lists;
        self.push(SidebarRowKind::List, index, depth);
        self.nested_under(&lists[index].id, depth);
    }

    fn folder(&mut self, index: usize, depth: u32) {
        let (lists, folders) = (self.lists, self.folders);
        let id = folders[index].id.as_str();
        if !self.visited.insert(id) {
            return;
        }
        self.push(SidebarRowKind::Folder, index, depth);
        if !self.expanded.contains(id) {
            return;
        }
        for (list, entry) in lists.iter().enumerate() {
            if entry.folder_id.as_deref() == Some(id) {
                self.list(list, depth + 1);
            }
        }
        for (child, entry) in folders.iter().enumerate() {
            if entry.parent_folder_id.as_deref() == Some(id) {
                self.folder(child, depth + 1);
            }
        }
    }
}

/// Every list inside a folder, its sub-folders' included, in sidebar order:
/// the folder's own lists first, then each sub-folder's. A cycle in the
/// parent chain ends rather than hangs.
#[uniffi::export]
pub fn sidebar_list_ids_in_folder(
    folder_id: String,
    folders: Vec<SidebarFolder>,
    lists: Vec<SidebarList>,
) -> Vec<String> {
    fn descend<'a>(
        id: &'a str,
        folders: &'a [SidebarFolder],
        lists: &'a [SidebarList],
        visited: &mut HashSet<&'a str>,
        result: &mut Vec<String>,
    ) {
        if !visited.insert(id) {
            return;
        }
        result.extend(
            lists
                .iter()
                .filter(|list| list.folder_id.as_deref() == Some(id))
                .map(|list| list.id.clone()),
        );
        for child in folders {
            if child.parent_folder_id.as_deref() == Some(id) {
                descend(&child.id, folders, lists, visited, result);
            }
        }
    }
    let mut result = Vec::new();
    descend(
        &folder_id,
        &folders,
        &lists,
        &mut HashSet::new(),
        &mut result,
    );
    result
}

#[cfg(test)]
mod tests;
