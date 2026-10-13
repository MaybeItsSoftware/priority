import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

@MainActor
final class BoardMatrixModelTests: XCTestCase {
  private var model: WorkspaceModel!
  private var list: TaskList!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    list = try XCTUnwrap(model.createList(named: "Board \(UUID().uuidString)"))
    model.reloadStructureNow()
  }

  private func board() async -> BoardModel {
    let board = BoardModel(scope: .list(list.id))
    await board.load(model)
    return board
  }

  func testUnfiledCardsLandInTheFirstColumnAndSubtasksRideAlong() async throws {
    let parent = try XCTUnwrap(model.createTask("Parent", listID: list.id))
    _ = model.createTask("Child", listID: list.id, parentTaskID: parent.id)
    let board = await board()
    XCTAssertEqual(board.columns, WorkspaceKanbanColumn.blitzitDefaults)
    let first = board.cards(in: "backlog")
    XCTAssertEqual(first.map(\.title), ["Parent"])
    XCTAssertEqual(first.first?.subtasks.map(\.task.title), ["Child"])
  }

  func testMovingACardChangesItsColumnAndUndoesInOneStep() async throws {
    let task = try XCTUnwrap(model.createTask("Card", listID: list.id))
    var board = await board()
    board.move(task.id, toColumn: "today", model: model)
    XCTAssertEqual(board.snapshot.column(ofCard: task.id)?.id, "today")
    board = await self.board()
    XCTAssertEqual(board.cards(in: "today").map(\.id), [task.id])
    XCTAssertTrue(board.cards(in: "today").first?.isPlanned == true)
    model.undo()
    board = await self.board()
    XCTAssertEqual(board.cards(in: "backlog").map(\.id), [task.id])
  }

  func testARuleColumnHoldsTheCardsItsRulesMatch() async throws {
    let tagged = try XCTUnwrap(model.createTask("Tagged", listID: list.id))
    _ = model.createTask("Plain", listID: list.id)
    let rules = WorkspaceFilterDefinition(show: .all, rules: [WorkspaceFilterRule(field: "tag", op: "has", value: "ship")])
    let key = ListScope.list(list.id).boardKey
    model.perform {
      try $0.setKanbanBoardColumns(
        WorkspaceKanbanColumn.blitzitDefaults + [WorkspaceKanbanColumn(id: "ship", title: "Ship", rules: rules)],
        for: key)
      try $0.moveToBoardColumn(key: key, taskIDs: [tagged.id], columnID: "ship")
    }
    let board = await board()
    XCTAssertEqual(board.cards(in: "ship").map(\.title), ["Tagged"])
    XCTAssertEqual(board.cards(in: "backlog").map(\.title), ["Plain"])
  }

  func testEnteringACardHidesTheColumnsBeforeItsOwnAndDrawsItsChildrenThere() async throws {
    let week = try XCTUnwrap(model.createTask("Week 1", listID: list.id))
    let drill = try XCTUnwrap(model.createTask("Drill", listID: list.id, parentTaskID: week.id))
    model.perform { try $0.setKanbanColumn("this-week", for: week.id) }
    let entered = BoardModel(scope: .nested(listID: list.id, taskID: week.id))
    await entered.load(model)
    XCTAssertEqual(entered.columns.map(\.id), ["this-week", "waiting-on", "today"])
    XCTAssertEqual(entered.cards(in: "this-week").map(\.id), [drill.id])
    // Drawn there, not refiled: leaving the card changes nothing.
    XCTAssertNil(try model.store.kanbanColumn(for: drill.id))
  }

  func testASubtaskFiledInAnotherColumnShowsThereAsItsOwnCard() async throws {
    let parent = try XCTUnwrap(model.createTask("Parent", listID: list.id))
    let child = try XCTUnwrap(model.createTask("Child", listID: list.id, parentTaskID: parent.id))
    model.perform { try $0.setKanbanColumn("in-progress", for: child.id) }
    let board = await board()
    let card = try XCTUnwrap(board.cards(in: "in-progress").first)
    XCTAssertEqual(card.id, child.id)
    XCTAssertEqual(card.parentTitle, "Parent")
  }

  func testEverythingsBoardIsWalkedInTheCoreAndHidesFinishedRowsWhenAsked() async throws {
    let parent = try XCTUnwrap(model.createTask("Parent", listID: list.id))
    let child = try XCTUnwrap(model.createTask("Child", listID: list.id, parentTaskID: parent.id))
    let done = try XCTUnwrap(model.createTask("Done", listID: list.id, parentTaskID: parent.id))
    model.perform { try $0.setKanbanColumn("in-progress", for: child.id) }
    model.perform { try $0.setStatus(.completed, for: done.id) }
    model.reloadStructureNow()
    let structure = model.structure

    let shown = try BoardSnapshot.load(
      store: model.store, workspaceID: model.workspace.id, scope: .everything, structure: structure,
      hidesCompleted: false)
    let card = try XCTUnwrap(shown.allCards.first { $0.id == parent.id })
    XCTAssertEqual(card.listName, list.name)
    XCTAssertEqual(card.subtasks.map(\.task.title), ["Child", "Done"])
    // Everything's cards are every doable task, so the subtask is a card of
    // its own in the column it is filed in.
    XCTAssertEqual(shown.column(ofCard: child.id)?.id, "in-progress")

    let hidden = try BoardSnapshot.load(
      store: model.store, workspaceID: model.workspace.id, scope: .everything, structure: structure,
      hidesCompleted: true)
    XCTAssertEqual(hidden.allCards.first { $0.id == parent.id }?.subtasks.map(\.task.title), ["Child"])
  }

  func testAddingRenamingAndRemovingColumns() async throws {
    let task = try XCTUnwrap(model.createTask("Card", listID: list.id))
    var board = await board()
    let column = try XCTUnwrap(board.addColumn(named: "Blocked!", model: model))
    XCTAssertEqual(column.id, "blocked")
    XCTAssertEqual(WorkspaceKanbanColumn.newID(title: "Blocked", among: board.columns), "blocked-2")
    board.renameColumn("blocked", to: "Stuck", model: model)
    board.move(task.id, toColumn: "blocked", model: model)
    board = await self.board()
    XCTAssertEqual(board.columns.last?.title, "Stuck")
    board.removeColumn("blocked", model: model)
    board = await self.board()
    XCTAssertFalse(board.columns.contains { $0.id == "blocked" })
    XCTAssertEqual(board.cards(in: "backlog").map(\.id), [task.id])
  }

  func testAddingACardFilesItInTheColumn() async throws {
    let board = await board()
    let created = try XCTUnwrap(board.addCard("New thing 30m", toColumn: "this-week", model: model))
    XCTAssertEqual(created.estimateSeconds, 1_800)
    await board.load(model)
    XCTAssertEqual(board.cards(in: "this-week").map(\.title), ["New thing"])
  }

  func testFoldingACardHidesItsSubtaskRows() async throws {
    let parent = try XCTUnwrap(model.createTask("Parent", listID: list.id))
    let child = try XCTUnwrap(model.createTask("Child", listID: list.id, parentTaskID: parent.id))
    _ = model.createTask("Grandchild", listID: list.id, parentTaskID: child.id)
    let board = await board()
    board.folded = []
    let card = try XCTUnwrap(board.cards(in: "backlog").first)
    XCTAssertEqual(board.subtaskRows(of: card).count, 2)
    board.toggleFold(child.id)
    XCTAssertEqual(board.subtaskRows(of: card).map(\.task.title), ["Child"])
    board.toggleFold(parent.id)
    XCTAssertTrue(board.subtaskRows(of: card).isEmpty)
    board.folded = []
  }

  func testPlacingInTheMatrix() async throws {
    let task = try XCTUnwrap(model.createTask("Card", listID: list.id))
    let matrix = MatrixModel(scope: .list(list.id))
    await matrix.load(model)
    XCTAssertEqual(matrix.unplaced.map(\.id), [task.id])
    matrix.place(task.id, in: .schedule, model: model)
    XCTAssertEqual(matrix.cell(of: task.id), .schedule)
    await matrix.load(model)
    XCTAssertEqual(matrix.cards(in: .schedule).map(\.id), [task.id])
    XCTAssertEqual(try model.store.matrixPosition(for: task.id), TaskMatrixPosition(urgency: 0, importance: 1))
    matrix.place(task.id, in: nil, model: model)
    await matrix.load(model)
    XCTAssertEqual(matrix.unplaced.map(\.id), [task.id])
  }

  /// The order a quadrant was arranged in on the Mac, ranked first.
  func testAQuadrantReadsInItsRankedOrder() async throws {
    let first = try XCTUnwrap(model.createTask("First", listID: list.id))
    let second = try XCTUnwrap(model.createTask("Second", listID: list.id))
    let third = try XCTUnwrap(model.createTask("Third", listID: list.id))
    for task in [first, second, third] {
      try model.store.setMatrixPosition(MatrixCell.doNow.position, for: task.id)
    }
    try model.store.placeInMatrix(taskId: third.id, urgency: 1, importance: 1, order: [third.id, first.id])
    let matrix = MatrixModel(scope: .list(list.id))
    await matrix.load(model)
    XCTAssertEqual(matrix.cards(in: .doNow).map(\.id), [third.id, first.id, second.id])
    XCTAssertEqual(matrix.cell(of: third.id), .doNow)
  }

  func testMatrixCellsRoundTripTheirPositions() {
    for cell in MatrixCell.allCases {
      XCTAssertEqual(MatrixCell(cell.position), cell)
    }
    XCTAssertNil(MatrixCell(TaskMatrixPosition(urgency: nil, importance: 1)))
  }
}
