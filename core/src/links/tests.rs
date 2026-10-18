use rusqlite::Connection;

use super::*;
use crate::journal::{journalled, undo};
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";

fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt) VALUES
               ('l', 'w', 'Inbox', 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, title, sortOrder, createdAt, updatedAt) VALUES
               ('a', 'l', 'A', 0, '{T}', '{T}'),
               ('b', 'l', 'B', 1, '{T}', '{T}');"
        ))
        .unwrap();
    connection
}

fn d(url: &str) -> TaskLink {
    describe(url, None, None)
}

#[test]
fn drive_addresses_say_what_they_are() {
    let doc = d("https://docs.google.com/document/d/1AbC/edit");
    assert_eq!(
        (doc.kind, doc.title.as_str(), doc.icon.as_str()),
        (LinkKind::Drive, "Google Doc", "doc")
    );
    assert_eq!(
        d("https://docs.google.com/spreadsheets/d/1x/edit#gid=0").icon,
        "sheet"
    );
    assert_eq!(
        d("https://docs.google.com/presentation/d/1x/edit").icon,
        "slides"
    );
    let folder = d("https://drive.google.com/drive/u/0/folders/1F");
    assert!(folder.is_folder);
    assert_eq!(folder.title, "Drive folder");
    assert_eq!(d("https://drive.google.com/file/d/1x/view").icon, "file");
}

#[test]
fn a_stored_name_and_type_sharpen_a_drive_link() {
    let pdf = describe(
        "https://drive.google.com/file/d/1x/view",
        Some("Lease"),
        Some("application/pdf"),
    );
    assert_eq!(
        (pdf.title.as_str(), pdf.subtitle.as_str(), pdf.icon.as_str()),
        ("Lease", "PDF in Drive", "pdf")
    );
}

#[test]
fn obsidian_notes_and_folders_round_trip() {
    let note = obsidian_link_url("Life".into(), "Projects/Takt plan.md".into(), false);
    assert_eq!(
        note,
        "obsidian://open?vault=Life&file=Projects%2FTakt%20plan.md"
    );
    let described = d(&note);
    assert_eq!(
        (
            described.kind,
            described.title.as_str(),
            described.subtitle.as_str()
        ),
        (LinkKind::Obsidian, "Takt plan", "Life · Projects")
    );
    let folder = d(&obsidian_link_url(
        "Studies".into(),
        "/Year 2/".into(),
        true,
    ));
    assert!(folder.is_folder);
    assert_eq!(
        (folder.title.as_str(), folder.subtitle.as_str()),
        ("Year 2", "Studies")
    );
}

#[test]
fn web_links_read_their_host() {
    let link = d("https://www.example.com/");
    assert_eq!(
        (link.kind, link.title.as_str()),
        (LinkKind::Web, "example.com")
    );
    assert_eq!(
        d("https://example.com/papers/attention.pdf").title,
        "attention.pdf"
    );
}

#[test]
fn only_a_whole_address_is_a_link() {
    assert_eq!(
        link_from_text("  https://a.example/x \n".into()).as_deref(),
        Some("https://a.example/x")
    );
    assert!(link_from_text("obsidian://open?vault=Life".into()).is_some());
    assert!(link_from_text("see https://a.example".into()).is_none());
    assert!(link_from_text("ftp://a.example".into()).is_none());
    assert!(link_from_text("https://".into()).is_none());
}

#[test]
fn adding_naming_and_removing_links_is_undoable() {
    let mut connection = workspace();
    let url = "https://docs.google.com/spreadsheets/d/1x/edit";
    let added = journalled(&mut connection, "Add Link", |tx| {
        add_link(
            tx,
            "a",
            url,
            Some("Budget"),
            Some("application/vnd.google-apps.spreadsheet"),
            1_000,
        )
    })
    .unwrap();
    assert!(added);
    let again = journalled(&mut connection, "Add Link", |tx| {
        add_link(tx, "a", url, None, None, 2_000)
    })
    .unwrap();
    assert!(!again);
    let links = task_links(&connection, "a").unwrap();
    assert_eq!(links.len(), 1);
    assert_eq!(
        (links[0].title.as_str(), links[0].icon.as_str()),
        ("Budget", "sheet")
    );
    assert_eq!(linked_task_ids(&connection).unwrap(), vec!["a".to_string()]);

    let removed = journalled(&mut connection, "Remove Link", |tx| {
        remove_link(tx, "a", url, 3_000)
    })
    .unwrap();
    assert!(removed);
    assert!(task_links(&connection, "a").unwrap().is_empty());
    assert!(linked_task_ids(&connection).unwrap().is_empty());
    let details: Option<String> = connection
        .query_row(
            "SELECT linkDetailsJSON FROM task_metadata WHERE taskId = 'a'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(details, None);

    undo(&mut connection).unwrap();
    assert_eq!(task_links(&connection, "a").unwrap()[0].title, "Budget");
}

#[test]
fn links_the_editor_wrote_are_read_too() {
    let connection = workspace();
    connection
        .execute_batch(&format!(
            "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, updatedAt)
               VALUES ('b', '[]', '[\"https:\\/\\/a.example\"]', '{T}');"
        ))
        .unwrap();
    let links = task_links(&connection, "b").unwrap();
    assert_eq!(links[0].url, "https://a.example");
    assert!(task_links(&connection, "a").unwrap().is_empty());
}

#[test]
fn a_missing_task_is_an_error() {
    let mut connection = workspace();
    let result = journalled(&mut connection, "Add Link", |tx| {
        add_link(tx, "nope", "https://a.example", None, None, 1)
    });
    assert!(matches!(result, Err(CoreError::MissingTask { .. })));
}
