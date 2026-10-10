use rusqlite::Connection;

use super::*;
use crate::schema::migrate;

const T: &str = "2024-01-01 00:00:00.000";
/// 2024-01-01 00:00:00 UTC.
const T_MS: i64 = 1_704_067_200_000;

/// Two lists. In `l`: a project with a finished step that has an open
/// detail, a nested list with a task, an archived list and a finished list
/// each holding a task, and a task in another column. In `o`: a wrapper
/// that is the list's visible root, holding one task.
fn workspace() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    migrate(&mut connection).unwrap();
    connection
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES ('w', 'Mine', '{T}', '{T}');
             INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt) VALUES
               ('l', 'w', 'Work', 0, 0, '{T}', '{T}'),
               ('o', 'w', 'Home', 1, 0, '{T}', '{T}');
             INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, itemKind, archivedAt, completedAt, createdAt, updatedAt) VALUES
               ('project', 'l', NULL, 'Project', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('step', 'l', 'project', 'Step', 'completed', 0, 'task', NULL, '{T}', '{T}', '{T}'),
               ('detail', 'l', 'step', 'Detail', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('reading', 'l', NULL, 'Reading', 'open', 1, 'list', NULL, NULL, '{T}', '{T}'),
               ('paper', 'l', 'reading', 'Paper', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('old', 'l', NULL, 'Old', 'open', 2, 'list', '{T}', NULL, '{T}', '{T}'),
               ('stale', 'l', 'old', 'Stale', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('closed', 'l', NULL, 'Closed', 'completed', 3, 'list', NULL, NULL, '{T}', '{T}'),
               ('shut', 'l', 'closed', 'Shut', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('root', 'o', NULL, 'Wrapper', 'open', 0, 'task', NULL, NULL, '{T}', '{T}'),
               ('chore', 'o', 'root', 'Chore', 'open', 0, 'task', NULL, NULL, '{T}', '{T}');
             INSERT INTO task_metadata (taskId, kanbanColumn, matrixUrgency, matrixImportance, updatedAt) VALUES
               ('detail', 'doing', NULL, NULL, '{T}'),
               ('chore', NULL, 1, 0, '{T}');
             UPDATE task_lists SET visibleRootTaskId = 'root' WHERE id = 'o';"
        ))
        .unwrap();
    connection
}

/// A board with its packed rows unpacked; everything else as it crossed.
struct Decoded {
    read: BoardRead,
    rows: Vec<TaskRow>,
}

impl std::ops::Deref for Decoded {
    type Target = BoardRead;
    fn deref(&self) -> &BoardRead {
        &self.read
    }
}

fn combined_board(
    connection: &Connection,
    list_ids: &[String],
    hide_completed_before_ms: Option<i64>,
) -> Result<Decoded, CoreError> {
    let read = super::combined_board(connection, list_ids, hide_completed_before_ms)?;
    let rows = crate::packed_rows::unpack_task_rows(&read.rows).expect("rows unpack");
    Ok(Decoded { read, rows })
}

fn ids() -> Vec<String> {
    ["l", "o"].map(str::to_string).to_vec()
}

/// A node's id, whichever table it is in.
fn id(read: &Decoded, node: u32) -> &str {
    let node = node as usize;
    match read.rows.get(node) {
        Some(row) => &row.id,
        None => &read.other_ids[node - read.rows.len()],
    }
}

fn unpacked(bytes: &[u8]) -> Vec<u32> {
    bytes
        .chunks(4)
        .map(|chunk| u32::from_le_bytes(chunk.try_into().unwrap()))
        .collect()
}

fn cards(read: &Decoded) -> Vec<&str> {
    unpacked(&read.cards)
        .into_iter()
        .map(|node| id(read, node))
        .collect()
}

fn tree<'a>(read: &'a Decoded, key: &str) -> Option<Vec<(&'a str, u32)>> {
    let keys = unpacked(&read.tree_keys);
    let rows = unpacked(&read.tree_rows);
    let depths = unpacked(&read.tree_depths);
    let mut start = 0;
    for pair in keys.chunks(2) {
        let end = pair[1] as usize;
        if id(read, pair[0]) == key {
            return Some(
                (start..end)
                    .map(|i| (id(read, rows[i]), depths[i]))
                    .collect(),
            );
        }
        start = end;
    }
    None
}

fn parent<'a>(read: &'a Decoded, child: &str) -> Option<&'a str> {
    let parents = unpacked(&read.parents);
    let node = (0..parents.len() as u32).find(|&node| id(read, node) == child)?;
    let parent = parents[node as usize];
    (parent != u32::MAX).then(|| id(read, parent))
}

