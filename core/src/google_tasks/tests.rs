//! Ported from `corelogic-tests/GoogleTasksMirrorTests.swift`. The due-date
//! formatting tests stay in Swift with the calendar code they test.

use super::*;
use GoogleTasksOperation as Op;

fn list(id: &str, name: &str) -> GoogleTasksLocalList {
    GoogleTasksLocalList {
        id: id.into(),
        name: name.into(),
    }
}

fn remote_list(id: &str, title: &str) -> GoogleTasksRemoteList {
    GoogleTasksRemoteList {
        id: id.into(),
        title: title.into(),
    }
}

fn task(id: &str, list: &str, title: &str) -> GoogleTasksLocalTask {
    GoogleTasksLocalTask {
        id: id.into(),
        list_id: list.into(),
        parent_id: None,
        title: title.into(),
        notes: String::new(),
        due: None,
        is_completed: false,
    }
}

fn remote(id: &str, list: &str, title: &str) -> GoogleTasksRemoteTask {
    GoogleTasksRemoteTask {
        id: id.into(),
        list_id: list.into(),
        parent_id: None,
        title: title.into(),
        notes: String::new(),
        due: None,
        is_completed: false,
        is_deleted: false,
    }
}

fn mapping(local: &str, remote: &str) -> GoogleTasksListMapping {
    GoogleTasksListMapping {
        local_list_id: local.into(),
        remote_list_id: remote.into(),
    }
}

fn entry(local_id: &str, remote_id: &str, title: &str) -> GoogleTasksLedgerEntry {
    GoogleTasksLedgerEntry {
        local_id: local_id.into(),
        remote_id: remote_id.into(),
        remote_list_id: "g-work".into(),
        pushed_title: title.into(),
        pushed_notes: String::new(),
        pushed_due: None,
        pushed_completed: false,
    }
}

fn payload(title: &str, notes: &str, completed: bool) -> GoogleTasksPayload {
    GoogleTasksPayload {
        title: title.into(),
        notes: notes.into(),
        due: None,
        is_completed: completed,
        parent_remote_id: None,
    }
}

struct Sides {
    local_lists: Vec<GoogleTasksLocalList>,
    local_tasks: Vec<GoogleTasksLocalTask>,
    remote_lists: Vec<GoogleTasksRemoteList>,
    remote_tasks: Vec<GoogleTasksRemoteTask>,
    ledger_tasks: Vec<GoogleTasksLedgerEntry>,
    ledger_lists: Vec<GoogleTasksListMapping>,
}

impl Sides {
    fn new(local_lists: Vec<GoogleTasksLocalList>) -> Self {
        Self {
            local_lists,
            local_tasks: vec![],
            remote_lists: vec![],
            remote_tasks: vec![],
            ledger_tasks: vec![],
            ledger_lists: vec![],
        }
    }

    /// One "Work" list on both sides, mapped, as most tests start.
    fn work() -> Self {
        let mut sides = Self::new(vec![list("work", "Work")]);
        sides.remote_lists = vec![remote_list("g-work", "Work")];
        sides.ledger_lists = vec![mapping("work", "g-work")];
        sides
    }

    fn plan(self) -> GoogleTasksPlan {
        google_tasks_plan(
            self.local_lists,
            self.local_tasks,
            self.remote_lists,
            self.remote_tasks,
            self.ledger_tasks,
            self.ledger_lists,
        )
    }
}

fn fields(plan: &GoogleTasksPlan) -> Vec<GoogleTasksConflictField> {
    plan.conflicts
        .iter()
        .map(|conflict| conflict.field)
        .collect()
}

// -- Lists --------------------------------------------------------------------

#[test]
fn a_list_with_no_google_copy_is_created() {
    let plan = Sides::new(vec![list("work", "Work")]).plan();
    assert_eq!(
        plan.operations,
        vec![Op::CreateList {
            local_list_id: "work".into(),
            title: "Work".into()
        }]
    );
}

#[test]
fn renaming_locally_renames_the_google_list() {
    let mut sides = Sides::work();
    sides.local_lists = vec![list("work", "Client work")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::RenameList {
            remote_list_id: "g-work".into(),
            title: "Client work".into()
        }]
    );
}

#[test]
fn archiving_a_list_locally_deletes_the_google_list() {
    let mut sides = Sides::work();
    sides.local_lists = vec![];
    assert_eq!(
        sides.plan().operations,
        vec![Op::DeleteList {
            remote_list_id: "g-work".into(),
            local_list_id: "work".into()
        }]
    );
}

#[test]
fn an_unmapped_google_list_is_never_touched() {
    let mut sides = Sides::new(vec![]);
    sides.remote_lists = vec![remote_list("g-personal", "Shopping")];
    sides.remote_tasks = vec![remote("g-1", "g-personal", "Milk")];
    assert_eq!(sides.plan(), GoogleTasksPlan::default());
}

