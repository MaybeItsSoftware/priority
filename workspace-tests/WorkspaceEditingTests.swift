import Foundation
import GRDB
import TaktWorkspace
import XCTest

final class WorkspaceEditingTests: XCTestCase {
  private var directory: URL!
  private var url: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var inboxID: String!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("EditorTests-\(UUID().uuidString)")
    url = directory.appendingPathComponent("workspace.sqlite")
    store = try WorkspaceStore(databaseURL: url)
    workspaceID = try store.bootstrapIfNeeded().id
    inboxID = try XCTUnwrap(store.inbox(in: workspaceID)).id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func draft(title: String = "Original") throws -> TaskEditorDraft {
    let task = try store.createTask(listId: inboxID, title: title)
    return TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
  }

  func testCompleteTaskSaveIsOneUndoStepAndPreservesPlacementAndOtherMetadata() throws {
    var edit = try draft()
    let id = edit.baseline.taskId
    let child = try store.createTask(listId: inboxID, title: "Child", parentTaskId: id)
    try store.setKanbanColumn("today", for: id)
    try store.setMatrixPosition(.init(urgency: 1, importance: 0), for: id)
    edit.values.title = "Changed"
    edit.values.notes = "Notes"
    edit.values.estimateMinutes = "15"
    edit.values.tags = " Work, work , Launch "
    edit.values.priority = 3
    edit.values.dailyProgress = true

    let committed = try store.saveTaskEditor(edit)
    XCTAssertEqual(committed.title, "Changed")
    XCTAssertEqual(committed.metadata.tags, ["Work", "Launch"])
    XCTAssertEqual(try store.daily(forTaskId: id)?.targetSeconds, 900)
    XCTAssertEqual(try store.undo(), "Edit Task")
    XCTAssertEqual(try store.taskEditorSnapshot(for: id), edit.baseline)
    XCTAssertEqual(try store.task(id: child.id)?.parentTaskId, id)
    XCTAssertEqual(try store.kanbanColumn(for: id), "today")
    XCTAssertEqual(try store.matrixPosition(for: id), .init(urgency: 1, importance: 0))
    try store.redo()
    XCTAssertEqual(try store.taskEditorSnapshot(for: id), committed)
  }

  func testFailureAfterContentAndMetadataWritesRollsBackEverythingIncludingHistory() throws {
    var edit = try draft()
    edit.values.title = "Changed"
    edit.values.tags = "Tag"
    edit.values.dailyProgress = true
    try store.updateTask(id: edit.baseline.taskId, title: "Original", notes: "Earlier edit", dueAt: nil, estimateSeconds: nil)
    try store.undo()
    let previousLabel = try store.undoableLabel()
    let previousRedo = try store.redoableLabel()
    try DatabaseQueue(path: url.path).write { db in
      try db.execute(sql: """
        CREATE TRIGGER fail_daily BEFORE INSERT ON dailies
        BEGIN SELECT RAISE(ABORT, 'Injected daily failure'); END
        """)
    }
    XCTAssertThrowsError(try store.saveTaskEditor(edit))
    XCTAssertEqual(try store.taskEditorSnapshot(for: edit.baseline.taskId), edit.baseline)
    XCTAssertEqual(try store.undoableLabel(), previousLabel)
    XCTAssertEqual(try store.redoableLabel(), previousRedo)
  }

  func testUnchangedTaskSavePreservesRedo() throws {
    let edit = try draft()
    var changed = edit
    changed.values.title = "Changed"
    try store.saveTaskEditor(changed)
    try store.undo()
    let timestamp = try store.task(id: edit.baseline.taskId)?.updatedAt
    try store.saveTaskEditor(edit)
    XCTAssertEqual(try store.task(id: edit.baseline.taskId)?.updatedAt, timestamp)
    XCTAssertEqual(try store.redoableLabel(), "Edit Task")
    try store.redo()
    XCTAssertEqual(try store.task(id: edit.baseline.taskId)?.title, "Changed")
  }

  func testStaleMetadataAndDailySnapshotsAreRejectedWithoutOverwritingTitle() throws {
    var edit = try draft()
    edit.values.title = "Draft title"
    try store.updateTaskEditorMetadata(taskId: edit.baseline.taskId, metadata: .init(tags: ["New tag"]))
    XCTAssertThrowsError(try store.saveTaskEditor(edit)) {
      XCTAssertEqual($0 as? TaskEditorError, .conflictingChanges)
    }
    XCTAssertEqual(try store.task(id: edit.baseline.taskId)?.title, "Original")
    edit.reconcile(with: try store.taskEditorSnapshot(for: edit.baseline.taskId))
    try store.makeDaily(taskId: edit.baseline.taskId)
    XCTAssertThrowsError(try store.saveTaskEditor(edit))
    XCTAssertEqual(try store.task(id: edit.baseline.taskId)?.title, "Original")
  }

