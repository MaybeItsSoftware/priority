import Foundation
import PriorityWorkspace
@testable import PriorityWorkspaceEditing
import XCTest

final class WorkspaceTaskEditorTests: XCTestCase {
  @MainActor
  private struct Fixture {
    let directory: URL
    let store: WorkspaceStore
    let editor: WorkspaceTaskEditor
    let first: WorkspaceTask
    let second: WorkspaceTask
    var draftsURL: URL { directory.appendingPathComponent("drafts.json") }
  }

  @MainActor
  private func fixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EditorManagerTests-\(UUID().uuidString)")
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))
    let first = try store.createTask(listId: inbox.id, title: "First")
    let second = try store.createTask(listId: inbox.id, title: "Second")
    let editor = WorkspaceTaskEditor(fileURL: directory.appendingPathComponent("drafts.json"))
    return Fixture(directory: directory, store: store, editor: editor, first: first, second: second)
  }

  @MainActor
  func testSwitchingTasksAndRestartingRetainsSeparateDrafts() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.edit(f.first.id) { $0.notes = "First notes" }
    f.editor.open(f.second.id, store: f.store)
    f.editor.edit(f.second.id) { $0.title = "Second draft" }
    f.editor.open(f.first.id, store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.notes, "First notes")
    f.editor.flush()
    let restarted = WorkspaceTaskEditor(fileURL: f.draftsURL)
    restarted.open(f.first.id, store: f.store)
    restarted.open(f.second.id, store: f.store)
    XCTAssertEqual(restarted.draft(for: f.first.id)?.values.title, "First")
    XCTAssertEqual(restarted.draft(for: f.first.id)?.values.notes, "First notes")
    XCTAssertEqual(restarted.draft(for: f.second.id)?.values.title, "Second draft")
  }

  @MainActor
  func testSuccessfulSaveAndRevertClearOnlyTheirOwnPersistedDraft() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    for task in [f.first, f.second] {
      f.editor.open(task.id, store: f.store)
      f.editor.edit(task.id) { $0.title += " edited" }
    }
    XCTAssertTrue(f.editor.save(f.first.id, store: f.store))
    XCTAssertEqual(try f.store.task(id: f.first.id)?.title, "First edited")
    XCTAssertEqual(try TaskEditorDraftStore(fileURL: f.draftsURL).load().map { $0.baseline.taskId }, [f.second.id])
    f.editor.revert(f.second.id, store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.second.id)?.values.title, "Second")
    XCTAssertTrue(try TaskEditorDraftStore(fileURL: f.draftsURL).load().isEmpty)
  }

  @MainActor
  func testFailedSavePreservesInvalidInputAndSavedValues() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.edit(f.first.id) { $0.title = "Renamed"; $0.estimateMinutes = "unfinished" }
    XCTAssertFalse(f.editor.save(f.first.id, store: f.store))
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.estimateMinutes, "unfinished")
    XCTAssertEqual(try f.store.task(id: f.first.id)?.title, "First")
    XCTAssertNotNil(f.editor.errors[f.first.id])
    f.editor.flush()
  }

  @MainActor
  func testUndoRefreshesCleanEditorsAndPreservesUnrelatedDirtyFields() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.edit(f.first.id) { $0.title = "Saved rename" }
    XCTAssertTrue(f.editor.save(f.first.id, store: f.store))
    f.editor.edit(f.first.id) { $0.notes = "Unsaved notes" }
    try f.store.undo()
    f.editor.refresh(store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.title, "First")
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.notes, "Unsaved notes")
    XCTAssertTrue(try XCTUnwrap(f.editor.draft(for: f.first.id)).conflicts.isEmpty)
    try f.store.redo()
    f.editor.refresh(store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.title, "Saved rename")
    f.editor.flush()
  }

  @MainActor
  func testStaleSaveReconcilesConflictsBeforeUserCanOverwriteSavedValues() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.edit(f.first.id) { $0.title = "My rename" }
    try f.store.updateTask(id: f.first.id, title: "Saved rename", notes: "", dueAt: nil, estimateSeconds: nil)
    XCTAssertFalse(f.editor.save(f.first.id, store: f.store))
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.conflicts, [.title])
    XCTAssertEqual(try f.store.task(id: f.first.id)?.title, "Saved rename")
    f.editor.resolve(f.first.id, field: .title, useSaved: false)
    XCTAssertTrue(f.editor.save(f.first.id, store: f.store))
    XCTAssertEqual(try f.store.task(id: f.first.id)?.title, "My rename")
  }

  @MainActor
  func testMovingDeletingAndUndoingDeletionRetainsDraftIdentityWithoutRecreatingTask() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.edit(f.first.id) { $0.notes = "Keep me" }
    let workspace = try f.store.bootstrapIfNeeded()
    let destination = try f.store.createList(workspaceId: workspace.id, name: "Destination")
    try f.store.moveTask(id: f.first.id, toListId: destination.id)
    f.editor.refresh(store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.values.notes, "Keep me")
    try f.store.deleteTask(id: f.first.id)
    f.editor.refresh(store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.isUnavailable, true)
    f.editor.edit(f.first.id) { $0.notes = "Retained while unavailable" }
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.isUnavailable, true)
    XCTAssertFalse(f.editor.save(f.first.id, store: f.store))
    XCTAssertNil(try f.store.task(id: f.first.id))
    try f.store.undo()
    f.editor.refresh(store: f.store)
    XCTAssertEqual(f.editor.draft(for: f.first.id)?.isUnavailable, false)
    XCTAssertNil(f.editor.errors[f.first.id])
    XCTAssertTrue(f.editor.save(f.first.id, store: f.store))
    XCTAssertEqual(try f.store.task(id: f.first.id)?.notes, "Retained while unavailable")
    XCTAssertEqual(try f.store.task(id: f.first.id)?.listId, destination.id)
  }

  @MainActor
  func testUnreadableDraftFileIsReportedAndNeverOverwrittenByNewEdits() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let corrupt = Data("recoverable damaged file".utf8)
    try corrupt.write(to: f.draftsURL)
    let editor = WorkspaceTaskEditor(fileURL: f.draftsURL)
    editor.open(f.first.id, store: f.store)
    editor.edit(f.first.id) { $0.notes = "In memory" }
    editor.flush()
    XCTAssertNotNil(editor.persistenceError)
    XCTAssertEqual(editor.draft(for: f.first.id)?.values.notes, "In memory")
    XCTAssertEqual(try Data(contentsOf: f.draftsURL), corrupt)
  }

  @MainActor
  func testDraftWriteFailureDoesNotReportCommittedTaskSaveAsFailure() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let blocker = f.directory.appendingPathComponent("file-not-directory")
    try Data().write(to: blocker)
    let editor = WorkspaceTaskEditor(fileURL: blocker.appendingPathComponent("drafts.json"))
    editor.open(f.first.id, store: f.store)
    editor.edit(f.first.id) { $0.title = "Committed" }
    XCTAssertTrue(editor.save(f.first.id, store: f.store))
    XCTAssertEqual(try f.store.task(id: f.first.id)?.title, "Committed")
    XCTAssertNotNil(editor.persistenceError)
  }
}


extension WorkspaceTaskEditorTests {
  @MainActor
  func testCleanNavigationDoesNotWriteDraftsAndUnchangedFlushPreservesFile() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    f.editor.open(f.first.id, store: f.store)
    f.editor.open(f.second.id, store: f.store)
    f.editor.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.draftsURL.path))

    f.editor.edit(f.first.id) { $0.notes = "Keep this draft" }
    f.editor.flush()
    let marker = Date(timeIntervalSince1970: 1000)
    try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: f.draftsURL.path)
    for _ in 0..<10 {
      f.editor.open(f.first.id, store: f.store)
      f.editor.open(f.second.id, store: f.store)
      f.editor.flush()
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: f.draftsURL.path)
    XCTAssertEqual(attributes[.modificationDate] as? Date, marker)
    XCTAssertEqual(try TaskEditorDraftStore(fileURL: f.draftsURL).load().first?.values.notes, "Keep this draft")
    f.editor.edit(f.second.id) { $0.title = "New edit" }
    f.editor.flush()
    XCTAssertEqual(try TaskEditorDraftStore(fileURL: f.draftsURL).load().count, 2)
  }
}
