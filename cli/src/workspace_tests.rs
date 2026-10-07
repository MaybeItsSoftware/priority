//! The workspace write tools, against scratch databases built from the app's
//! real schema (`fixtures/workspace_schema.sql`, dumped from a migrated
//! database). The real schema matters here more than anywhere: the undo
//! journal and the search index are both maintained by its triggers, and a
//! hand-written fixture would test neither.

use crate::checkvist::{CheckvistClient, CheckvistConfig};
use crate::local::LocalState;
use crate::tools::Tools;
use crate::workspace::Workspace;
use rusqlite::{Connection, params};
use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

const SCHEMA: &str = include_str!("fixtures/workspace_schema.sql");
const WORKSPACE: &str = "4A4BAC28-0000-4000-8000-000000000001";
const INBOX: &str = "827DF788-0000-4000-8000-000000000002";
const FOLDER: &str = "E0E463F3-0000-4000-8000-000000000003";
const PROJECTS: &str = "9FE01505-0000-4000-8000-000000000004";
const EARLIER: &str = "2026-09-01 09:00:00.000";

static COUNTER: AtomicU32 = AtomicU32::new(0);

struct Fixture {
    path: PathBuf,
    tools: Tools,
}

impl Fixture {
    fn new() -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "priority-workspace-tests-{}-{unique}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("scratch directory");
        let path = directory.join("priority.sqlite");

        let connection = Connection::open(&path).expect("fixture database");
        // WAL, as the app's DatabasePool runs it, so the fixture exercises the
        // same journalling mode as the real file.
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .expect("wal");
        connection.execute_batch(SCHEMA).expect("schema");
        connection
            .execute_batch(&format!(
                "INSERT INTO workspaces VALUES ('{WORKSPACE}', 'My Workspace', '{EARLIER}', '{EARLIER}');
                 INSERT INTO list_folders VALUES ('{FOLDER}', '{WORKSPACE}', NULL, 'Computer Science', 0, '{EARLIER}', '{EARLIER}');
                 INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, createdAt, updatedAt, systemRole)
                   VALUES ('{INBOX}', '{WORKSPACE}', NULL, 'Inbox', NULL, 0, 0, '{EARLIER}', '{EARLIER}', 'inbox');
                 INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, createdAt, updatedAt)
                   VALUES ('{PROJECTS}', '{WORKSPACE}', NULL, 'Projects', '#7a4de8', 1, 0, '{EARLIER}', '{EARLIER}');"
            ))
            .expect("seed");
        drop(connection);

        let tools = Tools {
            client: CheckvistClient::new(CheckvistConfig {
                username: String::new(),
                remote_key: String::new(),
                default_list_id: "999".into(),
                base_url: "https://checkvist.invalid".into(),
            }),
            local: LocalState {
                prefs_path: directory.join("missing.plist"),
                store_directory: directory.clone(),
            },
            workspace: Workspace {
                database_path: path.clone(),
            },
        };
        Fixture { path, tools }
    }

    fn call(&self, name: &str, arguments: Value) -> Value {
        self.try_call(name, arguments)
            .unwrap_or_else(|error| panic!("{name} failed: {error}"))
    }

    fn try_call(&self, name: &str, arguments: Value) -> Result<Value, String> {
        let arguments: Map<String, Value> = arguments.as_object().cloned().unwrap_or_default();
        self.tools
            .call(name, &arguments)
            .map(|outcome| outcome.payload)
            .map_err(|error| error.message)
    }

    fn db(&self) -> Connection {
        Connection::open(&self.path).expect("reopen")
    }

    fn scalar<T: rusqlite::types::FromSql>(&self, sql: &str, id: &str) -> T {
        self.db()
            .query_row(sql, [id], |row| row.get(0))
            .unwrap_or_else(|error| panic!("{sql}: {error}"))
    }

    fn add(&self, list: &str, title: &str, parent: Option<&str>) -> String {
        let mut arguments = json!({ "list_id": list, "title": title });
        if let Some(parent) = parent {
            arguments["parent_task_id"] = json!(parent);
        }
        self.call("workspace_task_add", arguments)["id"]
            .as_str()
            .expect("id")
            .to_string()
    }

    fn order(&self, list: &str, parent: Option<&str>) -> Vec<String> {
        let connection = self.db();
        let mut statement = connection
            .prepare(
                "SELECT title FROM tasks WHERE listId = ?1 AND parentTaskId IS ?2 \
                 ORDER BY sortOrder, createdAt, id",
            )
            .unwrap();
        statement
            .query_map(params![list, parent], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<String>>>()
            .unwrap()
    }

    /// Undo groups, oldest first, as `(label, entry count)`.
    fn journal(&self) -> Vec<(String, i64)> {
        let connection = self.db();
        let mut statement = connection
            .prepare(
                "SELECT label, COUNT(*) FROM change_log WHERE undone = 0 \
                 GROUP BY groupId ORDER BY MAX(id)",
            )
            .unwrap();
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    }
}

