use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt) VALUES
               ('l', 'w', 'Work', 0, 0, '{T}', '{T}'),
               ('old', 'w', 'Old', 1, 1, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, notes, status, sortOrder, createdAt, updatedAt) VALUES
               ('notes', 'l', 'Pay the bill', 'send the invoice by Friday', 'open', 0, '{T}', '{T}'),
               ('title', 'l', 'Invoice Acme', '', 'open', 1, '{T}', '{T}'),
               ('done', 'l', 'Invoice paid', '', 'completed', 2, '{T}', '{T}'),
               ('archived', 'old', 'Invoice archive', '', 'open', 0, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn ids(hits: &[SearchHit]) -> Vec<&str> {
    hits.iter().map(|hit| hit.task.id.as_str()).collect()
}

#[test]
fn prefixes_match_as_the_user_types_and_titles_outrank_notes() {
    let connection = workspace();
    let hits = search(&connection, "w", "inv", false, false, 60).unwrap();
    assert_eq!(ids(&hits), ["title", "notes"]);
    assert_eq!(hits[0].list.name, "Work");
    assert_eq!(hits[0].notes_snippet, None);
    assert_eq!(
        hits[1].notes_snippet.as_deref(),
        Some("send the invoice by Friday")
    );
}

#[test]
fn completed_tasks_and_archived_lists_join_only_when_asked() {
    let connection = workspace();
    let mut all = ids(&search(&connection, "w", "invoice", true, true, 60).unwrap())
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    all.sort();
    assert_eq!(all, ["archived", "done", "notes", "title"]);
    assert_eq!(
        search(&connection, "w", "invoice", false, false, 1)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn punctuation_and_query_syntax_are_not_errors() {
    let connection = workspace();
    for query in ["", "  ", "!!!", "\"", "OR", "NEAR(", "pay AND"] {
        assert!(
            search(&connection, "w", query, false, false, 60).is_ok(),
            "{query}"
        );
    }
    assert_eq!(
        prefix_pattern("Pay-the  BILL"),
        Some("\"pay\"* \"the\"* \"bill\"*".into())
    );
    assert_eq!(prefix_pattern("café"), Some("\"café\"*".into()));
    assert_eq!(prefix_pattern("..."), None);
}