#[test]
fn an_unmapped_list_is_adopted_by_exact_title_before_being_created() {
    let mut sides = Sides::new(vec![list("work", "Work")]);
    sides.remote_lists = vec![remote_list("g-work", "Work")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::AdoptRemoteList {
            local_list_id: "work".into(),
            remote_list_id: "g-work".into()
        }]
    );
}

#[test]
fn an_unmapped_list_still_creates_when_no_google_list_shares_its_title() {
    let mut sides = Sides::new(vec![list("work", "Work")]);
    sides.remote_lists = vec![
        remote_list("g-personal", "Shopping"),
        remote_list("g-w", "work"),
    ];
    assert_eq!(
        sides.plan().operations,
        vec![Op::CreateList {
            local_list_id: "work".into(),
            title: "Work".into()
        }]
    );
}

#[test]
fn a_mapped_google_list_is_not_adopted_by_a_second_local_list_with_the_same_title() {
    let mut sides = Sides::work();
    sides.local_lists = vec![list("work", "Work"), list("work-2", "Work")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::CreateList {
            local_list_id: "work-2".into(),
            title: "Work".into()
        }]
    );
}

#[test]
fn one_google_list_is_adopted_once() {
    let mut sides = Sides::new(vec![list("work", "Work"), list("work-2", "Work")]);
    sides.remote_lists = vec![remote_list("g-work", "Work")];
    assert_eq!(
        sides.plan().operations,
        vec![
            Op::AdoptRemoteList {
                local_list_id: "work".into(),
                remote_list_id: "g-work".into()
            },
            Op::CreateList {
                local_list_id: "work-2".into(),
                title: "Work".into()
            },
        ]
    );
}

#[test]
fn a_list_whose_google_copy_was_deleted_adopts_another_with_its_title() {
    let mut sides = Sides::new(vec![list("work", "Work")]);
    sides.remote_lists = vec![remote_list("g-work-2", "Work")];
    sides.ledger_lists = vec![mapping("work", "g-work-old")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::AdoptRemoteList {
            local_list_id: "work".into(),
            remote_list_id: "g-work-2".into()
        }]
    );
}

#[test]
fn tasks_in_an_adopted_list_wait_for_the_next_pass() {
    let mut sides = Sides::new(vec![list("work", "Work")]);
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    sides.remote_lists = vec![remote_list("g-work", "Work")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::AdoptRemoteList {
            local_list_id: "work".into(),
            remote_list_id: "g-work".into()
        }]
    );
}

// -- Pushing local state out --------------------------------------------------

#[test]
fn a_new_local_task_is_created_remotely() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::CreateTask {
            local_id: "t1".into(),
            remote_list_id: "g-work".into(),
            payload: payload("Write the brief", "", false)
        }]
    );
}

#[test]
fn a_task_completed_before_it_was_ever_mirrored_is_not_pushed() {
    let mut sides = Sides::work();
    let mut done = task("t1", "work", "Done already");
    done.is_completed = true;
    sides.local_tasks = vec![done];
    assert_eq!(sides.plan(), GoogleTasksPlan::default());
}

#[test]
fn completing_locally_pushes_the_completion() {
    let mut sides = Sides::work();
    let mut done = task("t1", "work", "Write the brief");
    done.is_completed = true;
    sides.local_tasks = vec![done];
    sides.remote_tasks = vec![remote("g-1", "g-work", "Write the brief")];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::UpdateTask {
            local_id: "t1".into(),
            remote_id: "g-1".into(),
            remote_list_id: "g-work".into(),
            payload: payload("Write the brief", "", true)
        }]
    );
    assert!(plan.conflicts.is_empty());
}

#[test]
fn deleting_locally_deletes_the_google_copy() {
    let mut sides = Sides::work();
    sides.remote_tasks = vec![remote("g-1", "g-work", "Write the brief")];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::DeleteTask {
            remote_id: "g-1".into(),
            remote_list_id: "g-work".into(),
            local_id: "t1".into()
        }]
    );
}

#[test]
fn an_unchanged_task_produces_nothing() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    sides.remote_tasks = vec![remote("g-1", "g-work", "Write the brief")];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    assert_eq!(sides.plan(), GoogleTasksPlan::default());
}

// -- Authority ----------------------------------------------------------------

#[test]
fn a_remote_title_edit_is_reverted_and_logged() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    sides.remote_tasks = vec![remote("g-1", "g-work", "write brief (phone edit)")];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::UpdateTask {
            local_id: "t1".into(),
            remote_id: "g-1".into(),
            remote_list_id: "g-work".into(),
            payload: payload("Write the brief", "", false)
        }]
    );
    assert_eq!(
        plan.conflicts,
        vec![GoogleTasksConflict {
            local_id: "t1".into(),
            remote_id: "g-1".into(),
            field: GoogleTasksConflictField::Title,
            local_value: "Write the brief".into(),
            remote_value: "write brief (phone edit)".into(),
        }]
    );
}