// -- the rows a write leaves --------------------------------------------------

#[test]
fn a_new_task_has_the_shape_the_app_writes() {
    let fixture = Fixture::new();
    let id = fixture.add(PROJECTS, "  Write the report  ", None);

    // Foundation's `UUID().uuidString`: uppercase, hyphenated.
    assert_eq!(id.len(), 36);
    assert_eq!(id, id.to_uppercase());
    let (title, notes, status, order, kind, created, updated): (
        String,
        String,
        String,
        i64,
        String,
        String,
        String,
    ) = fixture
        .db()
        .query_row(
            "SELECT title, notes, status, sortOrder, itemKind, createdAt, updatedAt \
             FROM tasks WHERE id = ?1",
            [&id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(
        (title.as_str(), notes.as_str(), status.as_str()),
        ("Write the report", "", "open")
    );
    assert_eq!((order, kind.as_str()), (0, "task"));
    // GRDB's stored date format, milliseconds included: `2026-09-17 12:04:14.451`.
    assert_eq!(created.len(), 23, "{created}");
    assert_eq!(&created[10..11], " ");
    assert_eq!(&created[19..20], ".");
    assert_eq!(created, updated);

    // No metadata row until there is metadata, as `createTask` does.
    let metadata: i64 = fixture.scalar("SELECT COUNT(*) FROM task_metadata WHERE taskId = ?1", &id);
    assert_eq!(metadata, 0);

    // And the second one goes after it.
    fixture.add(PROJECTS, "Second", None);
    assert_eq!(
        fixture.order(PROJECTS, None),
        ["Write the report", "Second"]
    );
}

#[test]
fn notes_links_and_a_column_are_stored_where_the_app_reads_them() {
    let fixture = Fixture::new();
    let task = fixture.call(
        "workspace_task_add",
        json!({
            "list_id": PROJECTS,
            "title": "Read the paper",
            "notes": "Section 3 first.",
            "external_links": [
                " obsidian://open?vault=Studies&file=Paper ",
                "https://example.com/paper.pdf",
                "HTTPS://EXAMPLE.COM/paper.pdf",
                "",
            ],
            "kanban_column": "this-week",
        }),
    );
    let id = task["id"].as_str().unwrap();
    assert_eq!(task["notes"], json!("Section 3 first."));
    assert_eq!(task["kanban_column"], json!("this-week"));

    // Trimmed, blanks dropped, case-insensitive duplicates collapsed: the
    // editor's `normalizedStrings`.
    let links: String = fixture.scalar(
        "SELECT externalLinksJSON FROM task_metadata WHERE taskId = ?1",
        id,
    );
    assert_eq!(
        serde_json::from_str::<Value>(&links).unwrap(),
        json!([
            "obsidian://open?vault=Studies&file=Paper",
            "https://example.com/paper.pdf"
        ])
    );
    let tags: String = fixture.scalar("SELECT tagsJSON FROM task_metadata WHERE taskId = ?1", id);
    assert_eq!(tags, "[]");

    // Search finds it through the schema's own FTS triggers.
    let found: String = fixture.scalar(
        "SELECT t.id FROM tasks_fts f JOIN tasks t ON t.rowid = f.rowid WHERE tasks_fts MATCH ?1",
        "section",
    );
    assert_eq!(found, id);
}

#[test]
fn a_subtask_needs_only_its_parent() {
    let fixture = Fixture::new();
    let parent = fixture.add(PROJECTS, "Parent", None);
    let child = fixture.call(
        "workspace_task_add",
        json!({ "title": "Child", "parent_task_id": parent }),
    );
    assert_eq!(child["list_id"], json!(PROJECTS));
    assert_eq!(child["parent_task_id"], json!(parent));

    let wrong_list = fixture.try_call(
        "workspace_task_add",
        json!({ "title": "Stray", "list_id": INBOX, "parent_task_id": parent }),
    );
    assert!(
        wrong_list.unwrap_err().contains("not"),
        "a parent in another list is refused"
    );
}

#[test]
fn at_top_puts_a_task_first_and_renumbers_densely() {
    let fixture = Fixture::new();
    fixture.add(PROJECTS, "One", None);
    fixture.add(PROJECTS, "Two", None);
    fixture.call(
        "workspace_task_add",
        json!({ "list_id": PROJECTS, "title": "Zero", "at_top": true }),
    );
    assert_eq!(fixture.order(PROJECTS, None), ["Zero", "One", "Two"]);
    let orders: String = fixture
        .db()
        .query_row(
            "SELECT group_concat(sortOrder) FROM (SELECT sortOrder FROM tasks ORDER BY sortOrder)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(orders, "0,1,2");
}

// -- updates ------------------------------------------------------------------

#[test]
fn an_update_changes_only_what_it_names() {
    let fixture = Fixture::new();
    let id = fixture.call(
        "workspace_task_add",
        json!({ "list_id": PROJECTS, "title": "Draft", "notes": "keep me",
                "external_links": ["https://a.example"] }),
    )["id"]
        .as_str()
        .unwrap()
        .to_string();

    let updated = fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "title": "Final", "kanban_column": "today" }),
    );
    assert_eq!(updated["title"], json!("Final"));
    assert_eq!(updated["notes"], json!("keep me"));
    assert_eq!(updated["external_links"], json!(["https://a.example"]));
    assert_eq!(updated["kanban_column"], json!("today"));

    // Null clears the column; absence left it alone above.
    let cleared = fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "kanban_column": null }),
    );
    assert_eq!(cleared["kanban_column"], Value::Null);

    // An empty array removes every link.
    let unlinked = fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "external_links": [] }),
    );
    assert_eq!(unlinked["external_links"], json!([]));

    assert!(
        fixture
            .try_call("workspace_task_update", json!({ "task_id": id }))
            .unwrap_err()
            .contains("No updates")
    );
    assert!(
        fixture
            .try_call(
                "workspace_task_update",
                json!({ "task_id": id, "title": "   " })
            )
            .is_err()
    );
}

