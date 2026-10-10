//! Reconciling Takt's lists with Google Tasks: given both sides and what was
//! last pushed, the plan of what to do. Doing it is HTTP, which stays with the
//! client; deciding it is here, in one call per pass.
//!
//! Takt is the authority, which is a narrower claim than "one-way sync".
//! Three things hold at once:
//!
//! - **Takt wins a disagreement.** A title, a due date or a list name edited
//!   on the Google side loses to the local one, and the plan pushes the local
//!   value back over it.
//! - **Ticking something off counts, wherever you tick it.** A task completed
//!   in Google completes locally rather than being un-completed next pass.
//! - **Nothing a person typed is thrown away.** Notes added on the Google side
//!   where Takt had none, or appended to what it wrote, are merged back; a
//!   task created in Google is adopted into the list it was created in.
//!
//! Everything Takt does overwrite is returned as a conflict, so the one case
//! where the authority rule destroys something can be read back.
//!
//! Replaces the planner in Swift's `GoogleTasksMirror`, which keeps its types
//! and wraps this. Due days arrive already in Google's form (the local day at
//! midnight UTC): reducing a date to a day is the caller's calendar's job.
//! Strings compare as Swift compares them (`swift_text`), so a note Google
//! hands back in another normal form is not a fresh conflict every pass.

use std::collections::{HashMap, HashSet};

