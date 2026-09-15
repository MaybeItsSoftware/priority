import Foundation
import PriorityWorkspace
import XCTest

final class WorkspaceStoreTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testBootstrapCreatesOneWorkspaceAndInbox() throws {
    let workspace = try store.bootstrapIfNeeded()

    XCTAssertEqual(try store.workspaces().map(\.id), [workspace.id])
    XCTAssertEqual(try store.lists(in: workspace.id).map(\.name), ["Inbox"])
    XCTAssertEqual(try store.bootstrapIfNeeded().id, workspace.id)
  }

  func testEverythingShowsVisibleRootsAcrossActiveListsWithoutChangingHierarchy() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    let inboxTask = try store.createTask(listId: inbox.id, title: "Inbox task")
    let work = try store.createList(workspaceId: workspace.id, name: "Work")
    let transportRoot = try store.createTask(listId: work.id, title: "Wörk!!!")
    let workTask = try store.createTask(listId: work.id, title: "Prepare proposal", parentTaskId: transportRoot.id)
    let archived = try store.createList(workspaceId: workspace.id, name: "Archived")
    _ = try store.createTask(listId: archived.id, title: "Old task")
    try store.setListArchived(true, id: archived.id)

    XCTAssertEqual(try store.visibleRootParentTaskID(for: work), transportRoot.id)
    XCTAssertEqual(try store.visibleRootTasks(in: workspace.id).map(\.id), [inboxTask.id, workTask.id])
    XCTAssertEqual(try store.task(id: workTask.id)?.parentTaskId, transportRoot.id)
    XCTAssertEqual(try store.tasks(in: work.id).map(\.id), [transportRoot.id])
  }

  func testOutlineKeepsHierarchyAndCompletingATaskPersists() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let root = try store.createTask(listId: list.id, title: "Project")
    let child = try store.createTask(listId: list.id, title: "First step", parentTaskId: root.id)

    let outline = try store.outline(in: list.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Project", "First step"])
    XCTAssertEqual(outline.map(\.depth), [0, 1])

    try store.setStatus(.completed, for: child.id)
    XCTAssertEqual(try store.task(id: child.id)?.status, .completed)
  }

  func testProjectBoardKeepsChildColumnsIndependentOfTheirParent() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let project = try store.createTask(listId: list.id, title: "Prepare big document")
    let section = try store.createTask(listId: list.id, title: "Section 1", parentTaskId: project.id)

    try store.setKanbanColumn("in-progress", for: project.id)
    try store.setKanbanColumn("today", for: section.id)

    XCTAssertEqual(try store.tasks(in: list.id).map(\.id), [project.id])
    XCTAssertEqual(try store.tasks(in: list.id, parentTaskId: project.id).map(\.id), [section.id])
    XCTAssertEqual(try store.kanbanColumn(for: project.id), "in-progress")
    XCTAssertEqual(try store.kanbanColumn(for: section.id), "today")
  }

  func testMatrixPositionIsLocalMetadataAndDoesNotChangeTaskHierarchy() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let task = try store.createTask(listId: list.id, title: "Plan launch")

    try store.setMatrixPosition(.init(urgency: 1, importance: 1), for: task.id)

    XCTAssertEqual(try store.matrixPosition(for: task.id), .init(urgency: 1, importance: 1))
    XCTAssertEqual(try store.tasks(in: list.id).map(\.id), [task.id])
  }

  func testLegacyImportCreatesSeparateListAndRebuildsParents() throws {
    let workspace = try store.bootstrapIfNeeded()
    let imported = try XCTUnwrap(store.importLegacyTasks(
      workspaceId: workspace.id,
      listName: "Imported from old Priority",
      seeds: [
        .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .completed, sortOrder: 0),
        .init(sourceId: "1", parentSourceId: nil, title: "Parent", status: .open, sortOrder: 0),
      ]))

    let outline = try store.outline(in: imported.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Parent", "Child"])
    XCTAssertEqual(outline.map(\.depth), [0, 1])
    XCTAssertEqual(outline.last?.task.status, .completed)
  }

  func testFocusSessionCompletesCurrentTaskAndAdvancesQueue() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let first = try store.createTask(listId: list.id, title: "Write")
    let second = try store.createTask(listId: list.id, title: "Review")
    let session = try store.startFocusSession(taskId: first.id)
    try store.addToFocusQueue(sessionId: session.id, taskId: second.id)

    let advanced = try store.completeActiveFocusTask(sessionId: session.id)

    XCTAssertEqual(try store.task(id: first.id)?.status, .completed)
    XCTAssertEqual(advanced.outcome, .taskCompleted)
    XCTAssertEqual(advanced.session.activeTaskId, second.id)
    XCTAssertEqual(try store.focusQueue(for: session.id).map(\.item.state), [.completed, .queued])
  }

  func testMoveTaskMovesEntireSubtreeAndRejectsCircularParent() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    let destination = try store.createList(workspaceId: workspace.id, name: "Project")
    let parent = try store.createTask(listId: inbox.id, title: "Parent")
    let child = try store.createTask(listId: inbox.id, title: "Child", parentTaskId: parent.id)
    let grandchild = try store.createTask(listId: inbox.id, title: "Grandchild", parentTaskId: child.id)

    XCTAssertThrowsError(try store.moveTask(id: parent.id, toListId: inbox.id, parentTaskId: grandchild.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .invalidTaskMove)
    }
    try store.moveTask(id: parent.id, toListId: destination.id)

    XCTAssertEqual(try store.outline(in: destination.id).map { $0.task.title }, ["Parent", "Child", "Grandchild"])
    XCTAssertEqual(try store.task(id: child.id)?.listId, destination.id)
    XCTAssertEqual(try store.task(id: grandchild.id)?.listId, destination.id)
    XCTAssertTrue(try store.outline(in: inbox.id).isEmpty)
  }

  func testIndentOutdentAndSiblingOrderingPreserveOutline() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    _ = try store.createTask(listId: list.id, title: "First")
    let second = try store.createTask(listId: list.id, title: "Second")
    let third = try store.createTask(listId: list.id, title: "Third")

    try store.moveTaskWithinSiblings(id: third.id, by: -2)
    XCTAssertEqual(try store.outline(in: list.id).map { $0.task.title }, ["Third", "First", "Second"])
    try store.indentTask(id: second.id)
    XCTAssertEqual(try store.outline(in: list.id).map { $0.task.title }, ["Third", "First", "Second"])
    XCTAssertEqual(try store.outline(in: list.id).map(\.depth), [0, 0, 1])
    try store.outdentTask(id: second.id)
    XCTAssertEqual(try store.outline(in: list.id).map(\.depth), [0, 0, 0])
  }

  func testBoardCaptureAtTopAndCardDropOrderRemainProjectScoped() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let first = try store.createTask(listId: list.id, title: "First")
    let second = try store.createTask(listId: list.id, title: "Second")
    let top = try store.createTask(listId: list.id, title: "New Today task")
    try store.moveTaskToStart(id: top.id)
    XCTAssertEqual(try store.tasks(in: list.id).map(\.id), [top.id, first.id, second.id])

    try store.moveTaskBefore(id: second.id, targetId: first.id)
    XCTAssertEqual(try store.tasks(in: list.id).map(\.id), [top.id, second.id, first.id])

    let child = try store.createTask(listId: list.id, title: "Child", parentTaskId: first.id)
    XCTAssertThrowsError(try store.moveTaskBefore(id: child.id, targetId: top.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .invalidTaskMove)
    }
    XCTAssertEqual(try store.task(id: child.id)?.parentTaskId, first.id)
  }

  func testFolderAndListMovesAreScopedAndDeletingFolderKeepsLists() throws {
    let workspace = try store.bootstrapIfNeeded()
    let top = try store.createFolder(workspaceId: workspace.id, name: "Work")
    let nested = try store.createFolder(workspaceId: workspace.id, name: "Client", parentFolderId: top.id)
    let list = try store.createList(workspaceId: workspace.id, name: "Launch", folderId: nested.id)

    XCTAssertThrowsError(try store.moveFolder(id: top.id, toParentFolderId: nested.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .invalidFolderMove)
    }
    try store.moveList(id: list.id, toFolderId: top.id)
    XCTAssertEqual(try store.lists(in: workspace.id).first(where: { $0.id == list.id })?.folderId, top.id)
    try store.deleteFolder(id: top.id)
    XCTAssertNil(try store.lists(in: workspace.id).first(where: { $0.id == list.id })?.folderId)
  }

  func testListsAndFoldersCanBeReorderedWithinTheirSiblings() throws {
    let workspace = try store.bootstrapIfNeeded()
    let firstFolder = try store.createFolder(workspaceId: workspace.id, name: "First")
    let secondFolder = try store.createFolder(workspaceId: workspace.id, name: "Second")
    try store.moveFolderWithinSiblings(id: secondFolder.id, by: -1)
    XCTAssertEqual(try store.folders(in: workspace.id).map(\.name), ["Second", "First"])

    _ = try XCTUnwrap(store.lists(in: workspace.id).first)
    let project = try store.createList(workspaceId: workspace.id, name: "Project")
    let someday = try store.createList(workspaceId: workspace.id, name: "Someday")
    try store.moveListWithinFolder(id: someday.id, by: -2)
    XCTAssertEqual(try store.lists(in: workspace.id).filter { $0.folderId == nil }.map(\.name), ["Someday", "Inbox", "Project"])

    try store.moveList(id: project.id, toFolderId: firstFolder.id)
    try store.moveListWithinFolder(id: project.id, by: -1)
    XCTAssertEqual(try store.lists(in: workspace.id).first(where: { $0.id == project.id })?.folderId, firstFolder.id)
  }

  func testTaskEditorMetadataNormalizesAndPersistsInspectorFields() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let task = try store.createTask(listId: list.id, title: "Plan launch")

    try store.updateTaskEditorMetadata(
      taskId: task.id,
      metadata: .init(
        priority: 3,
        tags: ["Work", " work ", "Launch", ""],
        recurrenceRule: " every Monday ",
        externalLinks: ["https://example.com/spec", "https://example.com/spec", " "]))

    XCTAssertEqual(
      try store.taskEditorMetadata(for: task.id),
      .init(
        priority: 3,
        tags: ["Work", "Launch"],
        recurrenceRule: "every Monday",
        externalLinks: ["https://example.com/spec"]))
  }
}