#[test]
fn completing_stamps_once_and_reopening_clears_the_stamp() {
    let fixture = Fixture::new();
    let id = fixture.add(PROJECTS, "Ship it", None);

    let done = fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "status": "completed" }),
    );
    assert_eq!(done["status"], json!("completed"));
    let stamped: String = fixture.scalar("SELECT completedAt FROM tasks WHERE id = ?1", &id);

    // Cancelling a completed task keeps its original completion time.
    fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "status": "cancelled" }),
    );
    let still: String = fixture.scalar("SELECT completedAt FROM tasks WHERE id = ?1", &id);
    assert_eq!(still, stamped);

    fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "status": "open" }),
    );
    let cleared: Option<String> =
        fixture.scalar("SELECT completedAt FROM tasks WHERE id = ?1", &id);
    assert_eq!(cleared, None);

    assert!(
        fixture
            .try_call(
                "workspace_task_update",
                json!({ "task_id": id, "status": "done" })
            )
            .is_err()
    );
}

#[test]
fn waiting_on_and_a_follow_up_file_the_task_in_waiting_on() {
    let fixture = Fixture::new();
    let task = fixture.add(PROJECTS, "Contract signed", None);
    fixture.call(
        "workspace_task_update",
        json!({ "task_id": task, "kanban_column": "today" }),
    );

    let updated = fixture.call(
        "workspace_task_update",
        json!({ "task_id": task, "waiting_on": "  Sam ", "follow_up_at": "2026-10-08 14:00" }),
    );
    assert_eq!(updated["waiting_on"], json!("Sam"));
    assert!(
        updated["follow_up_at"]
            .as_str()
            .is_some_and(|at| at.starts_with("2026-10-08 14:00"))
    );
    let column: Option<String> = fixture.scalar(
        "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
        &task,
    );
    assert_eq!(column.as_deref(), Some("waiting-on"));
    let stored: Option<String> = fixture.scalar(
        "SELECT waitingFollowUpAt FROM task_metadata WHERE taskId = ?1",
        &task,
    );
    assert!(stored.is_some_and(|at| at.ends_with(":00.000")));

    // Null clears the tag and leaves the time and the column.
    fixture.call(
        "workspace_task_update",
        json!({ "task_id": task, "waiting_on": null }),
    );
    let tag: Option<String> = fixture.scalar(
        "SELECT waitingOn FROM task_metadata WHERE taskId = ?1",
        &task,
    );
    assert_eq!(tag, None);

    let error = fixture
        .try_call(
            "workspace_task_update",
            json!({ "task_id": task, "follow_up_at": "soonish" }),
        )
        .unwrap_err();
    assert!(error.contains("2026-10-08 14:00"), "{error}");
}

