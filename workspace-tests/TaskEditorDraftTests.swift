import Foundation
import PriorityWorkspace
import XCTest

final class TaskEditorDraftTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var initial: TaskEditorSnapshot!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("DraftTests-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    let task = try store.createTask(listId: try XCTUnwrap(store.inbox(in: workspace.id)).id, title: "Original")
    initial = try store.taskEditorSnapshot(for: task.id)
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  func testCleanDraftRefreshesAllFieldsIncludingMetadataAndDailyState() {
    var draft = TaskEditorDraft(snapshot: initial)
    var saved = initial!
    saved.title = "Restored by undo"
    saved.metadata.tags = ["Tag"]
    saved.dailyProgress = true
    draft.reconcile(with: saved)
    XCTAssertEqual(draft.values, saved.values)
    XCTAssertFalse(draft.isDirty)
  }

  func testDirtyNotesSurviveUnrelatedSavedTitleChange() throws {
    var draft = TaskEditorDraft(snapshot: initial)
    draft.values.notes = "My notes"
    var saved = initial!
    saved.title = "Restored by undo"
    draft.reconcile(with: saved)
    XCTAssertEqual(draft.values.notes, "My notes")
    XCTAssertEqual(draft.values.title, saved.title)
    XCTAssertTrue(draft.conflicts.isEmpty)
    XCTAssertEqual(try draft.validatedSnapshot().title, saved.title)
  }

  func testConflictsPersistAcrossRefreshUntilExplicitlyResolvedAndSubsequentChangesConflictAgain() throws {
    var draft = TaskEditorDraft(snapshot: initial)
    draft.values.title = "My edit"
    var saved = initial!
    saved.title = "Saved edit"
    draft.reconcile(with: saved)
    draft.reconcile(with: saved)
    XCTAssertEqual(draft.values.title, "My edit")
    XCTAssertEqual(draft.conflicts, [.title])
    XCTAssertThrowsError(try draft.validatedSnapshot())
    draft.resolve(.title, useSaved: false)
    XCTAssertEqual(try draft.validatedSnapshot().title, "My edit")
    saved.title = "Another saved edit"
    draft.reconcile(with: saved)
    XCTAssertEqual(draft.conflicts, [.title])
    draft.resolve(.title, useSaved: true)
    XCTAssertEqual(draft.values.title, saved.title)
    XCTAssertFalse(draft.isDirty)
  }

  func testConvergingValuesBecomeCleanWithoutAConflict() {
    var draft = TaskEditorDraft(snapshot: initial)
    draft.values.title = "Same edit"
    var saved = initial!
    saved.title = "Same edit"
    draft.reconcile(with: saved)
    XCTAssertFalse(draft.isDirty)
    XCTAssertTrue(draft.conflicts.isEmpty)
  }

  func testExactEstimateChangesConflictWithDirtyMinutesButConvergingEstimateDoesNot() {
    var snapshot = initial!
    snapshot.estimateSeconds = 45
    var draft = TaskEditorDraft(snapshot: snapshot)
    draft.values.estimateMinutes = "1"
    snapshot.estimateSeconds = 59
    draft.reconcile(with: snapshot)
    XCTAssertEqual(draft.conflicts, [.estimateMinutes])
    snapshot.estimateSeconds = 60
    draft.reconcile(with: snapshot)
    XCTAssertTrue(draft.conflicts.isEmpty)
    XCTAssertFalse(draft.isDirty)
  }

  func testDeletingAndRestoringTaskPreservesItsDraftButPreventsSavingWhileMissing() throws {
    var draft = TaskEditorDraft(snapshot: initial)
    draft.values.notes = "Retain these"
    draft.isUnavailable = true
    XCTAssertThrowsError(try draft.validatedSnapshot())
    draft.reconcile(with: initial)
    XCTAssertFalse(draft.isUnavailable)
    XCTAssertEqual(try draft.validatedSnapshot().notes, "Retain these")
  }

  func testPersistenceRestoresInvalidInputConflictsAndUnavailableDraftsButExcludesCleanDrafts() throws {
    var draft = TaskEditorDraft(snapshot: initial)
    draft.values.estimateMinutes = "unfinished"
    draft.values.title = "My edit"
    var saved = initial!
    saved.title = "Saved edit"
    draft.reconcile(with: saved)
    draft.isUnavailable = true
    let disk = TaskEditorDraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
    try disk.save([draft, TaskEditorDraft(snapshot: initial)])
    XCTAssertEqual(try disk.load(), [draft])
    try disk.save([TaskEditorDraft(snapshot: initial)])
    XCTAssertTrue(try disk.load().isEmpty)
  }

  func testCorruptAndFutureDraftFormatsReportErrorsInsteadOfDiscardingTheFile() throws {
    let file = directory.appendingPathComponent("drafts.json")
    let disk = TaskEditorDraftStore(fileURL: file)
    for raw in ["broken", "{\"version\":3,\"drafts\":[]}"] {
      try Data(raw.utf8).write(to: file)
      XCTAssertThrowsError(try disk.load())
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
    }
  }

  func testPersistedDraftWithFractionalDueDateDoesNotBecomeFalselyStale() throws {
    try store.updateTask(id: initial.taskId, title: initial.title, notes: "", dueAt: Date(timeIntervalSince1970: 123456.789), estimateSeconds: nil)
    let snapshot = try store.taskEditorSnapshot(for: initial.taskId)
    var draft = TaskEditorDraft(snapshot: snapshot)
    draft.values.title = "Renamed"
    let disk = TaskEditorDraftStore(fileURL: directory.appendingPathComponent("drafts.json"))
    try disk.save([draft])
    let restored = try XCTUnwrap(disk.load().first)
    XCTAssertEqual(restored.baseline, snapshot)
    XCTAssertEqual(try store.saveTaskEditor(restored).title, "Renamed")
  }
}