#[test]
fn ticking_off_in_google_completes_the_local_task() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    let mut ticked = remote("g-1", "g-work", "Write the brief");
    ticked.is_completed = true;
    sides.remote_tasks = vec![ticked];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::CompleteLocalTask {
            local_id: "t1".into()
        }]
    );
    assert!(plan.conflicts.is_empty());
}

#[test]
fn notes_added_in_google_are_merged_back_in() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    let mut noted = remote("g-1", "g-work", "Write the brief");
    noted.notes = "Ask about the budget".into();
    sides.remote_tasks = vec![noted];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::MergeNotesIntoLocalTask {
            local_id: "t1".into(),
            notes: "Ask about the budget".into()
        }]
    );
    assert!(plan.conflicts.is_empty());
}

#[test]
fn notes_appended_in_google_are_merged_back_in() {
    let mut sides = Sides::work();
    let mut local = task("t1", "work", "Brief");
    local.notes = "Due Friday".into();
    sides.local_tasks = vec![local];
    let mut noted = remote("g-1", "g-work", "Brief");
    noted.notes = "Due Friday\nAsk about budget".into();
    sides.remote_tasks = vec![noted];
    let mut pushed = entry("t1", "g-1", "Brief");
    pushed.pushed_notes = "Due Friday".into();
    sides.ledger_tasks = vec![pushed];
    assert_eq!(
        sides.plan().operations,
        vec![Op::MergeNotesIntoLocalTask {
            local_id: "t1".into(),
            notes: "Due Friday\nAsk about budget".into()
        }]
    );
}

#[test]
fn rewritten_notes_are_a_conflict_rather_than_a_merge() {
    let mut sides = Sides::work();
    let mut local = task("t1", "work", "Brief");
    local.notes = "Due Friday".into();
    sides.local_tasks = vec![local];
    let mut noted = remote("g-1", "g-work", "Brief");
    noted.notes = "whenever".into();
    sides.remote_tasks = vec![noted];
    let mut pushed = entry("t1", "g-1", "Brief");
    pushed.pushed_notes = "Due Friday".into();
    sides.ledger_tasks = vec![pushed];
    let plan = sides.plan();
    assert_eq!(fields(&plan), vec![GoogleTasksConflictField::Notes]);
    assert_eq!(
        plan.operations,
        vec![Op::UpdateTask {
            local_id: "t1".into(),
            remote_id: "g-1".into(),
            remote_list_id: "g-work".into(),
            payload: payload("Brief", "Due Friday", false)
        }]
    );
}

#[test]
fn notes_added_on_both_sides_resolve_to_local_and_are_logged() {
    let mut sides = Sides::work();
    let mut local = task("t1", "work", "Brief");
    local.notes = "Local addition".into();
    sides.local_tasks = vec![local];
    let mut noted = remote("g-1", "g-work", "Brief");
    noted.notes = "Remote addition".into();
    sides.remote_tasks = vec![noted];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Brief")];
    let plan = sides.plan();
    assert_eq!(fields(&plan), vec![GoogleTasksConflictField::Notes]);
    assert_eq!(plan.conflicts[0].local_value, "Local addition");
}

#[test]
fn deleting_in_google_brings_the_task_back_and_logs_it() {
    let mut sides = Sides::work();
    sides.local_tasks = vec![task("t1", "work", "Write the brief")];
    let mut gone = remote("g-1", "g-work", "Write the brief");
    gone.is_deleted = true;
    sides.remote_tasks = vec![gone];
    sides.ledger_tasks = vec![entry("t1", "g-1", "Write the brief")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::CreateTask {
            local_id: "t1".into(),
            remote_list_id: "g-work".into(),
            payload: payload("Write the brief", "", false)
        }]
    );
    assert_eq!(fields(&plan), vec![GoogleTasksConflictField::Existence]);
}

#[test]
fn a_completed_task_deleted_in_google_stays_deleted() {
    let mut sides = Sides::work();
    let mut done = task("t1", "work", "Write the brief");
    done.is_completed = true;
    sides.local_tasks = vec![done];
    let mut gone = remote("g-1", "g-work", "Write the brief");
    gone.is_deleted = true;
    sides.remote_tasks = vec![gone];
    let mut pushed = entry("t1", "g-1", "Write the brief");
    pushed.pushed_completed = true;
    sides.ledger_tasks = vec![pushed];
    assert_eq!(sides.plan(), GoogleTasksPlan::default());
}

