import Foundation
import GRDB
@testable import TaktWorkspace
import XCTest

/// `WorkspaceTask` and `TaskMetadata` read their rows by hand rather than
/// through `Decodable`, for speed. A stored property the hand-written reader
/// forgot would come back nil without any error, so these write a row with
/// every column set and expect exactly that value back.
final class WorkspaceRowDecodingTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var listID: String!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktRowDecodingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    listID = try XCTUnwrap(store.inbox(in: workspace.id)).id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  /// Whole milliseconds, the precision the database stores.
  private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds.rounded()) }

  func testEveryTaskColumnSurvivesARoundTrip() throws {
    let parent = try store.createTask(listId: listID, title: "Parent")
    let task = WorkspaceTask(
      id: UUID().uuidString, listId: listID, parentTaskId: parent.id, title: "Every field", notes: "Notes",
      status: .completed, sortOrder: 7, dueAt: date(1_800_000_000), estimateSeconds: 900,
      sourceSystem: "checkvist", sourceId: "42", itemKind: .list, isPromoted: true,
      archivedAt: date(1_800_000_100), completedAt: date(1_800_000_200),
      createdAt: date(1_700_000_000), updatedAt: date(1_700_000_300))
    try store.database.write { db in try task.insert(db) }
    let read = try store.database.read { db in try WorkspaceTask.fetchOne(db, key: task.id) }
    XCTAssertEqual(read, task)
  }

  func testEveryMetadataColumnSurvivesARoundTrip() throws {
    let task = try store.createTask(listId: listID, title: "Metadata")
    var metadata = TaskMetadata(
      taskId: task.id, priority: 2, startAt: date(1_800_000_000), tagsJSON: #"["a"]"#,
      recurrenceRule: "FREQ=DAILY", matrixUrgency: 1, matrixImportance: 3, kanbanColumn: "today",
      externalLinksJSON: #"["https://example.com"]"#, focusRank: 4, updatedAt: date(1_700_000_000))
    metadata.planningJSON = #"{"x":1}"#
    metadata.waitingOn = "Sam"
    metadata.waitingFollowUpAt = date(1_800_000_500)
    metadata.waitingFollowUpTaskId = task.id
    metadata.followUpOfTaskId = task.id
    try store.database.write { db in try metadata.save(db) }
    let read = try store.database.read { db in try TaskMetadata.fetchOne(db, key: task.id) }
    XCTAssertEqual(read, metadata)
  }
}
