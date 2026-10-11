import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

/// Filter lists on the phone: they load with the structure, and their scope
/// reads only the tasks the core says match.
@MainActor
final class FilterListScopeTests: XCTestCase {
  private var model: WorkspaceModel!
  private var list: TaskList!
  private var filter: WorkspaceFilterList!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    list = try XCTUnwrap(model.createList(named: "Filtered \(UUID().uuidString)"))
    filter = try model.store.createFilterList(
      in: model.workspace.id, name: "Work", icon: nil,
      definition: WorkspaceFilterDefinition(rules: [WorkspaceFilterRule(field: "text", op: "contains", value: "work")]))
    model.reloadStructureNow()
  }

  func testTheStructureCarriesTheFilterListsAndTheTitleNamesIt() {
    XCTAssertEqual(model.structure.filterLists.map(\.id), [filter.id])
    XCTAssertEqual(model.title(for: .filter(filter.id)), "Work")
    XCTAssertFalse(model.structure.filterLists[0].definition.summary.isEmpty)
    XCTAssertEqual(ListScope.filter(filter.id).boardKey, ListScope.everything.boardKey)
  }

  func testTheOutlineAndBoardShowOnlyTheMatches() throws {
    let match = try XCTUnwrap(model.createTask("Do the work", listID: list.id))
    _ = try XCTUnwrap(model.createTask("Buy milk", listID: list.id))
    let structure = model.structure

    let outline = try OutlineBase.load(
      store: model.store, workspaceID: model.workspace.id, scope: .filter(filter.id), structure: structure,
      hidesCompleted: true)
    XCTAssertEqual(outline.items.map(\.id), [match.id])

    let board = try BoardSnapshot.load(
      store: model.store, workspaceID: model.workspace.id, scope: .filter(filter.id), structure: structure,
      hidesCompleted: true)
    XCTAssertEqual(board.allCards.map(\.id), [match.id])
    XCTAssertEqual(board.allCards.first?.listName, list.name)
  }
}