#[test]
fn completing_a_source_task_ends_the_habits_made_from_it() {
    let fixture = Fixture::new();
    let source = fixture.add(PROJECTS, "Learn drums", None);
    let habit = fixture.add(PROJECTS, "Practise drums", None);
    let other = fixture.add(PROJECTS, "Stretch", None);
    let db = fixture.db();
    for (id, task, rule) in [("H1", &habit, "source"), ("H2", &other, "never")] {
        db.execute(
            "INSERT INTO dailies (id, taskId, sortOrder, createdAt, updatedAt, sourceTaskId, \
             placementColumn, expiryRule) VALUES (?1, ?2, 0, ?3, ?3, ?4, 'today', ?5)",
            params![id, task, EARLIER, source, rule],
        )
        .unwrap();
        db.execute(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, kanbanColumn, \
             updatedAt) VALUES (?1, '[]', '[]', 'today', ?2)",
            params![task, EARLIER],
        )
        .unwrap();
    }

    fixture.call(
        "workspace_task_update",
        json!({ "task_id": source, "status": "completed" }),
    );

    let archived: Option<String> =
        fixture.scalar("SELECT archivedAt FROM dailies WHERE id = ?1", "H1");
    assert!(archived.is_some());
    let column: Option<String> = fixture.scalar(
        "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?1",
        &habit,
    );
    assert_eq!(column, None);
    let kept: Option<String> = fixture.scalar("SELECT archivedAt FROM dailies WHERE id = ?1", "H2");
    assert_eq!(kept, None, "a habit that never expires outlives its source");
}

#[test]
fn a_repeating_task_is_left_for_the_app_to_complete() {
    let fixture = Fixture::new();
    let id = fixture.add(PROJECTS, "Water the plants", None);
    fixture
        .db()
        .execute(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, recurrenceRule, updatedAt) \
             VALUES (?1, '[]', '[]', 'every week', ?2)",
            params![id, EARLIER],
        )
        .unwrap();
    let error = fixture
        .try_call(
            "workspace_task_update",
            json!({ "task_id": id, "status": "completed" }),
        )
        .unwrap_err();
    assert!(error.contains("repeats"), "{error}");
    let status: String = fixture.scalar("SELECT status FROM tasks WHERE id = ?1", &id);
    assert_eq!(status, "open");
}

// -- moving -------------------------------------------------------------------

#[test]
fn reparenting_carries_the_subtree_and_refuses_a_cycle() {
    let fixture = Fixture::new();
    let parent = fixture.add(PROJECTS, "Parent", None);
    let child = fixture.add(PROJECTS, "Child", Some(&parent));
    let grandchild = fixture.add(PROJECTS, "Grandchild", Some(&child));

    // Into its own descendant: refused, and nothing changes.
    let error = fixture
        .try_call(
            "workspace_task_move",
            json!({ "task_id": parent, "parent_task_id": grandchild }),
        )
        .unwrap_err();
    assert!(error.contains("itself"), "{error}");

    // To another list's top level: the subtree follows.
    let moved = fixture.call(
        "workspace_task_move",
        json!({ "task_id": child, "list_id": INBOX }),
    );
    assert_eq!(moved["list_id"], json!(INBOX));
    assert_eq!(moved["parent_task_id"], Value::Null);
    let list: String = fixture.scalar("SELECT listId FROM tasks WHERE id = ?1", &grandchild);
    assert_eq!(list, INBOX);
    let parent_of: String =
        fixture.scalar("SELECT parentTaskId FROM tasks WHERE id = ?1", &grandchild);
    assert_eq!(parent_of, child);

    // Back under a parent in the first list.
    fixture.call(
        "workspace_task_move",
        json!({ "task_id": child, "parent_task_id": parent }),
    );
    let list: String = fixture.scalar("SELECT listId FROM tasks WHERE id = ?1", &grandchild);
    assert_eq!(list, PROJECTS);
}

#[test]
fn a_move_across_lists_journals_every_row_of_the_subtree() {
    // The subtree's listId is rewritten in one `UPDATE … WHERE id IN (…)`, as
    // the app does. The change_log triggers are per row, so the undo step
    // must still hold one entry per moved task plus the root's reparent.
    let fixture = Fixture::new();
    let root = fixture.add(PROJECTS, "Root", None);
    let child = fixture.add(PROJECTS, "Child", Some(&root));
    let grandchild = fixture.add(PROJECTS, "Grandchild", Some(&child));
    fixture.call(
        "workspace_task_move",
        json!({ "task_id": root, "list_id": INBOX }),
    );

    let (label, entries) = fixture.journal().pop().expect("an undo step");
    assert!(label.starts_with("MCP: "), "{label}");
    // Three listId rewrites, then the root's parent and order.
    assert_eq!(entries, 4);
    for id in [&root, &child, &grandchild] {
        let list: String = fixture.scalar("SELECT listId FROM tasks WHERE id = ?1", id);
        assert_eq!(list, INBOX);
        let rows: i64 = fixture.scalar(
            "SELECT COUNT(*) FROM change_log WHERE rowId = ?1 AND operation = 'update' \
             AND json_extract(afterJSON, '$.listId') = '827DF788-0000-4000-8000-000000000002'",
            id,
        );
        assert!(rows >= 1, "no journalled listId change for {id}");
    }
}

