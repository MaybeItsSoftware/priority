//! How far one task has got: its subtasks and the time logged against it.
//!
//! The iPhone's inspector (`TaskProgress.load`) read every task in the
//! task's list to walk its branch, and every block of the task to add them
//! up; Android's inspector read the blocks with SQL of its own. Both now ask
//! here and only four numbers cross.

use rusqlite::{Connection, OptionalExtension};

use crate::CoreError;
use crate::workspace::CoreWorkspace;

/// A task's subtasks and logged work.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct TaskWorkFacts {
    /// Every task below it in its list, at any depth.
    pub subtasks: u32,
    /// Those of them no longer open: completed or cancelled.
    pub subtasks_done: u32,
    /// Seconds of work logged against it, across renames (`originalTaskId`).
    pub logged_seconds: i64,
    pub work_blocks: u32,
}

/// The facts for `task_id`; all zero for a task that is not there.
pub fn task_work_facts(connection: &Connection, task_id: &str) -> Result<TaskWorkFacts, CoreError> {
    let Some(list_id) = connection
        .query_row("SELECT listId FROM tasks WHERE id = ?1", [task_id], |row| {
            row.get::<_, String>(0)
        })
        .optional()?
    else {
        return Ok(TaskWorkFacts::default());
    };
    // The branch is walked within the task's own list, as its outline is.
    let (subtasks, subtasks_done) = connection.query_row(
        "WITH RECURSIVE branch(id, status) AS (
             SELECT id, status FROM tasks WHERE parentTaskId = ?1 AND listId = ?2
             UNION
             SELECT tasks.id, tasks.status FROM tasks JOIN branch ON tasks.parentTaskId = branch.id
             WHERE tasks.listId = ?2
         )
         SELECT COUNT(*), COALESCE(SUM(status <> 'open'), 0) FROM branch",
        [task_id, list_id.as_str()],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
    )?;
    let (logged_seconds, work_blocks) = connection.query_row(
        "SELECT COALESCE(SUM(seconds), 0), COUNT(*) FROM focus_work_blocks
         WHERE taskId = ?1 OR originalTaskId = ?1",
        [task_id],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
    )?;
    Ok(TaskWorkFacts {
        subtasks: subtasks as u32,
        subtasks_done: subtasks_done as u32,
        logged_seconds,
        work_blocks: work_blocks as u32,
    })
}

#[uniffi::export]
impl CoreWorkspace {
    /// A task's subtasks and logged work, counted in the core.
    pub fn task_work_facts(&self, task_id: String) -> Result<TaskWorkFacts, CoreError> {
        task_work_facts(&self.read(), &task_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::migrate;

    fn seeded() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        migrate(&mut connection).unwrap();
        connection
            .execute_batch(
                "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'W', 0, 0);
                 INSERT INTO task_lists (id, workspaceId, name, sortOrder, createdAt, updatedAt)
                     VALUES ('l', 'w', 'L', 0, 0, 0), ('m', 'w', 'M', 1, 0, 0);
                 INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, createdAt, updatedAt) VALUES
                     ('p', 'l', NULL, 'Parent', 'open', 0, 0, 0),
                     ('c', 'l', 'p', 'Child', 'completed', 0, 0, 0),
                     ('g', 'l', 'c', 'Grandchild', 'open', 0, 0, 0),
                     ('x', 'l', 'p', 'Cancelled', 'cancelled', 1, 0, 0),
                     ('o', 'm', 'p', 'Elsewhere', 'open', 0, 0, 0),
                     ('s', 'l', NULL, 'Sibling', 'open', 1, 0, 0);
                 INSERT INTO focus_sessions (id, startedAt, phase, workDurationSeconds, breakDurationSeconds)
                     VALUES ('f', 0, 'finished', 1500, 300);
                 INSERT INTO focus_work_blocks (id, sessionId, taskId, taskTitle, seconds, recordedAt, originalTaskId) VALUES
                     ('b1', 'f', 'p', 'Parent', 600, 0, NULL),
                     ('b2', 'f', NULL, 'Parent (old)', 300, 0, 'p'),
                     ('b3', 'f', 's', 'Sibling', 900, 0, NULL);",
            )
            .unwrap();
        connection
    }

    #[test]
    fn counts_the_whole_branch_in_its_list_and_the_time_across_renames() {
        let connection = seeded();
        assert_eq!(
            task_work_facts(&connection, "p").unwrap(),
            TaskWorkFacts {
                subtasks: 3,
                subtasks_done: 2,
                logged_seconds: 900,
                work_blocks: 2,
            }
        );
        assert_eq!(
            task_work_facts(&connection, "g").unwrap(),
            TaskWorkFacts::default()
        );
        assert_eq!(
            task_work_facts(&connection, "missing").unwrap(),
            TaskWorkFacts::default()
        );
    }
}
