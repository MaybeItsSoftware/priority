//! Takt's shared core.
//!
//! Every client — the Mac and iPhone apps through Swift, the Android app
//! through Kotlin, the CLI and the sync server as a Rust dependency — will call
//! this one implementation of the workspace store instead of keeping its own
//! copy. Nothing here knows about a UI toolkit. The migration is incremental;
//! `docs/rust-core-migration.md` is the plan and records which behaviour has
//! moved so far.

uniffi::setup_scaffolding!();

pub mod board;
pub mod conditions;
pub mod conversions;
pub mod dailies;
pub mod day_log;
pub mod editor;
pub mod error;
pub mod export;
pub mod focus;
pub mod habits;
pub mod imports;
pub mod journal;
pub mod lists;
pub mod next_up;
pub mod packed_rows;
pub mod periodic;
pub mod progress;
pub mod ranking;
pub mod reads;
pub mod records;
pub mod recurrence;
pub mod rows;
pub mod schema;
pub mod search;
pub mod setup;
pub mod sidebar;
pub mod sync;
pub mod tasks;
pub mod theme;
pub mod time;
pub mod today;
pub mod waiting;
pub mod workspace;

pub use error::CoreError;

/// The version of this crate, as compiled into the library a client loaded.
///
/// The first call across the boundary, and the one a client shows in its
/// diagnostics: when a platform's bindings and its compiled library drift
/// apart, this is the number that says which library it actually has.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_is_the_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
        assert!(!core_version().is_empty());
    }

    #[test]
    fn data_version_moves_for_other_connections_and_not_for_the_handles_own() {
        let path = std::env::temp_dir().join(format!(
            "takt-data-version-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path_text = path.to_string_lossy().to_string();
        schema::migrate_workspace(path_text.clone()).unwrap();
        let core = workspace::CoreWorkspace::open(path_text.clone()).unwrap();
        let start = core.data_version().unwrap();
        let workspace_id = core.bootstrap(1_000).unwrap();
        assert_eq!(core.data_version().unwrap(), start, "its own write");
        // The reading connection sees the handle's own commit straight away,
        // and reading through it moves nothing.
        let changes = core.own_changes().unwrap();
        let inbox = core.inbox(workspace_id.clone()).unwrap().unwrap();
        let task = core
            .create_task(
                tasks::NewTask {
                    list_id: inbox.id,
                    title: "Seen".into(),
                    parent_task_id: None,
                    kind: "task".into(),
                    notes: String::new(),
                    kanban_column: None,
                    start_at_ms: None,
                    due_at_ms: None,
                    estimate_seconds: None,
                    tags: vec![],
                    priority: None,
                    waiting_on: None,
                    external_links: vec![],
                    at_top: false,
                    adjacent_task_id: None,
                    above: false,
                },
                2_000,
            )
            .unwrap();
        assert_eq!(core.tasks_by_id(vec![task.clone()]).unwrap().len(), 1);
        let read = core
            .next_up(3_000, "UTC".into(), Default::default(), None, None)
            .unwrap();
        assert!(read.ranked.iter().any(|s| s.candidate.id == task));
        assert_eq!(core.data_version().unwrap(), start, "its own reads");
        let after_write = core.own_changes().unwrap();
        assert!(after_write > changes, "its own write is counted");
        assert_eq!(core.waiting_metadata().unwrap().len(), 0);
        assert_eq!(core.own_changes().unwrap(), after_write, "a read is not");
        let other = rusqlite::Connection::open(&path).unwrap();
        other
            .execute("UPDATE workspaces SET name = 'Elsewhere'", [])
            .unwrap();
        assert!(core.data_version().unwrap() > start, "someone else's write");
        let mode: String = other
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        drop(other);
        drop(core);
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{path_text}{suffix}"));
        }
    }
}
