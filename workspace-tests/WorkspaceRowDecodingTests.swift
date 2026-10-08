import Foundation
import TestSQLite
@testable import TaktWorkspace
import XCTest

/// Rows reach `WorkspaceTask` and `TaskMetadata` through the Rust core's
/// records (core/src/records.rs, core/src/rows.rs) and the conversions in
/// `WorkspaceRecords+Core.swift`. A column either side forgot would come back
/// nil without any error, so these write a row with every column set, from a
/// connection of their own, and expect exactly that value back.
final class WorkspaceRowDecodingTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var listID: String!
  private var databaseURL: URL { directory.appendingPathComponent("priority.sqlite") }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktRowDecodingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try WorkspaceStore(databaseURL: databaseURL)
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
    try DatabaseQueue(path: databaseURL.path).write { db in
      try db.execute(
        sql: """
          INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds,
            sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: StatementArguments([
          task.id, task.listId, task.parentTaskId, task.title, task.notes, task.status.rawValue, task.sortOrder,
          task.dueAt, task.estimateSeconds, task.sourceSystem, task.sourceId, task.itemKind?.rawValue,
          task.isPromoted, task.archivedAt, task.completedAt, task.createdAt, task.updatedAt,
        ]))
    }
    XCTAssertEqual(try store.task(id: task.id), task)
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
    try DatabaseQueue(path: databaseURL.path).write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO task_metadata (taskId, priority, startAt, tagsJSON, recurrenceRule, matrixUrgency,
            matrixImportance, kanbanColumn, externalLinksJSON, focusRank, updatedAt, planningJSON, waitingOn,
            waitingFollowUpAt, waitingFollowUpTaskId, followUpOfTaskId)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: StatementArguments([
          metadata.taskId, metadata.priority, metadata.startAt, metadata.tagsJSON, metadata.recurrenceRule,
          metadata.matrixUrgency, metadata.matrixImportance, metadata.kanbanColumn, metadata.externalLinksJSON,
          metadata.focusRank, metadata.updatedAt, metadata.planningJSON, metadata.waitingOn,
          metadata.waitingFollowUpAt, metadata.waitingFollowUpTaskId, metadata.followUpOfTaskId,
        ]))
    }
    XCTAssertEqual(try store.core.metadata(taskId: task.id).map(TaskMetadata.init), metadata)
  }
}
