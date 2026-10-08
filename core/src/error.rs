//! The one error every call into the core can return.

/// What went wrong in the core, as a client sees it.
///
/// The field is `detail` rather than `message`: Kotlin's generated exception
/// would otherwise clash with `Throwable.message`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("The workspace database failed: {detail}")]
    Database { detail: String },
    #[error("Migration {identifier} left {count} broken foreign key(s); nothing was saved.")]
    ForeignKeys { identifier: String, count: u32 },
    #[error("The workspace has no undo journal to record into.")]
    NoJournal,
    #[error("No task with id {id}.")]
    MissingTask { id: String },
    #[error("No daily with id {id}.")]
    MissingDaily { id: String },
    #[error("No list with id {id}.")]
    MissingList { id: String },
    #[error("No folder with id {id}.")]
    MissingFolder { id: String },
    #[error("The Inbox cannot be archived or deleted. You can rename it instead.")]
    SystemListIsPermanent,
    #[error("A workspace item needs a name.")]
    EmptyName,
    #[error("A folder cannot go inside itself or one of its own folders.")]
    InvalidFolderMove,
    #[error("A required condition is missing, archived or belongs to another workspace.")]
    InvalidCondition,
    #[error("{status} is not a task status; use open, completed or cancelled.")]
    InvalidStatus { status: String },
    #[error("Start must be before the deadline.")]
    InvalidSchedule,
    #[error("Enter a minimum useful block of at least one minute.")]
    InvalidMinimum,
    #[error("One-sitting tasks need a positive estimate at least as long as their minimum block.")]
    EstimateRequired,
    #[error("Choose a valid calendar date.")]
    InvalidDate,
    #[error("This task changed while it was open. Review the latest version before saving.")]
    EditorConflict,
    #[error("A task cannot be moved into itself or one of its subtasks.")]
    InvalidTaskMove,
}

impl From<rusqlite::Error> for CoreError {
    fn from(error: rusqlite::Error) -> Self {
        CoreError::Database {
            detail: error.to_string(),
        }
    }
}