use crate::swift_text;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksLocalList {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksLocalTask {
    pub id: String,
    pub list_id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub notes: String,
    /// The due day in Google's form, `yyyy-MM-ddT00:00:00.000Z`.
    pub due: Option<String>,
    pub is_completed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksRemoteList {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksRemoteTask {
    pub id: String,
    pub list_id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub notes: String,
    /// Google's own RFC 3339 string, verbatim.
    pub due: Option<String>,
    pub is_completed: bool,
    /// Google marks a deleted task for a while rather than dropping it.
    pub is_deleted: bool,
}

/// What was pushed to Google last time for one local task. Without it a
/// remote edit and Takt's own echo look the same.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksLedgerEntry {
    pub local_id: String,
    pub remote_id: String,
    pub remote_list_id: String,
    pub pushed_title: String,
    pub pushed_notes: String,
    pub pushed_due: Option<String>,
    pub pushed_completed: bool,
}

/// A local list and the Google list mirroring it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksListMapping {
    pub local_list_id: String,
    pub remote_list_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksPayload {
    pub title: String,
    pub notes: String,
    pub due: Option<String>,
    pub is_completed: bool,
    /// The Google task this one hangs under, when the local parent is mirrored
    /// in the same list and is itself top level.
    pub parent_remote_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GoogleTasksOperation {
    CreateList {
        local_list_id: String,
        title: String,
    },
    /// An unmapped Google list with exactly the title of a local list that has
    /// no copy: the mirror finding its own list again after losing the ledger.
    AdoptRemoteList {
        local_list_id: String,
        remote_list_id: String,
    },
    RenameList {
        remote_list_id: String,
        title: String,
    },
    DeleteList {
        remote_list_id: String,
        local_list_id: String,
    },
    CreateTask {
        local_id: String,
        remote_list_id: String,
        payload: GoogleTasksPayload,
    },
    UpdateTask {
        local_id: String,
        remote_id: String,
        remote_list_id: String,
        payload: GoogleTasksPayload,
    },
    DeleteTask {
        remote_id: String,
        remote_list_id: String,
        local_id: String,
    },
    CompleteLocalTask {
        local_id: String,
    },
    MergeNotesIntoLocalTask {
        local_id: String,
        notes: String,
    },
    AdoptRemoteTask {
        remote_id: String,
        remote_list_id: String,
        local_list_id: String,
        payload: GoogleTasksPayload,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GoogleTasksConflictField {
    Title,
    Notes,
    Due,
    Existence,
}

/// Something Takt overwrote because it had the final say.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GoogleTasksConflict {
    pub local_id: String,
    pub remote_id: String,
    pub field: GoogleTasksConflictField,
    pub local_value: String,
    pub remote_value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct GoogleTasksPlan {
    pub operations: Vec<GoogleTasksOperation>,
    pub conflicts: Vec<GoogleTasksConflict>,
}

/// Works out what has to happen for the two sides to agree.
///
/// The ledger is `ledger_tasks` (keyed by local task id) and `ledger_lists`
/// (keyed by local list id); a key given twice keeps its first entry. Lists
/// and tasks the ledger no longer has a local side for are deleted in the
/// order the ledger lists them. A Google list the ledger does not map is left
/// alone unless a local list without a copy has exactly its title, in which
/// case it is adopted: the mirror owns the lists it made and nothing else.
#[uniffi::export]
pub fn google_tasks_plan(
    local_lists: Vec<GoogleTasksLocalList>,
    local_tasks: Vec<GoogleTasksLocalTask>,
    remote_lists: Vec<GoogleTasksRemoteList>,
    remote_tasks: Vec<GoogleTasksRemoteTask>,
    ledger_tasks: Vec<GoogleTasksLedgerEntry>,
    ledger_lists: Vec<GoogleTasksListMapping>,
) -> GoogleTasksPlan {
    let mut operations = Vec::new();
    let mut conflicts = Vec::new();

    let remote_lists_by_id = first_by_key(&remote_lists, |list| &list.id);
    let local_lists_by_id = first_by_key(&local_lists, |list| &list.id);
    let ledger_lists = dedupe(ledger_lists, |mapping| mapping.local_list_id.clone());
    let ledger_tasks = dedupe(ledger_tasks, |entry| entry.local_id.clone());
    let ledger_list_by_local: HashMap<&str, &str> = ledger_lists
        .iter()
        .map(|mapping| {
            (
                mapping.local_list_id.as_str(),
                mapping.remote_list_id.as_str(),
            )
        })
        .collect();
    let ledger_by_local: HashMap<&str, &GoogleTasksLedgerEntry> = ledger_tasks
        .iter()
        .map(|entry| (entry.local_id.as_str(), entry))
        .collect();

    // --- Lists ---------------------------------------------------------------
    // A local list with no usable mapping first looks for an unmapped Google
    // list with exactly its title (case-sensitive, as the mirror pushes names
    // verbatim) and adopts it; only when there is none does it create one.
    // Adopted and created lists both wait a pass before their tasks are
    // planned: the executor reads tasks only from lists the ledger knew.
    let mut list_mapping: Vec<(&str, &str)> = Vec::new();
    let mut claimed: HashSet<&str> = ledger_lists
        .iter()
        .map(|mapping| mapping.remote_list_id.as_str())
        .collect();
    for list in &local_lists {
        if let Some(remote_list_id) = ledger_list_by_local.get(list.id.as_str())
            && let Some(remote) = remote_lists_by_id.get(remote_list_id)
        {
            list_mapping.push((list.id.as_str(), remote_list_id));
            if !swift_text::same(&remote.title, &list.name) {
                operations.push(GoogleTasksOperation::RenameList {
                    remote_list_id: (*remote_list_id).to_string(),
                    title: list.name.clone(),
                });
            }
            continue;
        }
        if let Some(found) = remote_lists.iter().find(|remote| {
            swift_text::same(&remote.title, &list.name) && !claimed.contains(remote.id.as_str())
        }) {
            claimed.insert(found.id.as_str());
            operations.push(GoogleTasksOperation::AdoptRemoteList {
                local_list_id: list.id.clone(),
                remote_list_id: found.id.clone(),
            });
            continue;
        }
        operations.push(GoogleTasksOperation::CreateList {
            local_list_id: list.id.clone(),
            title: list.name.clone(),
        });
    }
    // Mapped to a list Takt no longer has: the Google copy follows it.
    for mapping in &ledger_lists {
        if !local_lists_by_id.contains_key(mapping.local_list_id.as_str())
            && remote_lists_by_id.contains_key(mapping.remote_list_id.as_str())
        {
            operations.push(GoogleTasksOperation::DeleteList {
                remote_list_id: mapping.remote_list_id.clone(),
                local_list_id: mapping.local_list_id.clone(),
            });
        }
    }
    let remote_list_for: HashMap<&str, &str> = list_mapping.iter().copied().collect();

    // --- Tasks ---------------------------------------------------------------
    let remote_tasks_by_id = first_by_key(&remote_tasks, |task| &task.id);
    let local_tasks_by_id = first_by_key(&local_tasks, |task| &task.id);
    let parent_remote_ids = parent_mapping(&local_tasks, &local_tasks_by_id, &ledger_by_local);

    for task in &local_tasks {
        // A list with no Google copy yet waits for the pass after its creation.
        let Some(remote_list_id) = remote_list_for.get(task.list_id.as_str()) else {
            continue;
        };
        let parent_remote_id = parent_remote_ids.get(task.id.as_str()).cloned();

        let Some(entry) = ledger_by_local.get(task.id.as_str()) else {
            // Completed before it was ever mirrored: nothing to put on a phone.
            if !task.is_completed {
                operations.push(GoogleTasksOperation::CreateTask {
                    local_id: task.id.clone(),
                    remote_list_id: (*remote_list_id).to_string(),
                    payload: GoogleTasksPayload {
                        title: task.title.clone(),
                        notes: task.notes.clone(),
                        due: task.due.clone(),
                        is_completed: false,
                        parent_remote_id,
                    },
                });
            }
            continue;
        };

        let local = GoogleTasksPayload {
            title: task.title.clone(),
            notes: task.notes.clone(),
            due: task.due.clone(),
            is_completed: task.is_completed,
            parent_remote_id,
        };

        let remote = match remote_tasks_by_id.get(entry.remote_id.as_str()) {
            Some(remote) if !remote.is_deleted => *remote,
            _ => {
                // Deleted in Google while Takt still has it: it comes back, and
                // the deletion is recorded as overwritten.
                if !task.is_completed {
                    operations.push(GoogleTasksOperation::CreateTask {
                        local_id: task.id.clone(),
                        remote_list_id: (*remote_list_id).to_string(),
                        payload: local,
                    });
                    conflicts.push(GoogleTasksConflict {
                        local_id: task.id.clone(),
                        remote_id: entry.remote_id.clone(),
                        field: GoogleTasksConflictField::Existence,
                        local_value: task.title.clone(),
                        remote_value: "deleted in Google Tasks".to_string(),
                    });
                }
                continue;
            }
        };

        // Completion is not a disagreement: whoever ticked it off, it is done.
        if remote.is_completed && !task.is_completed && !entry.pushed_completed {
            operations.push(GoogleTasksOperation::CompleteLocalTask {
                local_id: task.id.clone(),
            });
            continue;
        }

        let mut wants_push = false;

        // Notes added in Google are an addition, as long as Takt has not
        // written anything of its own to disagree with.
        if !swift_text::same(&remote.notes, &entry.pushed_notes) {
            let local_unchanged = swift_text::same(&task.notes, &entry.pushed_notes);
            if local_unchanged && is_additive(&remote.notes, &entry.pushed_notes) {
                operations.push(GoogleTasksOperation::MergeNotesIntoLocalTask {
                    local_id: task.id.clone(),
                    notes: remote.notes.clone(),
                });
                continue;
            }
            conflicts.push(conflict(
                task,
                remote,
                GoogleTasksConflictField::Notes,
                &task.notes,
                &remote.notes,
            ));
            wants_push = true;
        }

        if !swift_text::same(&remote.title, &entry.pushed_title) {
            conflicts.push(conflict(
                task,
                remote,
                GoogleTasksConflictField::Title,
                &task.title,
                &remote.title,
            ));
            wants_push = true;
        }

        if !swift_text::same_optional(remote.due.as_deref(), entry.pushed_due.as_deref()) {
            conflicts.push(conflict(
                task,
                remote,
                GoogleTasksConflictField::Due,
                task.due.as_deref().unwrap_or("none"),
                remote.due.as_deref().unwrap_or("none"),
            ));
            wants_push = true;
        }

        // Takt moved, or the remote copy drifted from what Takt believes it
        // pushed: either way the same write puts it right.
        let local_moved = !swift_text::same(&local.title, &entry.pushed_title)
            || !swift_text::same(&local.notes, &entry.pushed_notes)
            || !swift_text::same_optional(local.due.as_deref(), entry.pushed_due.as_deref())
            || local.is_completed != entry.pushed_completed;
        let remote_drifted = !swift_text::same(&remote.title, &local.title)
            || !swift_text::same(&remote.notes, &local.notes)
            || !swift_text::same_optional(remote.due.as_deref(), local.due.as_deref());
        if wants_push || local_moved || remote_drifted {
            operations.push(GoogleTasksOperation::UpdateTask {
                local_id: task.id.clone(),
                remote_id: remote.id.clone(),
                remote_list_id: entry.remote_list_id.clone(),
                payload: local,
            });
        }
    }

    // Mirrored once, gone from Takt now: delete the Google copy.
    for entry in &ledger_tasks {
        if local_tasks_by_id.contains_key(entry.local_id.as_str()) {
            continue;
        }
        if let Some(remote) = remote_tasks_by_id.get(entry.remote_id.as_str())
            && !remote.is_deleted
        {
            operations.push(GoogleTasksOperation::DeleteTask {
                remote_id: entry.remote_id.clone(),
                remote_list_id: entry.remote_list_id.clone(),
                local_id: entry.local_id.clone(),
            });
        }
    }

    // Typed into Google directly: adopted rather than deleted, because
    // authority decides who wins an argument, not who may write. A blank
    // title is skipped: Google allows one while a row is being typed, Takt
    // does not, and a placeholder would be pushed back as a title conflict.
    // It is adopted on the pass after it gets a name.
    let mirrored: HashSet<&str> = ledger_tasks
        .iter()
        .map(|entry| entry.remote_id.as_str())
        .collect();
    let mut local_list_for_remote: HashMap<&str, &str> = HashMap::new();
    for (local_list_id, remote_list_id) in &list_mapping {
        local_list_for_remote
            .entry(remote_list_id)
            .or_insert(local_list_id);
    }
    for remote in &remote_tasks {
        if remote.is_deleted
            || remote.is_completed
            || mirrored.contains(remote.id.as_str())
            || swift_text::trim(&remote.title).is_empty()
        {
            continue;
        }
        let Some(local_list_id) = local_list_for_remote.get(remote.list_id.as_str()) else {
            continue;
        };
        operations.push(GoogleTasksOperation::AdoptRemoteTask {
            remote_id: remote.id.clone(),
            remote_list_id: remote.list_id.clone(),
            local_list_id: (*local_list_id).to_string(),
            payload: GoogleTasksPayload {
                title: remote.title.clone(),
                notes: remote.notes.clone(),
                due: remote.due.clone(),
                is_completed: false,
                parent_remote_id: None,
            },
        });
    }

    GoogleTasksPlan {
        operations,
        conflicts,
    }
}

fn conflict(
    task: &GoogleTasksLocalTask,
    remote: &GoogleTasksRemoteTask,
    field: GoogleTasksConflictField,
    local_value: &str,
    remote_value: &str,
) -> GoogleTasksConflict {
    GoogleTasksConflict {
        local_id: task.id.clone(),
        remote_id: remote.id.clone(),
        field,
        local_value: local_value.to_string(),
        remote_value: remote_value.to_string(),
    }
}

/// Google Tasks nests exactly one level. A task whose parent is itself a
/// child is mirrored at the top level rather than vanishing into a nesting
/// Google would refuse.
fn parent_mapping<'a>(
    local_tasks: &'a [GoogleTasksLocalTask],
    by_id: &HashMap<&str, &'a GoogleTasksLocalTask>,
    ledger: &HashMap<&str, &GoogleTasksLedgerEntry>,
) -> HashMap<&'a str, String> {
    let mut mapping = HashMap::new();
    for task in local_tasks {
        let Some(parent_id) = task.parent_id.as_deref() else {
            continue;
        };
        let Some(parent) = by_id.get(parent_id) else {
            continue;
        };
        // A grandchild: its parent already occupies the one level allowed.
        if let Some(grandparent) = parent.parent_id.as_deref()
            && by_id.contains_key(grandparent)
        {
            continue;
        }
        if parent.list_id != task.list_id {
            continue;
        }
        if let Some(entry) = ledger.get(parent_id) {
            mapping.insert(task.id.as_str(), entry.remote_id.clone());
        }
    }
    mapping
}

/// Whether one text only adds to another: same start, more after it. Anything
/// else is a rewrite, and a rewrite is a disagreement.
pub(crate) fn is_additive(candidate: &str, original: &str) -> bool {
    if swift_text::trim(original).is_empty() {
        return !swift_text::trim(candidate).is_empty();
    }
    swift_text::has_prefix(candidate, original)
        && swift_text::character_count(candidate) > swift_text::character_count(original)
}

fn first_by_key<'a, T>(
    items: &'a [T],
    key: impl Fn(&'a T) -> &'a String,
) -> HashMap<&'a str, &'a T> {
    let mut map = HashMap::new();
    for item in items {
        map.entry(key(item).as_str()).or_insert(item);
    }
    map
}

fn dedupe<T>(items: Vec<T>, key: impl Fn(&T) -> String) -> Vec<T> {
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|item| seen.insert(key(item)))
        .collect()
}

#[cfg(test)]
mod tests;
