import Foundation
import TestSQLite
import TaktWorkspace
import XCTest

/// The `priority` CLI (the app's MCP server) writes the task tree from another
/// process. These pin the two halves of that contract the app is responsible
/// for: noticing the write, and being able to undo it as one step.
final class WorkspaceExternalWriteTests: XCTestCase {
  private var directoryURL: URL!
  private var databaseURL: URL!
  private var store: WorkspaceStore!
  private var listID: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktExternalWriteTests-\(UUID().uuidString)", isDirectory: true)
    databaseURL = directoryURL.appendingPathComponent("priority.sqlite")
    store = try WorkspaceStore(databaseURL: databaseURL)
    let workspace = try store.bootstrapIfNeeded()
    listID = try XCTUnwrap(store.inbox(in: workspace.id)).id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testTheTokenIgnoresTheStoresOwnWrites() throws {
    let before = try store.externalChangeToken()
    _ = try store.createTask(listId: listID, title: "Mine")
    try store.setStatus(.completed, for: try XCTUnwrap(store.tasks(in: listID).first).id)
    XCTAssertEqual(try store.externalChangeToken(), before)
  }

  func testTheTokenMovesWhenAnotherConnectionCommits() throws {
    let before = try store.externalChangeToken()
    let other = try DatabaseQueue(path: databaseURL.path)
    try other.write { db in
      try db.execute(sql: "UPDATE task_lists SET name = 'Elsewhere' WHERE id = ?", arguments: [listID])
    }
    XCTAssertNotEqual(try store.externalChangeToken(), before)
    XCTAssertEqual(try store.lists(in: try XCTUnwrap(store.workspaces().first).id)
      .first { $0.id == listID }?.name, "Elsewhere")
  }

  /// The poll the app runs is the awaited form; it has to agree with the
  /// synchronous one on both counts.
  func testTheAwaitedTokenAgreesWithTheSynchronousOne() async throws {
    let before = try await store.readExternalChangeToken()
    XCTAssertEqual(before, try store.externalChangeToken())
    _ = try store.createTask(listId: listID, title: "Mine")
    let afterOwnWrite = try await store.readExternalChangeToken()
    XCTAssertEqual(afterOwnWrite, before)
    let other = try DatabaseQueue(path: databaseURL.path)
    let listID: String = listID
    try await other.write { db in
      try db.execute(sql: "UPDATE task_lists SET name = 'Elsewhere' WHERE id = ?", arguments: [listID])
    }
    let afterOtherWrite = try await store.readExternalChangeToken()
    XCTAssertNotEqual(afterOtherWrite, before)
  }

  /// The statements `cli/src/workspace_tasks.rs` runs for `workspace_task_add`
  /// with a link, inside its `journalled` wrapper. If the app's undo cannot
  /// take this back in one step, the two writers disagree about the journal.
  func testAWriteJournalledTheWayTheCLIDoesIsOneUndoStep() throws {
    let other = try DatabaseQueue(path: databaseURL.path)
    let taskID = UUID().uuidString
    let now = "2026-09-27 10:00:00.000"
    try other.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(
        sql: "UPDATE undo_control SET groupId = ?, label = 'MCP: New Task', suppressed = 0 WHERE id = 0",
        arguments: [UUID().uuidString])
      try db.execute(sql: """
        INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, createdAt, updatedAt, itemKind)
        VALUES (?, ?, NULL, 'From the assistant', 'Some notes', 'open', 0, ?, ?, 'task')
        """, arguments: [taskID, listID, now, now])
      try db.execute(sql: """
        INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, updatedAt)
        VALUES (?, '[]', '["obsidian://open?vault=Studies&file=Paper"]', ?)
        """, arguments: [taskID, now])
      try db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0")
    }

    // The app reads the row as its own, links included.
    let task = try XCTUnwrap(store.task(id: taskID))
    XCTAssertEqual(task.title, "From the assistant")
    XCTAssertEqual(task.createdAt.timeIntervalSince1970, 1_790_503_200, accuracy: 0.001)
    XCTAssertEqual(
      try store.taskEditorMetadata(for: taskID).externalLinks,
      ["obsidian://open?vault=Studies&file=Paper"])
    let workspaceID = try XCTUnwrap(store.workspaces().first).id
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "assistant").map(\.task.id), [taskID])

    XCTAssertEqual(try store.undoableLabel(), "MCP: New Task")
    XCTAssertEqual(try store.undo(), "MCP: New Task")
    XCTAssertNil(try store.task(id: taskID))
    XCTAssertEqual(try store.redo(), "MCP: New Task")
    XCTAssertEqual(try store.taskEditorMetadata(for: taskID).externalLinks.count, 1)
  }
}
