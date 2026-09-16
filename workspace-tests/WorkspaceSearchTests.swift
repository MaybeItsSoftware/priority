import Foundation
import GRDB
import PriorityWorkspace
import XCTest

final class WorkspaceSearchTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var listID: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrioritySearchTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    workspaceID = workspace.id
    listID = try XCTUnwrap(store.inbox(in: workspace.id)).id
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testFindsTasksByTitleAndNotes() throws {
    let invoice = try store.createTask(listId: listID, title: "Send the invoice")
    let unrelated = try store.createTask(listId: listID, title: "Water the plants")
    try store.updateTask(id: unrelated.id, title: "Water the plants", notes: "Ask about the invoice while there",
      dueAt: nil, estimateSeconds: nil)
    _ = try store.createTask(listId: listID, title: "Buy milk")

    let results = try store.searchTasks(in: workspaceID, matching: "invoice")

    XCTAssertEqual(results.map(\.task.id), [invoice.id, unrelated.id])
    XCTAssertEqual(results.first?.list.id, listID)
    // Title match first, and the notes match carries the stretch it matched on.
    XCTAssertNil(results.first?.notesSnippet)
    XCTAssertEqual(results.last?.notesSnippet?.contains("invoice"), true)
  }

  func testMatchesPrefixesSoResultsNarrowWhileTyping() throws {
    let task = try store.createTask(listId: listID, title: "Reconcile the accounts")

    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "recon").map(\.task.id), [task.id])
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "recon acc").map(\.task.id), [task.id])
    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "reconx").isEmpty)
  }

  func testIndexFollowsEditsAndDeletions() throws {
    let task = try store.createTask(listId: listID, title: "Draft the proposal")
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "proposal").count, 1)

    try store.updateTask(id: task.id, title: "Draft the summary", notes: "", dueAt: nil, estimateSeconds: nil)

    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "proposal").isEmpty)
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "summary").count, 1)

    try store.deleteTask(id: task.id)
    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "summary").isEmpty)
  }

  func testExcludesCompletedTasksAndArchivedListsUnlessAsked() throws {
    let other = try store.createList(workspaceId: workspaceID, name: "Old work")
    let archived = try store.createTask(listId: other.id, title: "Archived report")
    let done = try store.createTask(listId: listID, title: "Finished report")
    try store.setStatus(.completed, for: done.id)
    try store.setListArchived(true, id: other.id)

    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "report").isEmpty)
    XCTAssertEqual(
      try store.searchTasks(in: workspaceID, matching: "report", includingCompleted: true,
        includingArchivedLists: true).map(\.task.id).sorted(),
      [archived.id, done.id].sorted())
  }

  func testIgnoresAnEmptyOrUnmatchableQuery() throws {
    _ = try store.createTask(listId: listID, title: "Something")

    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "   ").isEmpty)
    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "***").isEmpty)
  }

  /// The migration builds the index from the tasks already in the database, so
  /// work written before the app had search has to be findable without being
  /// edited again. Rewound to the pre-index shape to prove it.
  func testTasksWrittenBeforeTheIndexExistedAreStillFound() throws {
    let url = directoryURL.appendingPathComponent("prior.sqlite")
    let store = try WorkspaceStore(databaseURL: url)
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.inbox(in: workspace.id))
    let existing = try store.createTask(listId: list.id, title: "Older task about shipping")

    try DatabaseQueue(path: url.path).write { db in
      let triggers = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'tasks'")
      XCTAssertFalse(triggers.isEmpty, "synchronize() should have written the index triggers")
      for trigger in triggers { try db.execute(sql: "DROP TRIGGER \(trigger)") }
      try db.execute(sql: "DROP TABLE tasks_fts")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7_task_full_text_search'")
    }

    let reopened = try WorkspaceStore(databaseURL: url)

    XCTAssertEqual(try reopened.searchTasks(in: workspace.id, matching: "shipping").map(\.task.id), [existing.id])
    // And the rebuilt index is live, not just backfilled once.
    let added = try reopened.createTask(listId: list.id, title: "Newer task about freight")
    XCTAssertEqual(try reopened.searchTasks(in: workspace.id, matching: "freight").map(\.task.id), [added.id])
  }
}