#[test]
fn position_reorders_among_siblings() {
    let fixture = Fixture::new();
    for title in ["A", "B", "C", "D"] {
        fixture.add(PROJECTS, title, None);
    }
    let d: String = fixture.scalar("SELECT id FROM tasks WHERE title = ?1", "D");
    fixture.call(
        "workspace_task_move",
        json!({ "task_id": d, "position": 2 }),
    );
    assert_eq!(fixture.order(PROJECTS, None), ["A", "D", "B", "C"]);

    // Past the end means last.
    let a: String = fixture.scalar("SELECT id FROM tasks WHERE title = ?1", "A");
    fixture.call(
        "workspace_task_move",
        json!({ "task_id": a, "position": 99 }),
    );
    assert_eq!(fixture.order(PROJECTS, None), ["D", "B", "C", "A"]);

    assert!(
        fixture
            .try_call(
                "workspace_task_move",
                json!({ "task_id": a, "position": 0 })
            )
            .is_err()
    );
}

#[test]
fn moving_to_a_list_lands_under_its_visible_root() {
    let fixture = Fixture::new();
    // An imported list whose one root task is a wrapper named after it.
    let wrapper = fixture.add(PROJECTS, "Projects", None);
    fixture.add(PROJECTS, "Inside", Some(&wrapper));
    fixture
        .db()
        .execute(
            "UPDATE task_lists SET visibleRootTaskId = ?1 WHERE id = ?2",
            params![wrapper, PROJECTS],
        )
        .unwrap();
    let stray = fixture.add(INBOX, "Stray", None);
    let moved = fixture.call(
        "workspace_task_move",
        json!({ "task_id": stray, "list_id": PROJECTS }),
    );
    assert_eq!(moved["parent_task_id"], json!(wrapper));
}

// -- promoting a task to its own list ----------------------------------------

#[test]
fn a_task_promoted_to_a_list_keeps_its_subtree_as_the_lists_contents() {
    let fixture = Fixture::new();
    let project = fixture.add(PROJECTS, "Get a first in ELEC0150", None);
    let week = fixture.add(PROJECTS, "Week 1", Some(&project));
    let reading = fixture.add(PROJECTS, "Reading", Some(&week));
    fixture.add(PROJECTS, "Unrelated", None);

    let result = fixture.call(
        "workspace_task_to_list",
        json!({ "task_id": project, "folder_id": FOLDER }),
    );
    let list = &result["list"];
    let list_id = list["id"].as_str().unwrap();
    assert_eq!(list["name"], json!("Get a first in ELEC0150"));
    assert_eq!(list["folder_id"], json!(FOLDER));
    // The task survives as the list's visible root: same id, now a list.
    assert_eq!(list["visible_root_task_id"], json!(project));
    assert_eq!(result["root_task"]["kind"], json!("list"));
    assert_eq!(result["root_task"]["parent_task_id"], Value::Null);
    assert_eq!(result["moved_task_count"], json!(3));

    // Subtasks moved with it and kept their shape.
    for id in [&week, &reading] {
        let moved_to: String = fixture.scalar("SELECT listId FROM tasks WHERE id = ?1", id);
        assert_eq!(moved_to, list_id);
    }
    let parent_of: String = fixture.scalar("SELECT parentTaskId FROM tasks WHERE id = ?1", &week);
    assert_eq!(parent_of, project);
    // The colour comes from the list it left, as in the app.
    let color: String = fixture.scalar("SELECT colorHex FROM task_lists WHERE id = ?1", list_id);
    assert_eq!(color, "#7a4de8");
    assert_eq!(fixture.order(PROJECTS, None), ["Unrelated"]);

    // One undo step for the whole thing.
    let journal = fixture.journal();
    assert_eq!(journal.last().unwrap().0, "MCP: Move Item to Folder");

    // The tree tool shows it in the folder, and its tasks without the wrapper
    // being mistaken for a nested list.
    let tree = fixture.call("workspace_tree", json!({}));
    assert!(
        tree["lists"]
            .as_array()
            .unwrap()
            .iter()
            .any(|list| list["id"] == json!(list_id) && list["folder_id"] == json!(FOLDER))
    );
    assert_eq!(tree["nested_lists"], json!([]));
}

