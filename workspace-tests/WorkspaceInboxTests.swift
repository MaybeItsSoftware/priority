import Foundation
import GRDB
import PriorityWorkspace
import XCTest

/// The Inbox is the one list the app itself relies on, so its identity has to
/// survive renaming, and a database from before the role existed has to arrive
/// with the right list claimed rather than a second Inbox beside it.
final class WorkspaceInboxTests: XCTestCase {
  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityInboxTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  private func makeStore() throws -> WorkspaceStore {
    try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
  }

  func testBootstrapGivesTheInboxItsRole() throws {
    let store = try makeStore()
    let workspace = try store.bootstrapIfNeeded()

    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))
    XCTAssertEqual(inbox.name, "Inbox")
    XCTAssertTrue(inbox.isSystemList)
  }

  func testRenamingTheInboxKeepsItTheInbox() throws {
    let store = try makeStore()
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))

    try store.updateList(id: inbox.id, name: "Capture", colorHex: nil)

    let found = try XCTUnwrap(store.inbox(in: workspace.id))
    XCTAssertEqual(found.id, inbox.id)
    XCTAssertEqual(found.name, "Capture")
  }

  func testTheInboxCannotBeArchivedOrDeleted() throws {
    let store = try makeStore()
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))

    XCTAssertThrowsError(try store.setListArchived(true, id: inbox.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .systemListIsPermanent)
    }
    XCTAssertThrowsError(try store.deleteList(id: inbox.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .systemListIsPermanent)
    }
    XCTAssertEqual(try store.lists(in: workspace.id).map(\.id), [inbox.id])
  }

  func testAWorkspaceWithNoInboxGetsOneOnNextLaunch() throws {
    let url = directoryURL.appendingPathComponent("priority.sqlite")
    let store = try WorkspaceStore(databaseURL: url)
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))

    // Deleting it behind the store's back, which is what a database written
    // before the role existed can already look like.
    try DatabaseQueue(path: url.path).write { db in
      try db.execute(sql: "DELETE FROM task_lists WHERE id = ?", arguments: [inbox.id])
    }
    XCTAssertNil(try store.inbox(in: workspace.id))

    try store.bootstrapIfNeeded()

    let replacement = try XCTUnwrap(store.inbox(in: workspace.id))
    XCTAssertEqual(replacement.name, "Inbox")
    XCTAssertNotEqual(replacement.id, inbox.id)
  }

  /// Migration fixture: a database in the pre-role shape with two lists called
  /// Inbox. The older one is the one the app has been capturing into, and it is
  /// the one the migration has to claim.
  func testMigrationClaimsTheOldestInboxAndLeavesLaterOnesAlone() throws {
    let url = directoryURL.appendingPathComponent("legacy.sqlite")
    let older = "list-older"
    let newer = "list-newer"

    // A real database, then rewound: drop the column and index v6 added so the
    // migrator is handed exactly what a v5 install had, and re-run it.
    let workspaceID = try WorkspaceStore(databaseURL: url).bootstrapIfNeeded().id
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.rollBackSyncMigration()
      // The undo journal's triggers name every column of the tables they
      // watch, so they have to come off before a column can be taken away —
      // and all of them, because SQLite reparses the whole schema during an
      // ALTER and a trigger left pointing at a dropped table fails that.
      // Removing their migration too means reopening puts them back.
      let triggers = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'change\\_log%' ESCAPE '\\'")
      for trigger in triggers { try db.execute(sql: "DROP TRIGGER \(trigger)") }
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8_undo_journal'")
      try db.execute(sql: "DROP TABLE change_log")
      try db.execute(sql: "DROP TABLE undo_control")
      try db.execute(sql: "DROP INDEX task_lists_on_system_role")
      try db.execute(sql: "ALTER TABLE task_lists DROP COLUMN systemRole")
      try db.execute(sql: "DELETE FROM task_lists")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6_inbox_as_a_system_list'")
      for (id, name, created) in [
        (older, "Inbox", "2026-01-01 00:00:00.000"),
        (newer, "Inbox", "2026-06-01 00:00:00.000"),
        ("list-work", "Work", "2026-03-01 00:00:00.000"),
      ] {
        try db.execute(
          sql: """
            INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, createdAt, updatedAt)
            VALUES (?, ?, NULL, ?, NULL, 0, 0, ?, ?)
            """,
          arguments: [id, workspaceID, name, created, created])
      }
    }

    let store = try WorkspaceStore(databaseURL: url)

    let inbox = try XCTUnwrap(store.inbox(in: workspaceID))
    XCTAssertEqual(inbox.id, older)
    let roles = try store.lists(in: workspaceID).filter(\.isSystemList)
    XCTAssertEqual(roles.map(\.id), [older])
    // The second Inbox stays an ordinary list rather than being merged away.
    XCTAssertEqual(try store.lists(in: workspaceID).count, 3)
  }
}
