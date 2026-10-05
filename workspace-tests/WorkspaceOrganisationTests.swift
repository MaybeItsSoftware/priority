import Foundation
import TaktWorkspace
import XCTest

final class WorkspaceOrganisationTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var inboxID: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktOrganisationTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    workspaceID = try store.bootstrapIfNeeded().id
    inboxID = try XCTUnwrap(store.inbox(in: workspaceID)).id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directoryURL)
  }

  private func importedList(name: String = "Work", rootTitle: String = "Work") throws -> TaskList {
    try XCTUnwrap(store.importTasks(
      workspaceId: workspaceID, listName: name, sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "root", parentSourceId: nil, title: rootTitle, status: .open, sortOrder: 0),
        .init(sourceId: "child", parentSourceId: "root", title: "Proposal", status: .open, sortOrder: 0),
      ])).list
  }

  func testRenamingEitherSideOfAnImportedWrapperKeepsVisiblePlacementAfterReopenAndUndo() throws {
    let list = try importedList()
    let rootID = try XCTUnwrap(store.visibleRootParentTaskID(for: list))
    let child = try XCTUnwrap(store.tasks(in: list.id, parentTaskId: rootID).first)

    try store.renameList(id: list.id, name: "Clients")
    // Even a stale sidebar record resolves against the current stored identity.
    XCTAssertEqual(try store.visibleRootParentTaskID(for: list), rootID)
    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), [child.id])
    try store.updateTask(id: rootID, title: "Renamed project", notes: "", dueAt: nil, estimateSeconds: nil)
    let reopened = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    XCTAssertEqual(try reopened.visibleRootTasks(in: workspaceID).map(\.id), [child.id])
    try reopened.undo()
    try reopened.undo()
    XCTAssertEqual(try reopened.visibleRootParentTaskID(for: list), rootID)
    XCTAssertEqual(try reopened.task(id: child.id)?.parentTaskId, rootID)
  }

  func testAnOrdinaryTaskWithTheListNameIsVisibleEvenWhenItHasChildren() throws {
    let list = try store.createList(workspaceId: workspaceID, name: "Project")
    let root = try store.createTask(listId: list.id, title: "Project")
    _ = try store.createTask(listId: list.id, title: "Step", parentTaskId: root.id)

    XCTAssertNil(try store.visibleRootParentTaskID(for: list))
    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), [root.id])
  }

  func testWrapperRecognitionPreservesUnicodeAndDoesNotMatchUnrelatedEmojiNames() throws {
    let list = try importedList(name: "仕事", rootTitle: "家庭")
    XCTAssertNil(try store.visibleRootParentTaskID(for: list))
    // Punctuation-only names cannot identify a wrapper.
    let emojiStore = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("emoji.sqlite"))
    let workspace = try emojiStore.bootstrapIfNeeded()
    let emojiList = try XCTUnwrap(emojiStore.importTasks(
      workspaceId: workspace.id, listName: "💼", sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "root", parentSourceId: nil, title: "🏠", status: .open, sortOrder: 0),
        .init(sourceId: "child", parentSourceId: "root", title: "Step", status: .open, sortOrder: 0),
      ])).list
    XCTAssertNil(try emojiStore.visibleRootParentTaskID(for: emojiList))
  }

  func testMovingIntoAnImportedListPlacesTheWholeSubtreeBesideVisibleWorkAndUndoesTogether() throws {
    let destination = try importedList()
    let rootID = try XCTUnwrap(destination.visibleRootTaskId)
    let existing = try XCTUnwrap(store.tasks(in: destination.id, parentTaskId: rootID).first)
    let task = try store.createTask(listId: inboxID, title: "New project")
    let child = try store.createTask(listId: inboxID, title: "Step", parentTaskId: task.id)

    try store.moveTask(id: task.id, toListId: destination.id, toVisibleRoot: true)

    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), [existing.id, task.id])
    XCTAssertEqual(try store.task(id: child.id)?.listId, destination.id)
    XCTAssertEqual(try store.task(id: child.id)?.parentTaskId, task.id)
    XCTAssertEqual(try store.undo(), "Move Task")
    XCTAssertEqual(try store.task(id: task.id)?.listId, inboxID)
    XCTAssertNil(try store.task(id: task.id)?.parentTaskId)
    XCTAssertEqual(try store.task(id: child.id)?.listId, inboxID)
  }

  func testPromotingAChildOrMovingTheWrapperNeverHidesOtherRoots() throws {
    let list = try importedList()
    let rootID = try XCTUnwrap(list.visibleRootTaskId)
    let child = try XCTUnwrap(store.tasks(in: list.id, parentTaskId: rootID).first)
    try store.outdentTask(id: child.id)
    XCTAssertNil(try store.visibleRootParentTaskID(for: list))
    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), [rootID, child.id])
    try store.undo()
    try store.moveTask(id: rootID, toListId: inboxID)
    XCTAssertNil(try store.visibleRootParentTaskID(for: list))
    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), [rootID])
  }

  func testDeletingAndRestoringAnImportedListRestoresItsWrapperIdentity() throws {
    let list = try importedList()
    let rootID = try XCTUnwrap(list.visibleRootTaskId)
    let visibleIDs = try store.visibleRootTasks(in: workspaceID).map(\.id)
    try store.deleteList(id: list.id)
    try store.undo()
    XCTAssertEqual(try store.visibleRootParentTaskID(for: list), rootID)
    XCTAssertEqual(try store.visibleRootTasks(in: workspaceID).map(\.id), visibleIDs)
  }

  func testNoOpReorderRenameAndMovePreserveRedoAndPosition() throws {
    let task = try store.createTask(listId: inboxID, title: "First")
    try store.updateTask(id: task.id, title: "Renamed", notes: "", dueAt: nil, estimateSeconds: nil)
    try store.undo()

    try store.moveTaskWithinSiblings(id: task.id, by: -1)
    try store.moveTask(id: task.id, toListId: inboxID)
    try store.renameList(id: inboxID, name: "  Inbox  ")
    try store.moveList(id: inboxID, toFolderId: nil)

    XCTAssertEqual(try store.redoableLabel(), "Edit Task")
    XCTAssertEqual(try store.redo(), "Edit Task")
    XCTAssertEqual(try store.task(id: task.id)?.title, "Renamed")
  }

  func testRenamingAListRefiledByFolderDeletionDoesNotReorderTheSidebar() throws {
    let folder = try store.createFolder(workspaceId: workspaceID, name: "Folder")
    let list = try store.createList(workspaceId: workspaceID, name: "AAA", folderId: folder.id)
    try store.deleteFolder(id: folder.id)
    // Both the released list and Inbox have sortOrder 0. Their names must not
    // become the tie breaker when the released list is renamed.
    let before = try store.lists(in: workspaceID).map(\.id)
    try store.renameList(id: list.id, name: "ZZZ")
    XCTAssertEqual(try store.lists(in: workspaceID).map(\.id), before)
    try store.moveListWithinFolder(id: list.id, by: -1)
    XCTAssertEqual(try store.lists(in: workspaceID).map(\.id), [list.id, inboxID])
  }
}