#[test]
fn a_task_typed_into_google_is_adopted_into_the_mirrored_list() {
    let mut sides = Sides::work();
    sides.remote_tasks = vec![remote("g-9", "g-work", "Called from the train")];
    assert_eq!(
        sides.plan().operations,
        vec![Op::AdoptRemoteTask {
            remote_id: "g-9".into(),
            remote_list_id: "g-work".into(),
            local_list_id: "work".into(),
            payload: payload("Called from the train", "", false)
        }]
    );
}

#[test]
fn a_blank_titled_remote_task_is_not_adopted() {
    let mut sides = Sides::work();
    sides.remote_tasks = vec![
        remote("g-blank", "g-work", ""),
        remote("g-spaces", "g-work", "  \n"),
        remote("g-9", "g-work", "Called from the train"),
    ];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::AdoptRemoteTask {
            remote_id: "g-9".into(),
            remote_list_id: "g-work".into(),
            local_list_id: "work".into(),
            payload: payload("Called from the train", "", false)
        }]
    );
    assert!(plan.conflicts.is_empty());
}

// -- Shape --------------------------------------------------------------------

#[test]
fn subtasks_nest_once_and_grandchildren_flatten() {
    let mut sides = Sides::work();
    let mut child = task("child", "work", "Step");
    child.parent_id = Some("parent".into());
    let mut grandchild = task("grandchild", "work", "Detail");
    grandchild.parent_id = Some("child".into());
    sides.local_tasks = vec![task("parent", "work", "Goal"), child, grandchild];
    sides.ledger_tasks = vec![entry("parent", "g-parent", "Goal"), {
        let mut step = entry("child", "g-child", "Step");
        step.remote_list_id = "g-work".into();
        step
    }];
    let mut remote_child = remote("g-child", "g-work", "Step");
    remote_child.parent_id = Some("g-parent".into());
    sides.remote_tasks = vec![remote("g-parent", "g-work", "Goal"), remote_child];

    let plan = sides.plan();
    let Some(Op::CreateTask { payload, .. }) = plan.operations.first() else {
        panic!(
            "expected the grandchild to be created, got {:?}",
            plan.operations
        );
    };
    assert_eq!(payload.parent_remote_id, None);
}

#[test]
fn a_child_of_a_mirrored_top_level_task_hangs_under_it() {
    let mut sides = Sides::work();
    let mut child = task("child", "work", "Step");
    child.parent_id = Some("parent".into());
    sides.local_tasks = vec![task("parent", "work", "Goal"), child];
    sides.remote_tasks = vec![remote("g-parent", "g-work", "Goal")];
    sides.ledger_tasks = vec![entry("parent", "g-parent", "Goal")];
    let plan = sides.plan();
    assert_eq!(
        plan.operations,
        vec![Op::CreateTask {
            local_id: "child".into(),
            remote_list_id: "g-work".into(),
            payload: GoogleTasksPayload {
                parent_remote_id: Some("g-parent".into()),
                ..payload("Step", "", false)
            }
        }]
    );
}

// -- Beyond the Swift suite ---------------------------------------------------

/// Google can hand notes back in another Unicode normal form. Swift compared
/// them as equal; so must the core, or every pass would push and log again.
#[test]
fn notes_in_another_normal_form_are_not_a_change() {
    let mut sides = Sides::work();
    let mut local = task("t1", "work", "Brief");
    local.notes = "caf\u{e9}".into();
    sides.local_tasks = vec![local];
    let mut noted = remote("g-1", "g-work", "Brief");
    noted.notes = "cafe\u{301}".into();
    sides.remote_tasks = vec![noted];
    let mut pushed = entry("t1", "g-1", "Brief");
    pushed.pushed_notes = "caf\u{e9}".into();
    sides.ledger_tasks = vec![pushed];
    assert_eq!(sides.plan(), GoogleTasksPlan::default());
}

#[test]
fn deletions_follow_the_ledgers_order() {
    let mut sides = Sides::work();
    sides.local_lists = vec![];
    sides.remote_lists = vec![remote_list("g-work", "Work"), remote_list("g-home", "Home")];
    sides.ledger_lists = vec![mapping("work", "g-work"), mapping("home", "g-home")];
    assert_eq!(
        sides.plan().operations,
        vec![
            Op::DeleteList {
                remote_list_id: "g-work".into(),
                local_list_id: "work".into()
            },
            Op::DeleteList {
                remote_list_id: "g-home".into(),
                local_list_id: "home".into()
            },
        ]
    );
}

#[test]
fn additive_means_the_same_start_and_more() {
    assert!(is_additive("Ask", ""));
    assert!(!is_additive("  ", ""));
    assert!(is_additive("Due Friday\nmore", "Due Friday"));
    assert!(!is_additive("Due Friday", "Due Friday"));
    assert!(!is_additive("Due Thursday", "Due Friday"));
    // A combining accent added to the last letter is a rewrite of it.
    assert!(!is_additive("cafe\u{301}", "cafe"));
}
