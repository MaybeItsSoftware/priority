import Foundation
import GRDB
import PriorityWorkspace
import XCTest

final class WorkspaceUndoTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var listID: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityUndoTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    workspaceID = workspace.id
    listID = try XCTUnwrap(store.inbox(in: workspace.id)).id
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testNothingToUndoOnAFreshWorkspace() throws {
    XCTAssertNil(try store.undoableLabel())
    XCTAssertNil(try store.redoableLabel())
    XCTAssertNil(try store.undo())
  }

  func testUndoTakesBackACreationAndRedoPutsItBack() throws {
    let task = try store.createTask(listId: listID, title: "Write the report")
    XCTAssertEqual(try store.undoableLabel(), "New Task")

    XCTAssertEqual(try store.undo(), "New Task")
    XCTAssertNil(try store.task(id: task.id))
    XCTAssertEqual(try store.redoableLabel(), "New Task")

    XCTAssertEqual(try store.redo(), "New Task")
    XCTAssertEqual(try store.task(id: task.id)?.title, "Write the report")
  }

  func testBoardCreationAtTopIsOneCompleteUndoStep() throws {
    let existing = try store.createTask(listId: listID, title: "Existing")
    let added = try store.createTask(listId: listID, title: "New card", kanbanColumn: "today", atTop: true)
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [added.id, existing.id])
    XCTAssertEqual(try store.undo(), "New Task")
    XCTAssertNil(try store.task(id: added.id))
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [existing.id])
    try store.redo()
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [added.id, existing.id])
    XCTAssertEqual(try store.kanbanColumn(for: added.id), "today")
  }

  func testColumnPlacementAndReorderingUndoTogether() throws {
    let first = try store.createTask(listId: listID, title: "First", kanbanColumn: "backlog")
    let second = try store.createTask(listId: listID, title: "Second", kanbanColumn: "today")
    try store.moveTaskBefore(id: second.id, targetId: first.id, kanbanColumn: "backlog")
    XCTAssertEqual(try store.undo(), "Reorder Task")
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [first.id, second.id])
    XCTAssertEqual(try store.kanbanColumn(for: second.id), "today")
    try store.redo()
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [second.id, first.id])
    XCTAssertEqual(try store.kanbanColumn(for: second.id), "backlog")
  }

  func testBoardHistoryPersistsAndLegacyPreferencesDoNotOverwriteIt() throws {
    let key = "\(listID!)/root"
    let baseline = WorkspaceKanbanColumn.blitzitDefaults
    let legacy = [key: try JSONEncoder().encode(baseline)]
    _ = try store.kanbanBoardConfigurations(legacy: legacy, currentKey: key)
    let custom = baseline + [WorkspaceKanbanColumn(id: "custom", title: "Custom")]
    try store.setKanbanBoardColumns(custom, for: key, label: "Add Board Column")
    let reopened = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    XCTAssertEqual(try reopened.undo(), "Add Board Column")
    let undone = try XCTUnwrap(reopened.kanbanBoardConfigurations(legacy: legacy, currentKey: key)[key])
    XCTAssertEqual(try JSONDecoder().decode([WorkspaceKanbanColumn].self, from: undone), baseline)
    XCTAssertEqual(try reopened.redo(), "Add Board Column")
    let redone = try XCTUnwrap(reopened.kanbanBoardConfigurations(legacy: legacy, currentKey: key)[key])
    XCTAssertEqual(try JSONDecoder().decode([WorkspaceKanbanColumn].self, from: redone), custom)
  }

  func testColumnRemovalAndItsCardsUndoTogether() throws {
    let key = "\(listID!)/root"
    let defaults = WorkspaceKanbanColumn.blitzitDefaults
    _ = try store.kanbanBoardConfigurations(legacy: [:], currentKey: key)
    let card = try store.createTask(listId: listID, title: "Today", kanbanColumn: "today")
    let remaining = defaults.filter { $0.id != "today" }
    try store.setKanbanBoardColumns(remaining, for: key, movingTaskIDs: [card.id], toColumn: "backlog", label: "Remove Board Column")
    XCTAssertEqual(try store.undo(), "Remove Board Column")
    let restored = try XCTUnwrap(store.kanbanBoardConfigurations(legacy: [:], currentKey: key)[key])
    XCTAssertEqual(try JSONDecoder().decode([WorkspaceKanbanColumn].self, from: restored), defaults)
    XCTAssertEqual(try store.kanbanColumn(for: card.id), "today")
    try store.redo()
    let redone = try XCTUnwrap(store.kanbanBoardConfigurations(legacy: [:], currentKey: key)[key])
    XCTAssertEqual(try JSONDecoder().decode([WorkspaceKanbanColumn].self, from: redone), remaining)
    XCTAssertEqual(try store.kanbanColumn(for: card.id), "backlog")
  }

  func testRelativeCreationPreservesSiblingOrderAndUndoesInOneStep() throws {
    let first = try store.createTask(listId: listID, title: "First")
    let last = try store.createTask(listId: listID, title: "Last")
    let middle = try store.createTask(listId: listID, title: "Middle", adjacentTaskId: last.id, above: true)
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [first.id, middle.id, last.id])
    try store.undo()
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [first.id, last.id])
    try store.redo()
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [first.id, middle.id, last.id])
  }

  func testFailedCreationDoesNotLeaveAPartialTaskOrDestroyRedo() throws {
    let first = try store.createTask(listId: listID, title: "First")
    try store.updateTask(id: first.id, title: "Changed", notes: "", dueAt: nil, estimateSeconds: nil)
    try store.undo()
    XCTAssertThrowsError(try store.createTask(listId: listID, title: "Bad", kanbanColumn: "today", adjacentTaskId: "missing"))
    XCTAssertEqual(try store.tasks(in: listID).map(\.id), [first.id])
    XCTAssertEqual(try store.redoableLabel(), "Edit Task")
  }

  func testUndoFocusCompletionReopensWorkWithoutErasingElapsedTime() throws {
    let task = try store.createTask(listId: listID, title: "Focus task")
    let session = try store.startFocusSession(taskId: task.id)
    _ = try store.completeActiveFocusTask(sessionId: session.id, elapsedSeconds: 600)
    XCTAssertEqual(try store.undo(), "Complete Task")
    XCTAssertEqual(try store.task(id: task.id)?.status, .open)
    XCTAssertEqual(try store.workBlocks(for: task.id).map(\.seconds), [600])
    try store.redo()
    XCTAssertEqual(try store.task(id: task.id)?.status, .completed)
    XCTAssertEqual(try store.workBlocks(for: task.id).map(\.seconds), [600])
  }

  func testUndoRestoresAnEditedTitleWithoutTouchingItsSubtree() throws {
    let parent = try store.createTask(listId: listID, title: "Original")
    let child = try store.createTask(listId: listID, title: "Child", parentTaskId: parent.id)
    try store.updateTask(id: parent.id, title: "Renamed", notes: "note", dueAt: nil, estimateSeconds: nil)

    XCTAssertEqual(try store.undo(), "Edit Task")

    XCTAssertEqual(try store.task(id: parent.id)?.title, "Original")
    // The subtree is the real hazard here: restoring a row by replacing it
    // would cascade the children away.
    XCTAssertEqual(try store.task(id: child.id)?.parentTaskId, parent.id)
  }

  func testUndoRestoresADeletedSubtreeWhole() throws {
    let parent = try store.createTask(listId: listID, title: "Parent")
    let child = try store.createTask(listId: listID, title: "Child", parentTaskId: parent.id)
    let grandchild = try store.createTask(listId: listID, title: "Grandchild", parentTaskId: child.id)
    try store.setKanbanColumn("today", for: grandchild.id)

    try store.deleteTask(id: parent.id)
    XCTAssertTrue(try store.outline(in: listID).isEmpty)

    XCTAssertEqual(try store.undo(), "Delete Task")

    XCTAssertEqual(try store.outline(in: listID).map { $0.task.title }, ["Parent", "Child", "Grandchild"])
    XCTAssertEqual(try store.outline(in: listID).map(\.depth), [0, 1, 2])
    // Metadata is cascaded away with the task, so it has to come back too.
    XCTAssertEqual(try store.kanbanColumn(for: grandchild.id), "today")
  }

  func testUndoRestoresADeletedListAndEverythingInIt() throws {
    let list = try store.createList(workspaceId: workspaceID, name: "Project")
    let task = try store.createTask(listId: list.id, title: "Ship it")
    try store.deleteList(id: list.id)

    XCTAssertEqual(try store.undo(), "Delete List")

    XCTAssertEqual(try store.lists(in: workspaceID).map(\.id).contains(list.id), true)
    XCTAssertEqual(try store.task(id: task.id)?.title, "Ship it")
  }

  func testOneOperationIsOneUndoStepHoweverManyRowsItTouched() throws {
    let first = try store.createTask(listId: listID, title: "First")
    let second = try store.createTask(listId: listID, title: "Second")
    let third = try store.createTask(listId: listID, title: "Third")

    // Reordering rewrites the sort order of every sibling in one write.
    try store.moveTaskWithinSiblings(id: third.id, by: -2)
    XCTAssertEqual(try store.outline(in: listID).map { $0.task.title }, ["Third", "First", "Second"])

    XCTAssertEqual(try store.undo(), "Reorder Task")

    XCTAssertEqual(try store.outline(in: listID).map { $0.task.title }, ["First", "Second", "Third"])
    XCTAssertEqual(try store.undoableLabel(), "New Task")
    XCTAssertEqual([first, second, third].count, 3)
  }

  func testUndoingSeveralStepsWalksBackInOrder() throws {
    let task = try store.createTask(listId: listID, title: "One")
    try store.updateTask(id: task.id, title: "Two", notes: "", dueAt: nil, estimateSeconds: nil)
    try store.updateTask(id: task.id, title: "Three", notes: "", dueAt: nil, estimateSeconds: nil)

    try store.undo()
    XCTAssertEqual(try store.task(id: task.id)?.title, "Two")
    try store.undo()
    XCTAssertEqual(try store.task(id: task.id)?.title, "One")
    try store.undo()
    XCTAssertNil(try store.task(id: task.id))
    XCTAssertNil(try store.undo())

    try store.redo()
    XCTAssertEqual(try store.task(id: task.id)?.title, "One")
    try store.redo()
    try store.redo()
    XCTAssertEqual(try store.task(id: task.id)?.title, "Three")
    XCTAssertNil(try store.redo())
  }

  /// A new edit after an undo is a new branch of history — the same rule a text
  /// editor follows, and the one that stops redo putting back something the
  /// user has since worked past.
  func testANewEditAfterAnUndoClearsTheRedoStack() throws {
    let task = try store.createTask(listId: listID, title: "One")
    try store.updateTask(id: task.id, title: "Two", notes: "", dueAt: nil, estimateSeconds: nil)
    try store.undo()
    XCTAssertNotNil(try store.redoableLabel())

    try store.updateTask(id: task.id, title: "Different", notes: "", dueAt: nil, estimateSeconds: nil)

    XCTAssertNil(try store.redoableLabel())
    XCTAssertNil(try store.redo())
    XCTAssertEqual(try store.task(id: task.id)?.title, "Different")
  }

  func testUndoingIsNotItselfAnUndoStep() throws {
    let task = try store.createTask(listId: listID, title: "One")
    try store.updateTask(id: task.id, title: "Two", notes: "", dueAt: nil, estimateSeconds: nil)

    try store.undo()

    // Not "Edit Task" again: the replay must not have been recorded.
    XCTAssertEqual(try store.undoableLabel(), "New Task")
  }

  func testImportingIsNotRecordedAsThousandsOfSteps() throws {
    _ = try store.importTasks(
      workspaceId: workspaceID, listName: "Imported", sourceSystem: "checkvist",
      seeds: (0..<50).map {
        .init(sourceId: "\($0)", parentSourceId: nil, title: "Task \($0)", status: .open, sortOrder: $0)
      })

    XCTAssertNil(try store.undoableLabel())
  }

  func testTheSearchIndexFollowsAnUndo() throws {
    let task = try store.createTask(listId: listID, title: "Findable widget")
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "widget").count, 1)

    try store.undo()
    XCTAssertTrue(try store.searchTasks(in: workspaceID, matching: "widget").isEmpty)

    try store.redo()
    XCTAssertEqual(try store.searchTasks(in: workspaceID, matching: "widget").map(\.task.id), [task.id])
  }

  func testTheJournalDoesNotGrowWithoutBound() throws {
    for index in 0..<140 {
      _ = try store.createTask(listId: listID, title: "Task \(index)")
    }

    let groups = try DatabaseQueue(path: directoryURL.appendingPathComponent("priority.sqlite").path)
      .read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT groupId) FROM change_log") ?? 0
      }
    XCTAssertLessThanOrEqual(groups, 100)
    XCTAssertGreaterThan(groups, 0)
    // Trimming the oldest steps must not break the newest ones.
    XCTAssertEqual(try store.undo(), "New Task")
  }
}