#[test]
fn a_task_becomes_a_pinned_nested_list_in_place() {
    let fixture = Fixture::new();
    let parent = fixture.add(PROJECTS, "Reading list", None);
    fixture.add(PROJECTS, "Book", Some(&parent));

    // Pinning a plain task is refused: only a nested list has a sidebar row.
    assert!(
        fixture
            .try_call(
                "workspace_task_update",
                json!({ "task_id": parent, "pinned": true })
            )
            .unwrap_err()
            .contains("not a nested list")
    );

    let updated = fixture.call(
        "workspace_task_update",
        json!({ "task_id": parent, "kind": "list", "pinned": true }),
    );
    assert_eq!(updated["kind"], json!("list"));
    assert_eq!(updated["is_promoted"], json!(true));
    assert_eq!(updated["list_id"], json!(PROJECTS), "it stays where it was");

    let tree = fixture.call("workspace_tree", json!({}));
    assert_eq!(tree["nested_lists"][0]["id"], json!(parent));
    assert_eq!(tree["nested_lists"][0]["is_promoted"], json!(true));

    // Back to a task clears the pin, as `setItemKind` does.
    let task = fixture.call(
        "workspace_task_update",
        json!({ "task_id": parent, "kind": "task" }),
    );
    assert_eq!(task.get("is_promoted"), None);
    assert_eq!(fixture.journal().last().unwrap().0, "MCP: Convert to Task");
}

#[test]
fn a_lists_own_visible_root_cannot_be_promoted_out_of_it() {
    let fixture = Fixture::new();
    let wrapper = fixture.add(PROJECTS, "Projects", None);
    fixture
        .db()
        .execute(
            "UPDATE task_lists SET visibleRootTaskId = ?1 WHERE id = ?2",
            params![wrapper, PROJECTS],
        )
        .unwrap();
    let error = fixture
        .try_call("workspace_task_to_list", json!({ "task_id": wrapper }))
        .unwrap_err();
    assert!(error.contains("visible root"), "{error}");
}

// -- folders and lists --------------------------------------------------------

#[test]
fn folders_and_lists_append_and_move_like_the_sidebar() {
    let fixture = Fixture::new();
    let folder = fixture.call("workspace_folder_create", json!({ "name": "Studies" }));
    assert_eq!(folder["sort_order"], json!(1), "after Computer Science");
    let folder_id = folder["id"].as_str().unwrap();

    let list = fixture.call(
        "workspace_list_create",
        json!({ "name": "Revision", "folder_id": folder_id }),
    );
    assert_eq!(list["folder_id"], json!(folder_id));
    assert_eq!(list["sort_order"], json!(0));

    // Projects moves into Computer Science, then back out to the end of the
    // top level.
    let moved = fixture.call(
        "workspace_list_move",
        json!({ "list_id": PROJECTS, "folder_id": FOLDER }),
    );
    assert_eq!(moved["folder_id"], json!(FOLDER));
    let out = fixture.call("workspace_list_move", json!({ "list_id": PROJECTS }));
    assert_eq!(out["folder_id"], Value::Null);
    assert_eq!(out["sort_order"], json!(1), "after the Inbox");

    assert!(
        fixture
            .try_call(
                "workspace_list_move",
                json!({ "list_id": PROJECTS, "folder_id": "NOPE" })
            )
            .unwrap_err()
            .contains("No folder")
    );
}

#[test]
fn deleting_a_list_takes_its_tasks_and_spares_the_inbox() {
    let fixture = Fixture::new();
    fixture.add(PROJECTS, "Goes with it", None);
    let deleted = fixture.call("workspace_list_delete", json!({ "list_id": PROJECTS }));
    assert_eq!(deleted["tasks_deleted"], json!(1));
    assert!(
        fixture
            .try_call("workspace_tasks", json!({ "list_id": PROJECTS }))
            .unwrap_err()
            .contains("No list")
    );

    let inbox = fixture.call("workspace_tree", json!({}))["lists"]
        .as_array()
        .unwrap()
        .iter()
        .find(|list| list["system_role"] == json!("inbox"))
        .map(|list| list["id"].as_str().unwrap().to_string())
        .unwrap();
    assert!(
        fixture
            .try_call("workspace_list_delete", json!({ "list_id": inbox }))
            .unwrap_err()
            .contains("Inbox")
    );
}

