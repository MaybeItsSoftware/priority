import Foundation
import TestSQLite
import TaktWorkspace
import XCTest

final class WorkspaceUndoTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var listID: String!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktUndoTests-\(UUID().uuidString)", isDirectory: true)
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

  func testUndoHistoryListsNamedStepsNewestFirstWithUndoneOnTop() throws {
    XCTAssertEqual(try store.undoHistory(limit: 10), [])
    let task = try store.createTask(listId: listID, title: "One")
    try store.updateTask(id: task.id, title: "Two", notes: "", dueAt: nil, estimateSeconds: nil)
    _ = try store.createTask(listId: listID, title: "Three")
    try store.undo()

    let history = try store.undoHistory(limit: 10)
    XCTAssertEqual(history.map(\.label), ["New Task", "Edit Task", "New Task"])
    XCTAssertEqual(history.map(\.isUndone), [true, false, false])
    XCTAssertTrue(history.allSatisfy { $0.changeCount >= 1 })
    XCTAssertEqual(Set(history.map(\.id)).count, 3)

    XCTAssertEqual(try store.undoHistory(limit: 2).map(\.label), ["New Task", "Edit Task"])
    XCTAssertEqual(try store.undoHistory(limit: 0), [])
  }

  /// The agent panel's cards: one step taken back by its id, alone when the
  /// later steps do not depend on it, and with them when one does.
  func testOneStepIsTakenBackByIdAloneOrWithTheStepsThatBuiltOnIt() throws {
    let milk = try store.createTask(listId: listID, title: "Milk")
    let first = try XCTUnwrap(store.undoHistory(limit: 1).first).id
    let eggs = try store.createTask(listId: listID, title: "Eggs")

    let plan = try store.stepUndoPlan(first)
    XCTAssertTrue(plan.isAvailable)
    XCTAssertFalse(plan.isUndone)
    XCTAssertEqual(plan.laterSteps, [])
    XCTAssertEqual(try store.undoStep(first), ["New Task"])
    XCTAssertNil(try store.task(id: milk.id))
    XCTAssertNotNil(try store.task(id: eggs.id), "the later step stands")
    XCTAssertTrue(try store.stepUndoPlan(first).canRedo)
    XCTAssertTrue(try store.redoStep(first))
    XCTAssertNotNil(try store.task(id: milk.id))

    try store.updateTask(id: milk.id, title: "Oat milk", notes: "", dueAt: nil, estimateSeconds: nil)
    XCTAssertEqual(try store.stepUndoPlan(first).laterSteps.map(\.label), ["Edit Task"])
    XCTAssertEqual(try store.undoStep(first), ["Edit Task", "New Task"])
    XCTAssertNil(try store.task(id: milk.id))
    XCTAssertNotNil(try store.task(id: eggs.id), "a later step that did not build on it stands")
    XCTAssertFalse(try store.stepUndoPlan("NOT-A-STEP").isAvailable)
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
    let baseline = [WorkspaceKanbanColumn(id: "todo", title: "To do"), WorkspaceKanbanColumn(id: "done", title: "Done")]
    let legacy = [key: Data(#"[{"id":"todo","title":"To do"},{"id":"done","title":"Done"}]"#.utf8)]
    _ = try store.kanbanBoardConfigurations(legacy: legacy, currentKey: key)
    XCTAssertEqual(try store.boardColumns(key: key, listIDs: [listID]).layout, baseline)
    let custom = baseline + [WorkspaceKanbanColumn(id: "custom", title: "Custom")]
    try store.setKanbanBoardColumns(custom, for: key, label: "Add Board Column")
    let reopened = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    XCTAssertEqual(try reopened.undo(), "Add Board Column")
    _ = try reopened.kanbanBoardConfigurations(legacy: legacy, currentKey: key)
    XCTAssertEqual(try reopened.boardColumns(key: key, listIDs: [listID]).layout, baseline)
    XCTAssertEqual(try reopened.redo(), "Add Board Column")
    XCTAssertEqual(try reopened.boardColumns(key: key, listIDs: [listID]).layout, custom)
  }

  func testDeletingAColumnMovesItsCardsInOneUndoStep() throws {
    let key = "\(listID!)/root"
    let card = try store.createTask(listId: listID, title: "Started", kanbanColumn: "in-progress")
    let before = try store.boardColumns(key: key, listIDs: [listID])
    XCTAssertEqual(before.source, .builtin)
    XCTAssertEqual(before.layout, WorkspaceKanbanColumn.blitzitDefaults)
    try store.deleteBoardColumn(key: key, listIDs: [listID], columnID: "in-progress", toColumn: "this-week")
    let after = try store.boardColumns(key: key, listIDs: [listID])
    XCTAssertEqual(after.source, .own)
    XCTAssertFalse(after.columns.contains { $0.id == "in-progress" })
    XCTAssertEqual(try store.kanbanColumn(for: card.id), "this-week")
    XCTAssertEqual(try store.undo(), "Delete Column")
    XCTAssertEqual(try store.boardColumns(key: key, listIDs: [listID]).source, .builtin)
    XCTAssertEqual(try store.kanbanColumn(for: card.id), "in-progress")
  }

  func testARuleColumnHoldsItsMatchesAndADropEditsTheTask() throws {
    let key = "\(listID!)/root"
    let task = try store.createTask(listId: listID, title: "Ship it")
    let rules = WorkspaceFilterDefinition(rules: [WorkspaceFilterRule(field: "tag", op: "has", value: "ship")])
    let columns = WorkspaceKanbanColumn.blitzitDefaults + [WorkspaceKanbanColumn(id: "ship", title: "Ship", rules: rules)]
    try store.setKanbanBoardColumns(columns, for: key)
    let read = try store.boardColumns(key: key, listIDs: [listID])
    XCTAssertEqual(read.layout.last?.rules?.rules.first?.value, "ship")
    XCTAssertEqual(read.columnID(forTaskID: task.id, filed: nil), "backlog")
    try store.moveToBoardColumn(key: key, taskIDs: [task.id], columnID: "ship")
    XCTAssertEqual(try store.taskEditorMetadata(for: task.id).tags, ["ship"])
    XCTAssertEqual(try store.boardColumns(key: key, listIDs: [listID]).placements[task.id], "ship")
    XCTAssertThrowsError(try store.moveToBoardColumn(key: key, taskIDs: [task.id], columnID: "today")) { error in
      guard case WorkspaceStoreError.columnRefused = error else { return XCTFail("\(error)") }
    }
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