fn placement<'a>(read: &'a Decoded, task: &str) -> Option<&'a BoardPlacement> {
    read.placements
        .iter()
        .find(|placement| read.rows[placement.row as usize].id == task)
}

#[test]
fn cards_are_the_open_tasks_outside_closed_lists_and_the_visible_root() {
    let read = combined_board(&workspace(), &ids(), None).unwrap();
    assert_eq!(cards(&read), ["project", "detail", "paper", "chore"]);
}

#[test]
fn the_actionable_read_carries_the_cards_alone_in_board_order() {
    let connection = workspace();
    let rows =
        crate::packed_rows::unpack_task_rows(&actionable_tasks(&connection, &ids()).unwrap())
            .unwrap();
    let read = combined_board(&connection, &ids(), None).unwrap();
    let titles: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(titles, cards(&read));
    let reversed: Vec<String> = ids().into_iter().rev().collect();
    let rows =
        crate::packed_rows::unpack_task_rows(&actionable_tasks(&connection, &reversed).unwrap())
            .unwrap();
    assert_eq!(
        rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
        ["chore", "project", "detail", "paper"]
    );
    assert!(actionable_tasks(&connection, &[]).unwrap().len() <= 8);
}

#[test]
fn trees_keep_every_level_and_name_each_parent() {
    let read = combined_board(&workspace(), &ids(), None).unwrap();
    assert_eq!(
        tree(&read, "project").unwrap(),
        [("step", 0), ("detail", 1)]
    );
    assert_eq!(tree(&read, "step").unwrap(), [("detail", 0)]);
    assert_eq!(tree(&read, "detail").unwrap(), []);
    // Not inside a card: no tree of its own.
    assert_eq!(tree(&read, "reading"), None);
    assert_eq!(parent(&read, "detail"), Some("step"));
    assert_eq!(parent(&read, "paper"), Some("reading"));
    assert_eq!(parent(&read, "chore"), Some("root"));
    assert_eq!(parent(&read, "project"), None);
    // The archived list is not walked; the finished one is.
    assert_eq!(parent(&read, "stale"), None);
    assert_eq!(parent(&read, "shut"), Some("closed"));
}

#[test]
fn a_finished_subtask_is_left_out_but_still_named() {
    let read = combined_board(&workspace(), &ids(), Some(T_MS + 1)).unwrap();
    assert_eq!(tree(&read, "project").unwrap(), [("detail", 1)]);
    assert_eq!(tree(&read, "step").unwrap(), [("detail", 0)]);
    assert!(read.rows.iter().all(|row| row.id != "step"));
    assert!(read.other_ids.contains(&"step".to_string()));
    assert_eq!(parent(&read, "detail"), Some("step"));
    assert_eq!(parent(&read, "step"), Some("project"));
    // Finished at the cut-off or after it, it still crosses.
    let read = combined_board(&workspace(), &ids(), Some(T_MS)).unwrap();
    assert_eq!(
        tree(&read, "project").unwrap(),
        [("step", 0), ("detail", 1)]
    );
}

#[test]
fn only_rows_with_a_placement_carry_one() {
    let read = combined_board(&workspace(), &ids(), None).unwrap();
    let detail = placement(&read, "detail").unwrap();
    assert_eq!(detail.kanban_column.as_deref(), Some("doing"));
    let chore = placement(&read, "chore").unwrap();
    assert_eq!(
        (
            chore.kanban_column.as_deref(),
            chore.matrix_urgency,
            chore.matrix_importance
        ),
        (None, Some(1), Some(0))
    );
    assert!(placement(&read, "project").is_none());
}

#[test]
fn a_scope_of_one_list_and_an_empty_scope() {
    let read = combined_board(&workspace(), &["o".to_string()], None).unwrap();
    assert_eq!(cards(&read), ["chore"]);
    let read = combined_board(&workspace(), &[], None).unwrap();
    assert!(read.rows.is_empty() && read.cards.is_empty() && read.tree_keys.is_empty());
}