#[test]
fn the_task_tree_nests_children_and_hides_closed_work() {
    let fixture = Fixture::new();
    let parent = fixture.add(PROJECTS, "Parent", None);
    fixture.add(PROJECTS, "Child", Some(&parent));
    let done = fixture.add(PROJECTS, "Done", None);
    fixture.call(
        "workspace_task_update",
        json!({ "task_id": done, "status": "completed" }),
    );

    let open = fixture.call("workspace_tasks", json!({ "list_id": PROJECTS }));
    assert_eq!(open["task_count"], json!(2));
    assert_eq!(open["tasks"][0]["children"][0]["title"], json!("Child"));

    let all = fixture.call(
        "workspace_tasks",
        json!({ "list_id": PROJECTS, "include_closed": true }),
    );
    assert_eq!(all["task_count"], json!(3));

    let subtree = fixture.call(
        "workspace_tasks",
        json!({ "list_id": PROJECTS, "parent_task_id": parent }),
    );
    assert_eq!(subtree["tasks"][0]["title"], json!("Child"));
}

// -- deleting -----------------------------------------------------------------

#[test]
fn deleting_takes_the_subtree_by_cascade() {
    let fixture = Fixture::new();
    let parent = fixture.add(PROJECTS, "Parent", None);
    fixture.add(PROJECTS, "Child", Some(&parent));
    let result = fixture.call("workspace_task_delete", json!({ "task_id": parent }));
    assert_eq!(result["subtasks_deleted"], json!(1));
    let left: i64 = fixture.scalar("SELECT COUNT(*) FROM tasks WHERE listId = ?1", PROJECTS);
    assert_eq!(left, 0, "foreign keys were on, so the child went too");
}

// -- the undo journal ---------------------------------------------------------

#[test]
fn each_write_is_one_labelled_undo_step() {
    let fixture = Fixture::new();
    let id = fixture.call(
        "workspace_task_add",
        json!({ "list_id": PROJECTS, "title": "Linked", "external_links": ["https://a.example"] }),
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "status": "completed" }),
    );
    fixture.call("workspace_folder_create", json!({ "name": "F" }));

    let journal = fixture.journal();
    assert_eq!(
        journal,
        vec![
            // The task row and its metadata row, together.
            ("MCP: New Task".to_string(), 2),
            ("MCP: Change Status".to_string(), 1),
            ("MCP: New Folder".to_string(), 1),
        ]
    );
    // Recording is switched off again afterwards, so the app's own
    // unjournalled writes are not swept into the last MCP step.
    let suppressed: i64 = fixture.scalar("SELECT suppressed FROM undo_control WHERE id = ?1", "0");
    assert_eq!(suppressed, 1);

    // The journal holds what replaying needs: the full row before and after.
    let after: String = fixture.scalar(
        "SELECT afterJSON FROM change_log WHERE label = 'MCP: Change Status' AND rowId = ?1",
        &id,
    );
    assert_eq!(
        serde_json::from_str::<Value>(&after).unwrap()["status"],
        json!("completed")
    );
}

#[test]
fn a_no_op_leaves_no_undo_step_and_keeps_redo() {
    let fixture = Fixture::new();
    let id = fixture.add(PROJECTS, "Same", None);
    // Something the app has undone, waiting to be redone.
    fixture
        .db()
        .execute(
            "INSERT INTO change_log (groupId, label, tableName, rowId, operation, undone) \
             VALUES ('G', 'Rename List', 'task_lists', ?1, 'update', 1)",
            [PROJECTS],
        )
        .unwrap();

    fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "title": "Same" }),
    );
    let redo: i64 = fixture.scalar("SELECT COUNT(*) FROM change_log WHERE undone = ?1", "1");
    assert_eq!(
        redo, 1,
        "a write that changed nothing does not discard redo"
    );

    fixture.call(
        "workspace_task_update",
        json!({ "task_id": id, "title": "Different" }),
    );
    let redo: i64 = fixture.scalar("SELECT COUNT(*) FROM change_log WHERE undone = ?1", "1");
    assert_eq!(redo, 0, "a real change starts a new branch of history");
}

#[test]
fn a_refused_write_leaves_nothing_behind() {
    let fixture = Fixture::new();
    let before = fixture.journal();
    assert!(
        fixture
            .try_call(
                "workspace_task_move",
                json!({ "task_id": "MISSING", "position": 1 })
            )
            .is_err()
    );
    assert_eq!(fixture.journal(), before);
    let suppressed: i64 = fixture.scalar("SELECT suppressed FROM undo_control WHERE id = ?1", "0");
    assert_eq!(suppressed, 1);
}

#[test]
fn an_unmigrated_database_is_refused_rather_than_written() {
    let fixture = Fixture::new();
    fixture
        .db()
        .execute(
            "DELETE FROM grdb_migrations WHERE identifier = 'v16_task_completion_time'",
            [],
        )
        .unwrap();
    let error = fixture
        .try_call(
            "workspace_task_add",
            json!({ "list_id": PROJECTS, "title": "x" }),
        )
        .unwrap_err();
    assert!(error.contains("predates"), "{error}");
}

