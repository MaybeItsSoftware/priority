import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// The store's face of the core's filter lists: the rows, their undo, the
/// rules crossing both ways, and the scope the desktop draws one through.
final class WorkspaceFilterListTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var workspace: Workspace!
  private var inbox: TaskList!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktFilterListTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    workspace = try store.bootstrapIfNeeded()
    inbox = try XCTUnwrap(store.lists(in: workspace.id).first)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  private func tagRule(_ tag: String) -> WorkspaceFilterDefinition {
    WorkspaceFilterDefinition(rules: [WorkspaceFilterRule(field: "tag", op: "has", value: tag)])
  }

  func testCreatingEditingAndDeletingAreUndoable() throws {
    let made = try store.createFilterList(
      in: workspace.id, name: "  Work  ", icon: "briefcase", definition: tagRule("#Work"))
    XCTAssertEqual(made.name, "Work")
    XCTAssertEqual(made.definition.rules.first?.value, "work", "saved tidied: no hash, lower case")
    XCTAssertEqual(try store.filterLists(in: workspace.id).map(\.id), [made.id])

    try store.updateFilterList(
      made.id, name: "Work soon", icon: nil,
      definition: WorkspaceFilterDefinition(match: .any, show: .all, rules: made.definition.rules))
    let edited = try XCTUnwrap(store.filterList(id: made.id))
    XCTAssertEqual(edited.name, "Work soon")
    XCTAssertNil(edited.icon)
    XCTAssertEqual(edited.definition.match, .any)
    XCTAssertEqual(edited.definition.show, .all)

    try store.deleteFilterList(made.id)
    XCTAssertTrue(try store.filterLists(in: workspace.id).isEmpty)
    XCTAssertEqual(try store.undo(), "Delete Filter List")
    XCTAssertEqual(try store.filterLists(in: workspace.id).first?.name, "Work soon")
  }

  func testARuleTheCoreCannotEvaluateIsRefusedWithItsReason() throws {
    let bad = WorkspaceFilterDefinition(rules: [WorkspaceFilterRule(field: "due", op: "within", value: "soon")])
    XCTAssertThrowsError(try store.createFilterList(in: workspace.id, name: "Soon", icon: nil, definition: bad)) {
      guard case .invalidFilter(let detail) = $0 as? WorkspaceStoreError else {
        return XCTFail("expected invalidFilter, got \($0)")
      }
      XCTAssertTrue(detail.contains("whole number"), detail)
    }
    XCTAssertThrowsError(try bad.validated())
    XCTAssertTrue(try store.filterLists(in: workspace.id).isEmpty)
  }

  func testTheDefinitionRoundTripsThroughItsJSONAndReadsAsASentence() throws {
    let definition = WorkspaceFilterDefinition(
      match: .any, show: .open,
      rules: [
        WorkspaceFilterRule(field: "tag", op: "has", value: "work"),
        WorkspaceFilterRule(field: "due", op: "within", value: "7"),
      ])
    XCTAssertEqual(try WorkspaceFilterDefinition(json: definition.json), definition)
    XCTAssertEqual(definition.summary, "Open tasks where tag has work or due date is within 7 days")
    XCTAssertFalse(WorkspaceFilterCatalog.fields.isEmpty)
    XCTAssertEqual(WorkspaceFilterCatalog.op("within", of: "due")?.valueKind, "days")
  }

  func testTheBuiltInsAreTodayAndEverything() {
    XCTAssertEqual(
      WorkspaceFilterList.builtins.map(\.id), [WorkspaceFilterList.todayID, WorkspaceFilterList.everythingID])
    XCTAssertTrue(WorkspaceFilterList.builtins.allSatisfy(\.isBuiltin))
  }

  func testTheTasksAndTheBoardAreTheMatchesAcrossLists() throws {
    let other = try store.createList(workspaceId: workspace.id, name: "Home")
    let tagged = try store.createTask(listId: inbox.id, title: "Report")
    let elsewhere = try store.createTask(listId: other.id, title: "Invoice")
    _ = try store.createTask(listId: other.id, title: "Laundry")
    for task in [tagged, elsewhere] {
      try store.updateTaskEditorMetadata(taskId: task.id, metadata: .init(tags: ["Work"]))
    }
    let definition = tagRule("work")

    XCTAssertEqual(
      Set(try store.filterListTasks(definition, in: workspace.id).map(\.id)), [tagged.id, elsewhere.id])

    let filter = try store.createFilterList(in: workspace.id, name: "Work", icon: nil, definition: definition)
    let read = try store.scopeRead(.filter(filter.id, [inbox.id, other.id]), hidingCompletedBefore: nil)
    guard case .combined(let board) = read else { return XCTFail("a filter list reads as a combined board") }
    XCTAssertEqual(board.cards.map(\.id), [tagged.id, elsewhere.id])
    XCTAssertTrue(WorkspaceScope.filter(filter.id, []).isCombined)
    XCTAssertEqual(WorkspaceScope.filter(filter.id, [inbox.id]).listIDs, [inbox.id])
  }
}