  func testUnrelatedTitleSavePreservesExactEstimateCommaTagsAndDailySchedule() throws {
    var edit = try draft()
    let id = edit.baseline.taskId
    try store.updateTask(id: id, title: "Original", notes: "", dueAt: nil, estimateSeconds: 45)
    try store.updateTaskEditorMetadata(taskId: id, metadata: .init(tags: ["Research, design"]))
    let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
    let daily = try store.makeDaily(taskId: id, weekdays: [2, 4], intervalDays: 3, targetSeconds: 600, now: now)
    let contribution = try store.logContribution(dailyId: daily.id, seconds: 60, now: now)
    edit = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: id))
    edit.values.title = "Renamed"
    try store.saveTaskEditor(edit)
    XCTAssertEqual(try store.task(id: id)?.estimateSeconds, 45)
    XCTAssertEqual(try store.taskEditorMetadata(for: id).tags, ["Research, design"])
    XCTAssertEqual(try store.daily(forTaskId: id), daily)
    XCTAssertEqual(try store.contributionHistory(dailyId: daily.id, days: 1), [contribution])
  }

  func testReEnablingDailyUsesNewEstimateButKeepsScheduleIdentityAndContributions() throws {
    let initial = try draft()
    let id = initial.baseline.taskId
    let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
    let daily = try store.makeDaily(taskId: id, weekdays: [2], intervalDays: 4, targetSeconds: 100, now: now)
    let contribution = try store.logContribution(dailyId: daily.id, seconds: 30, now: now)
    try store.archiveDaily(taskId: id)
    var edit = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: id))
    edit.values.estimateMinutes = "20"
    edit.values.dailyProgress = true
    try store.saveTaskEditor(edit)
    let restored = try XCTUnwrap(store.daily(forTaskId: id))
    XCTAssertEqual(restored.id, daily.id)
    XCTAssertEqual(restored.intervalDays, daily.intervalDays)
    XCTAssertEqual(restored.intervalAnchor, daily.intervalAnchor)
    XCTAssertEqual(restored.activeWeekdaysMask, daily.activeWeekdaysMask)
    XCTAssertEqual(restored.targetSeconds, 1200)
    XCTAssertEqual(try store.contributionHistory(dailyId: daily.id, days: 1), [contribution])
  }

  func testInvalidEstimateAndDeletedTaskNeverSaveOtherFields() throws {
    var edit = try draft()
    edit.values.title = "Changed"
    for estimate in ["oops", "-2", "1.5.1", "nan", "inf", String(Int.max)] {
      edit.values.estimateMinutes = estimate
      XCTAssertThrowsError(try store.saveTaskEditor(edit)) {
        XCTAssertEqual($0 as? TaskEditorError, .invalidEstimate)
      }
      XCTAssertEqual(try store.task(id: edit.baseline.taskId)?.title, "Original")
    }
    edit.values.estimateMinutes = "1"
    try store.deleteTask(id: edit.baseline.taskId)
    XCTAssertThrowsError(try store.saveTaskEditor(edit)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .missingTask)
    }
  }

  func testFractionalMinutesSaveAsSecondsAndTitleEditsDoNotChangeThem() throws {
    var edit = try draft()
    edit.values.estimateMinutes = "0.75"
    let committed = try store.saveTaskEditor(edit)
    XCTAssertEqual(committed.estimateSeconds, 45)
    XCTAssertEqual(committed.values.estimateMinutes, "0.75")
    var rename = TaskEditorDraft(snapshot: committed)
    rename.values.title = "Renamed"
    XCTAssertEqual(try store.saveTaskEditor(rename).estimateSeconds, 45)
  }

  func testCompletionAndPlacementChangesDoNotInvalidateOrGetOverwrittenByEditorSave() throws {
    var edit = try draft()
    let id = edit.baseline.taskId
    edit.values.title = "Renamed"
    let destination = try store.createList(workspaceId: workspaceID, name: "Other")
    try store.moveTask(id: id, toListId: destination.id)
    try store.setStatus(.completed, for: id)
    try store.saveTaskEditor(edit)
    XCTAssertEqual(try store.task(id: id)?.status, .completed)
    XCTAssertEqual(try store.task(id: id)?.listId, destination.id)
    XCTAssertEqual(try store.task(id: id)?.title, "Renamed")
  }

  func testFolderRenameAndInvalidMoveAreAtomicAndPickerExcludesAllDescendants() throws {
    let parent = try store.createFolder(workspaceId: workspaceID, name: "Parent", now: Date(timeIntervalSince1970: 100))
    let child = try store.createFolder(workspaceId: workspaceID, name: "Child", parentFolderId: parent.id)
    let grandchild = try store.createFolder(workspaceId: workspaceID, name: "Grandchild", parentFolderId: child.id)
    let other = try store.createFolder(workspaceId: workspaceID, name: "Other")
    XCTAssertEqual(try store.validParentFolders(for: parent.id).map(\.id), [other.id])
    for invalidID in [parent.id, child.id, grandchild.id] {
      XCTAssertThrowsError(try store.saveFolderSettings(id: parent.id, name: "Renamed", parentFolderId: invalidID))
      XCTAssertEqual(try store.folders(in: workspaceID).first { $0.id == parent.id }, parent)
    }
    try store.saveFolderSettings(id: parent.id, name: "Renamed", parentFolderId: other.id)
    XCTAssertEqual(try store.undo(), "Edit Folder")
    XCTAssertEqual(try store.folders(in: workspaceID).first { $0.id == parent.id }, parent)
  }

  func testListSettingsUndoTogetherAndForbiddenInboxArchiveRollsBackRename() throws {
    let folder = try store.createFolder(workspaceId: workspaceID, name: "Folder")
    let list = try store.createList(workspaceId: workspaceID, name: "Work", now: Date(timeIntervalSince1970: 100))
    try store.saveListSettings(id: list.id, name: "Clients", colorHex: "#abcdef", folderId: folder.id,
                              isArchived: true, visibleRootTaskId: nil)
    XCTAssertEqual(try store.undo(), "Edit List")
    XCTAssertEqual(try store.lists(in: workspaceID).first { $0.id == list.id }, list)
    try store.redo()
    let committed = try XCTUnwrap(store.lists(in: workspaceID, includingArchived: true).first { $0.id == list.id })
    XCTAssertEqual(committed.name, "Clients")
    XCTAssertEqual(committed.folderId, folder.id)
    XCTAssertTrue(committed.isArchived)
    XCTAssertThrowsError(try store.saveListSettings(
      id: inboxID, name: "Capture", colorHex: nil, folderId: folder.id, isArchived: true, visibleRootTaskId: nil))
    XCTAssertEqual(try store.inbox(in: workspaceID)?.name, "Inbox")
    XCTAssertNil(try store.inbox(in: workspaceID)?.folderId)
  }

  func testCrossWorkspaceSettingsDestinationsAreRejected() throws {
    let otherID = UUID().uuidString
    try DatabaseQueue(path: url.path).write { db in
      try db.execute(sql: "INSERT INTO workspaces(id, name, createdAt, updatedAt) VALUES (?, 'Other', ?, ?)",
                     arguments: [otherID, Date.now, Date.now])
    }
    let other = try store.createFolder(workspaceId: otherID, name: "Other")
    let folder = try store.createFolder(workspaceId: workspaceID, name: "Folder")
    XCTAssertThrowsError(try store.saveFolderSettings(id: folder.id, name: "Renamed", parentFolderId: other.id))
    XCTAssertThrowsError(try store.saveListSettings(id: inboxID, name: "Renamed", colorHex: nil,
                                                 folderId: other.id, isArchived: false, visibleRootTaskId: nil))
    XCTAssertEqual(try store.inbox(in: workspaceID)?.name, "Inbox")
  }

  func testLegacyRootRecoveryIsExplicitUndoableAndDoesNotMoveOrRenameTasks() throws {
    let list = try XCTUnwrap(store.importTasks(
      workspaceId: workspaceID, listName: "Clients", sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "root", parentSourceId: nil, title: "Old work name", status: .open, sortOrder: 0),
        .init(sourceId: "child", parentSourceId: "root", title: "Proposal", status: .open, sortOrder: 0),
      ])).list
    XCTAssertNil(try store.visibleRootParentTaskID(for: list))
    let root = try XCTUnwrap(store.visibleRootCandidates(in: list.id).first)
    let before = try store.outline(in: list.id)
    try store.saveListSettings(id: list.id, name: list.name, colorHex: nil, folderId: nil,
                              isArchived: false, visibleRootTaskId: root.id)
    XCTAssertEqual(try store.visibleRootParentTaskID(for: list), root.id)
    XCTAssertEqual(try store.outline(in: list.id), before)
    let reopened = try WorkspaceStore(databaseURL: url)
    XCTAssertEqual(try reopened.visibleRootParentTaskID(for: list), root.id)
    try reopened.undo()
    XCTAssertNil(try reopened.visibleRootParentTaskID(for: list))
    try reopened.redo()
    XCTAssertEqual(try reopened.visibleRootParentTaskID(for: list), root.id)
  }

  func testInvalidVisibleRootChoiceDoesNotApplyOtherListEdits() throws {
    let edit = try draft()
    XCTAssertThrowsError(try store.saveListSettings(
      id: inboxID, name: "Capture", colorHex: nil, folderId: nil,
      isArchived: false, visibleRootTaskId: edit.baseline.taskId)) {
      XCTAssertEqual($0 as? TaskEditorError, .invalidVisibleRoot)
    }
    XCTAssertEqual(try store.inbox(in: workspaceID)?.name, "Inbox")
  }
}