#[test]
fn a_write_waits_out_another_writer_instead_of_failing() {
    let fixture = Fixture::new();
    let holder = fixture.db();
    holder.execute_batch("BEGIN IMMEDIATE").unwrap();
    let path = fixture.path.clone();
    let release = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(300));
        holder.execute_batch("COMMIT").unwrap();
        drop(path);
    });
    // Blocks on the lock for ~300ms, then succeeds.
    fixture.add(PROJECTS, "Patient", None);
    release.join().unwrap();
}

#[test]
fn reads_work_with_the_app_closed_and_still_cannot_write() {
    // A WAL database with no `-shm` beside it, which a strictly read-only
    // connection cannot create: what SQLite leaves when the app's last
    // connection closes cleanly, and what a `.backup` copy looks like. Built
    // deliberately, since whether SQLite removes the file on close varies.
    let fixture = Fixture::new();
    fixture.add(PROJECTS, "Visible", None);
    fixture
        .db()
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
        .unwrap();
    for suffix in ["sqlite-wal", "sqlite-shm"] {
        let _ = std::fs::remove_file(fixture.path.with_extension(suffix));
    }
    let strict =
        Connection::open_with_flags(&fixture.path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    assert!(
        strict
            .query_row("SELECT COUNT(*) FROM tasks", [], |row| row.get::<_, i64>(0))
            .is_err(),
        "the state this test is about: a strictly read-only open cannot read"
    );
    drop(strict);

    let tasks = fixture.call("workspace_tasks", json!({ "list_id": PROJECTS }));
    assert_eq!(tasks["tasks"][0]["title"], json!("Visible"));
    assert_eq!(
        fixture.call("focus_status", json!({}))["running"],
        json!(false)
    );

    // The fallback connection is still read-only.
    let connection = fixture.tools.workspace.open().expect("open");
    assert!(
        connection.execute("DELETE FROM tasks", []).is_err(),
        "query_only refuses writes"
    );
}

// -- the command line reaches the same tools ----------------------------------

#[test]
fn the_ws_subcommands_resolve_to_the_workspace_tools() {
    use crate::cli::{Cli, resolve};
    use clap::Parser;

    let resolved = |args: &[&str]| {
        let cli = Cli::try_parse_from(std::iter::once("priority").chain(args.iter().copied()))
            .unwrap_or_else(|error| panic!("{args:?}: {error}"));
        resolve(&cli).unwrap()
    };

    let (name, arguments) = resolved(&[
        "ws",
        "add",
        "Read",
        "the",
        "paper",
        "--parent",
        "P",
        "--link",
        "https://a",
        "--link",
        "obsidian://b",
        "-c",
        "today",
    ]);
    assert_eq!(name, "workspace_task_add");
    assert_eq!(arguments["title"], json!("Read the paper"));
    assert_eq!(arguments["parent_task_id"], json!("P"));
    assert_eq!(
        arguments["external_links"],
        json!(["https://a", "obsidian://b"])
    );
    assert_eq!(arguments["kanban_column"], json!("today"));

    let (name, arguments) = resolved(&["ws", "done", "T"]);
    assert_eq!(name, "workspace_task_update");
    assert_eq!(arguments["status"], json!("completed"));

    let (name, arguments) = resolved(&["ws", "update", "T", "--no-links"]);
    assert_eq!(name, "workspace_task_update");
    assert_eq!(arguments["external_links"], json!([]));

    // The global --list-id is Checkvist's, and must not leak in.
    let (name, arguments) = resolved(&["-l", "123", "ws", "to-list", "T", "-f", "F"]);
    assert_eq!(name, "workspace_task_to_list");
    assert_eq!(arguments.get("list_id"), None);
    assert_eq!(arguments["folder_id"], json!("F"));

    for (args, tool) in [
        (&["ws", "tree"][..], "workspace_tree"),
        (&["ws", "tasks", "L"][..], "workspace_tasks"),
        (
            &["ws", "move", "T", "--position", "2"][..],
            "workspace_task_move",
        ),
        (&["ws", "rm", "T"][..], "workspace_task_delete"),
        (&["ws", "new-folder", "F"][..], "workspace_folder_create"),
        (&["ws", "new-list", "L"][..], "workspace_list_create"),
        (&["ws", "move-list", "L"][..], "workspace_list_move"),
    ] {
        assert_eq!(resolved(args).0, tool, "{args:?}");
    }
}
