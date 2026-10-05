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

  func testASubtaskFiledInAnotherColumnShowsThereAsItsOwnCard() async throws {
    let parent = try XCTUnwrap(model.createTask("Parent", listID: list.id))
    let child = try XCTUnwrap(model.createTask("Child", listID: list.id, parentTaskID: parent.id))
    model.perform { try $0.setKanbanColumn("in-progress", for: child.id) }
    let board = await board()
    let card = try XCTUnwrap(board.cards(in: "in-progress").first)
    XCTAssertEqual(card.id, child.id)
    XCTAssertEqual(card.parentTitle, "Parent")
  }

  func testAddingRenamingAndRemovingColumns() async throws {
    let task = try XCTUnwrap(model.createTask("Card", listID: list.id))
    var board = await board()
    let column = try XCTUnwrap(board.addColumn(named: "Blocked!", model: model))
    XCTAssertEqual(column.id, "blocked")
    XCTAssertEqual(BoardModel.uniqueColumnID(base: "blocked", in: board.columns), "blocked-2")
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

  func testMatrixCellsRoundTripTheirPositions() {
    for cell in MatrixCell.allCases {
      XCTAssertEqual(MatrixCell(cell.position), cell)
    }
    XCTAssertNil(MatrixCell(TaskMatrixPosition(urgency: nil, importance: 1)))
  }
}
