import Foundation
import GRDB
import PriorityWorkspace
import XCTest

/// The migration ladder itself, as opposed to what any one migration does.
///
/// Identifiers and their order are effectively permanent: a database in the
/// wild records which ones it has run, so renaming or reordering one silently
/// re-runs it, or silently skips it, on every existing install.
final class WorkspaceMigrationTests: XCTestCase {
  private static let expectedLadder = [
    "v1_local_workspace",
    "v2_metadata_and_focus",
    "v3_dailies_as_contributions",
    "v4_manual_focus_order",
    "v5_task_source_identity",
    "v6_inbox_as_a_system_list",
    "v7_task_full_text_search",
    "v8_undo_journal",
    "v9_focus_block_start",
    "v10_focus_points",
  ]

  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityMigrationTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  private func appliedMigrations(at url: URL) throws -> [String] {
    try DatabaseQueue(path: url.path).read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }
  }

  func testEveryMigrationAppliesInOrderToANewDatabase() throws {
    let url = directoryURL.appendingPathComponent("new.sqlite")
    _ = try WorkspaceStore(databaseURL: url)

    XCTAssertEqual(try appliedMigrations(at: url), Self.expectedLadder)
  }

  func testReopeningAppliesNothingFurther() throws {
    let url = directoryURL.appendingPathComponent("reopen.sqlite")
    let store = try WorkspaceStore(databaseURL: url)
    let workspace = try store.bootstrapIfNeeded()
    let task = try store.createTask(
      listId: try XCTUnwrap(store.inbox(in: workspace.id)).id, title: "Survives a reopen")

    let reopened = try WorkspaceStore(databaseURL: url)

    XCTAssertEqual(try appliedMigrations(at: url), Self.expectedLadder)
    XCTAssertEqual(try reopened.task(id: task.id)?.title, "Survives a reopen")
    XCTAssertEqual(try reopened.workspaces().map(\.id), [workspace.id])
  }

  /// Each migration has to be able to run against a database that already has
  /// work in it, not only against an empty one. Rewinding the ladder and
  /// letting it re-run is the closest a test can get to an old install.
  func testTheLadderRerunsOverExistingWorkWithoutLosingIt() throws {
    let url = directoryURL.appendingPathComponent("populated.sqlite")
    let store = try WorkspaceStore(databaseURL: url)
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.inbox(in: workspace.id))
    let parent = try store.createTask(listId: list.id, title: "Parent task")
    let child = try store.createTask(listId: list.id, title: "Child task", parentTaskId: parent.id)
    try store.setKanbanColumn("today", for: child.id)
    let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)
    let session = try store.startFocusSession(taskId: parent.id, now: sessionStart)

    // Rewind the additive migrations: drop what they created, forget that they
    // ran, and reopen. What v1–v4 built, and the data in it, stays put.
    try DatabaseQueue(path: url.path).write { db in
      let triggers = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'change\\_log%' ESCAPE '\\'")
      for trigger in triggers { try db.execute(sql: "DROP TRIGGER \(trigger)") }
      for table in ["focus_awards", "change_log", "undo_control", "tasks_fts"] {
        try db.execute(sql: "DROP TABLE \(table)")
      }
      for trigger in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%tasks_fts%'") {
        try db.execute(sql: "DROP TRIGGER \(trigger)")
      }
      try db.execute(sql: "DROP INDEX task_lists_on_system_role")
      try db.execute(sql: "ALTER TABLE task_lists DROP COLUMN systemRole")
      try db.execute(sql: "ALTER TABLE focus_sessions DROP COLUMN activeTaskStartedAt")
      try db.execute(sql: "DROP INDEX tasks_on_source")
      try db.execute(sql: "ALTER TABLE tasks DROP COLUMN sourceSystem")
      try db.execute(sql: "ALTER TABLE tasks DROP COLUMN sourceId")
      try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?, ?, ?, ?, ?)",
        arguments: ["v5_task_source_identity", "v6_inbox_as_a_system_list",
                    "v7_task_full_text_search", "v8_undo_journal", "v9_focus_block_start",
                    "v10_focus_points"])
    }

    let migrated = try WorkspaceStore(databaseURL: url)

    XCTAssertEqual(try appliedMigrations(at: url), Self.expectedLadder)
    XCTAssertEqual(try migrated.outline(in: list.id).map { $0.task.title }, ["Parent task", "Child task"])
    XCTAssertEqual(try migrated.kanbanColumn(for: child.id), "today")
    // And everything the later migrations add works on that existing data.
    XCTAssertEqual(try migrated.inbox(in: workspace.id)?.id, list.id)
    // A session that predates the per-task clock keeps the only start it had.
    XCTAssertEqual(try migrated.activeFocusSession()?.id, session.id)
    XCTAssertEqual(try migrated.activeFocusSession()?.activeTaskStartedAt, sessionStart)
    XCTAssertEqual(try migrated.searchTasks(in: workspace.id, matching: "child").map(\.task.id), [child.id])
    try migrated.updateTask(id: parent.id, title: "Renamed", notes: "", dueAt: nil, estimateSeconds: nil)
    XCTAssertEqual(try migrated.undo(), "Edit Task")
    XCTAssertEqual(try migrated.task(id: parent.id)?.title, "Parent task")
  }
}
