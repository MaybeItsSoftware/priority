import Foundation
@testable import PriorityWorkspace
import GRDB
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

  func testCompletionTimeIsStampedOnceAndClearedOnReopening() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    let task = try store.createTask(listId: inbox.id, title: "Write it up")
    let monday = Date(timeIntervalSince1970: 1_758_542_400)
    let tuesday = monday.addingTimeInterval(86_400)

    try store.setStatus(.completed, for: task.id, now: monday)
    XCTAssertEqual(try store.task(id: task.id)?.completedAt, monday)

    // Closing an already-closed task must not move the day it was finished on.
    try store.setStatus(.completed, for: task.id, now: tuesday)
    XCTAssertEqual(try store.task(id: task.id)?.completedAt, monday)

    try store.setStatus(.open, for: task.id, now: tuesday)
    XCTAssertNil(try store.task(id: task.id)?.completedAt)
  }

  func testWorkProgressSeparatesTodayFromTheWeekAndIgnoresLists() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    // Wednesday 2025-09-24, mid-afternoon.
    let now = Date(timeIntervalSince1970: 1_758_726_000)
    let yesterday = now.addingTimeInterval(-86_400)

    let today = try store.createTask(listId: inbox.id, title: "Today's task")
    let earlier = try store.createTask(listId: inbox.id, title: "Monday's task")
    try store.setStatus(.completed, for: today.id, now: now)
    try store.setStatus(.completed, for: earlier.id, now: yesterday)
    // A list closing is bookkeeping, not a unit of work.
    let project = try store.createList(workspaceId: workspace.id, name: "Project")
    try store.setListCompleted(true, id: project.id, now: now)

    let progress = try store.workProgress(now: now, calendar: calendar)
    XCTAssertEqual(progress.today.completed, 1)
    XCTAssertEqual(progress.week.completed, 2)
    XCTAssertEqual(progress.elapsedDays, 3)
  }

  func testCompletingAPeriodicTaskSchedulesTheNextOccurrence() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    // Wednesday 2025-09-24, 09:00 UTC.
    let wednesday = Date(timeIntervalSince1970: 1_758_704_400)
    let task = try store.createTask(
      listId: inbox.id, title: "Water the plants", kanbanColumn: "today", startAt: wednesday)
    try store.updateTaskEditorMetadata(
      taskId: task.id, metadata: TaskEditorMetadata(recurrenceRule: "every 3 days"))

    try store.setStatus(.completed, for: task.id, now: wednesday)

    // The occurrence you did stays done, so it counts towards the day.
    let finished = try XCTUnwrap(store.task(id: task.id))
    XCTAssertEqual(finished.status, .completed)
    XCTAssertEqual(finished.completedAt, wednesday)

    let repeated = try XCTUnwrap(
      store.tasks(in: inbox.id).first { $0.id != task.id && $0.title == "Water the plants" })
    XCTAssertEqual(repeated.status, .open)
    XCTAssertNil(repeated.completedAt)
    XCTAssertEqual(try store.startAt(for: repeated.id), wednesday.addingTimeInterval(3 * 86_400))
    XCTAssertEqual(try store.periodicSchedule(for: repeated.id)?.cadence, .days(3))
    // It arrives without a claim on a day nobody has planned yet.
    XCTAssertNil(try store.kanbanColumn(for: repeated.id))
  }

  func testATaskWithoutARuleIsSimplyCompleted() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    let task = try store.createTask(listId: inbox.id, title: "One-off")

    try store.setStatus(.completed, for: task.id)

    XCTAssertEqual(try store.tasks(in: inbox.id).map(\.id), [task.id])
  }

  func testEverythingShowsVisibleRootsAcrossActiveListsWithoutChangingHierarchy() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
    let inboxTask = try store.createTask(listId: inbox.id, title: "Inbox task")
    let imported = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "Work", sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "root", parentSourceId: nil, title: "Wörk!!!", status: .open, sortOrder: 0),
        .init(sourceId: "child", parentSourceId: "root", title: "Prepare proposal", status: .open, sortOrder: 0),
      ]))
    let work = imported.list
    let transportRoot = try XCTUnwrap(store.tasks(in: work.id).first)
    let workTask = try XCTUnwrap(store.tasks(in: work.id, parentTaskId: transportRoot.id).first)
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
    let imported = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id,
      listName: "Imported from old Priority",
      sourceSystem: "priority-offline",
      seeds: [
        .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .completed, sortOrder: 0),
        .init(sourceId: "1", parentSourceId: nil, title: "Parent", status: .open, sortOrder: 0),
      ]))

    let outline = try store.outline(in: imported.list.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Parent", "Child"])
    XCTAssertEqual(outline.map(\.depth), [0, 1])
    XCTAssertEqual(outline.last?.task.status, .completed)
    XCTAssertTrue(imported.createdList)
    XCTAssertEqual(imported.insertedCount, 2)
  }

  func testRepeatedImportUpdatesTheSameTasksInsteadOfCopyingThem() throws {
    let workspace = try store.bootstrapIfNeeded()
    let first = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "Imported", sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "1", parentSourceId: nil, title: "Parent", status: .open, sortOrder: 0),
        .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .open, sortOrder: 0),
      ]))

    let second = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "Imported", sourceSystem: "checkvist",
      seeds: [
        .init(sourceId: "1", parentSourceId: nil, title: "Parent renamed", status: .open, sortOrder: 0),
        .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .completed, sortOrder: 0),
        .init(sourceId: "3", parentSourceId: "1", title: "Added later", status: .open, sortOrder: 1),
      ]))

    XCTAssertFalse(second.createdList)
    XCTAssertEqual(second.list.id, first.list.id)
    XCTAssertEqual(second.insertedCount, 1)
    XCTAssertEqual(second.updatedCount, 2)
    XCTAssertEqual(try store.lists(in: workspace.id).count, 2)  // Inbox plus the one imported list
    let outline = try store.outline(in: first.list.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Parent renamed", "Child", "Added later"])
    XCTAssertEqual(outline.map(\.depth), [0, 1, 1])
    XCTAssertEqual(outline[1].task.status, .completed)
  }

  /// The same source in two systems is two different tasks, so the unique
  /// index has to be on the pair rather than on the id alone.
  func testSameSourceIDInADifferentSystemImportsSeparately() throws {
    let workspace = try store.bootstrapIfNeeded()
    let seeds: [ImportedTaskSeed] = [.init(sourceId: "1", parentSourceId: nil, title: "One", status: .open, sortOrder: 0)]

    let checkvist = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "From Checkvist", sourceSystem: "checkvist", seeds: seeds))
    let offline = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "From old Priority", sourceSystem: "priority-offline", seeds: seeds))

    XCTAssertNotEqual(checkvist.list.id, offline.list.id)
    XCTAssertEqual(checkvist.insertedCount, 1)
    XCTAssertEqual(offline.insertedCount, 1)
  }

  /// A re-import must not undo the user's own filing. Content is the source's
  /// to update; placement is not.
  func testRepeatedImportLeavesLocalPlacementAlone() throws {
    let workspace = try store.bootstrapIfNeeded()
    let seeds: [ImportedTaskSeed] = [
      .init(sourceId: "1", parentSourceId: nil, title: "Parent", status: .open, sortOrder: 0),
      .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .open, sortOrder: 0),
    ]
    let imported = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "Imported", sourceSystem: "checkvist", seeds: seeds))
    let child = try XCTUnwrap(try store.outline(in: imported.list.id).last?.task)
    try store.outdentTask(id: child.id)

    _ = try store.importTasks(
      workspaceId: workspace.id, listName: "Imported", sourceSystem: "checkvist", seeds: seeds)

    XCTAssertNil(try store.task(id: child.id)?.parentTaskId)
    XCTAssertEqual(try store.outline(in: imported.list.id).map(\.depth), [0, 0])
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

  func testAdvancingTheQueueRestartsTheBlockClockSoTheNextTaskIsNotCreditedTheFirstsSitting() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let first = try store.createTask(listId: list.id, title: "Write")
    let second = try store.createTask(listId: list.id, title: "Review")
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = try store.startFocusSession(taskId: first.id, now: start)
    try store.addToFocusQueue(sessionId: session.id, taskId: second.id, now: start)

    XCTAssertEqual(session.activeTaskStartedAt, start)

    let handover = start.addingTimeInterval(30 * 60)
    let advanced = try store.completeActiveFocusTask(sessionId: session.id, now: handover)

    // The session still began half an hour ago; the second task's block did not.
    XCTAssertEqual(advanced.session.startedAt, start)
    XCTAssertEqual(advanced.session.activeTaskStartedAt, handover)
  }

  func testRenamingAListKeepsItsColourAndIsUndoableOnItsOwn() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try store.createList(workspaceId: workspace.id, name: "Wrk")
    try store.updateList(id: list.id, name: "Wrk", colorHex: "#7a4de8")

    try store.renameList(id: list.id, name: "  Work  ")

    let renamed = try XCTUnwrap(store.lists(in: workspace.id).first { $0.id == list.id })
    XCTAssertEqual(renamed.name, "Work")
    XCTAssertEqual(renamed.colorHex, "#7a4de8")
    XCTAssertEqual(try store.undoableLabel(), "Rename List")

    XCTAssertEqual(try store.undo(), "Rename List")
    XCTAssertEqual(try store.lists(in: workspace.id).first { $0.id == list.id }?.name, "Wrk")
  }

  func testRenamingRefusesAnEmptyNameAndRenamingTheInboxIsAllowed() throws {
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))

    XCTAssertThrowsError(try store.renameList(id: inbox.id, name: "   ")) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .emptyName)
    }
    // Renaming the Inbox is fine; it is found by its role, not its name.
    try store.renameList(id: inbox.id, name: "Capture")

    XCTAssertEqual(try store.inbox(in: workspace.id)?.name, "Capture")
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

  func testDroppingAListPlacesItWhereItLandedAcrossFolders() throws {
    let workspace = try store.bootstrapIfNeeded()
    let folder = try store.createFolder(workspaceId: workspace.id, name: "Work")
    let project = try store.createList(workspaceId: workspace.id, name: "Project")
    let someday = try store.createList(workspaceId: workspace.id, name: "Someday")

    // Dropped above the Inbox at the top level.
    let inbox = try XCTUnwrap(store.lists(in: workspace.id).first { $0.systemRole == .inbox })
    try store.placeList(id: someday.id, before: inbox.id, inFolderId: nil)
    XCTAssertEqual(
      try store.lists(in: workspace.id).filter { $0.folderId == nil }.map(\.name),
      ["Someday", "Inbox", "Project"])

    // A drop with no row below it means the end of the group.
    try store.placeList(id: someday.id, before: nil, inFolderId: nil)
    XCTAssertEqual(
      try store.lists(in: workspace.id).filter { $0.folderId == nil }.map(\.name),
      ["Inbox", "Project", "Someday"])

    // Crossing into a folder moves and places in one step.
    try store.placeList(id: project.id, before: nil, inFolderId: folder.id)
    XCTAssertEqual(try store.lists(in: workspace.id).first { $0.id == project.id }?.folderId, folder.id)
    XCTAssertEqual(
      try store.lists(in: workspace.id).filter { $0.folderId == nil }.map(\.name),
      ["Inbox", "Someday"])
  }

  func testDroppingAFolderPlacesItAndRefusesItsOwnDescendant() throws {
    let workspace = try store.bootstrapIfNeeded()
    let first = try store.createFolder(workspaceId: workspace.id, name: "First")
    let second = try store.createFolder(workspaceId: workspace.id, name: "Second")
    let child = try store.createFolder(workspaceId: workspace.id, name: "Child", parentFolderId: first.id)

    try store.placeFolder(id: second.id, before: first.id, inParentFolderId: nil)
    XCTAssertEqual(
      try store.folders(in: workspace.id).filter { $0.parentFolderId == nil }.map(\.name),
      ["Second", "First"])

    XCTAssertThrowsError(try store.placeFolder(id: first.id, before: nil, inParentFolderId: child.id)) {
      XCTAssertEqual($0 as? WorkspaceStoreError, .invalidFolderMove)
    }
    XCTAssertEqual(try store.folders(in: workspace.id).first { $0.id == first.id }?.parentFolderId, nil)
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


extension WorkspaceStoreTests {
  func testBatchedBoardMetadataMatchesIndividualReadsAcrossBatchBoundaries() throws {
    let workspace = try store.bootstrapIfNeeded()
    let outcome = try XCTUnwrap(store.importTasks(
      workspaceId: workspace.id, listName: "Large board", sourceSystem: "performance-test",
      seeds: (0..<1200).map {
        ImportedTaskSeed(sourceId: "task-\($0)", parentSourceId: nil,
                         title: "Task \($0)", status: .open, sortOrder: $0)
      }))
    let ids = outcome.insertedTaskIDs
    try store.database.write { db in
      for (index, id) in ids.enumerated() where index % 3 != 0 {
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON,
            matrixUrgency, matrixImportance, kanbanColumn, updatedAt)
          VALUES (?, '[]', '[]', ?, ?, ?, ?)
          """, arguments: [id, index % 100, (index * 7) % 100,
                             index.isMultiple(of: 2) ? "today" : nil, Date.now])
      }
    }
    let clock = ContinuousClock()
    let individualStart = clock.now
    var expectedColumns: [String: String] = [:]
    var expectedPositions: [String: TaskMatrixPosition] = [:]
    for id in ids {
      expectedColumns[id] = try store.kanbanColumn(for: id)
      expectedPositions[id] = try store.matrixPosition(for: id)
    }
    let individualTime = individualStart.duration(to: clock.now)
    let batchStart = clock.now
    let metadata = try store.boardMetadata(for: ids + [ids[0]])
    let batchTime = batchStart.duration(to: clock.now)
    XCTAssertEqual(metadata.columns, expectedColumns)
    XCTAssertEqual(metadata.positions, expectedPositions)
    print("Board metadata, 1200 tasks: individual=\(individualTime), batched=\(batchTime)")

    let empty = try store.boardMetadata(for: [])
    XCTAssertTrue(empty.columns.isEmpty)
    XCTAssertTrue(empty.positions.isEmpty)
    try store.setKanbanColumn("later", for: ids[0])
    XCTAssertEqual(try store.boardMetadata(for: [ids[0]]).columns[ids[0]], "later")
    _ = try store.undo()
    XCTAssertNil(try store.boardMetadata(for: [ids[0]]).columns[ids[0]])
  }
}


extension WorkspaceStoreTests {
  func testBulkColumnMovePreservesMetadataAndIsOneAtomicUndoStep() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.inbox(in: workspace.id))
    let first = try store.createTask(listId: list.id, title: "First")
    let second = try store.createTask(listId: list.id, title: "Second")
    let position = TaskMatrixPosition(urgency: 25, importance: 80)
    try store.setMatrixPosition(position, for: first.id)
    try store.setKanbanColumn("today", for: first.id)
    try store.setKanbanColumn("later", for: [first.id, second.id, first.id])
    XCTAssertEqual(try store.kanbanColumn(for: first.id), "later")
    XCTAssertEqual(try store.kanbanColumn(for: second.id), "later")
    XCTAssertEqual(try store.matrixPosition(for: first.id), position)
    _ = try store.undo()
    XCTAssertEqual(try store.kanbanColumn(for: first.id), "today")
    XCTAssertNil(try store.kanbanColumn(for: second.id))
    _ = try store.redo()
    XCTAssertEqual(try store.kanbanColumn(for: second.id), "later")
    XCTAssertThrowsError(try store.setKanbanColumn("done", for: [first.id, "missing"]))
    XCTAssertEqual(try store.kanbanColumn(for: first.id), "later")
    XCTAssertEqual(try store.matrixPosition(for: first.id), position)
  }
}
