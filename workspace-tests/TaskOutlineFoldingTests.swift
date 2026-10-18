import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// Folding a branch has to leave exactly the rows the outline draws and the
/// arrow keys walk — the folded task itself, and nothing beneath it.
final class TaskOutlineFoldingTests: XCTestCase {
  private var directory: URL!
  /// project
  ///   step
  ///     detail
  ///   other
  /// solo
  ///
  /// Rows are named by title below, so the assertions read as the tree does.
  private var tree: [TaskOutlineItem] = []

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("Folding-\(UUID().uuidString)")
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
    let workspaceID = try store.bootstrapIfNeeded().id
    let list = try store.createList(workspaceId: workspaceID, name: "Work")
    let project = try store.createTask(listId: list.id, title: "project")
    let step = try store.createTask(listId: list.id, title: "step", parentTaskId: project.id)
    _ = try store.createTask(listId: list.id, title: "detail", parentTaskId: step.id)
    _ = try store.createTask(listId: list.id, title: "other", parentTaskId: project.id)
    _ = try store.createTask(listId: list.id, title: "solo")
    tree = try store.outline(in: list.id)
    XCTAssertEqual(tree.map(\.task.title), ["project", "step", "detail", "other", "solo"])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func id(_ title: String) -> String {
    tree.first { $0.task.title == title }!.id
  }

  private func titles(_ items: [TaskOutlineItem]) -> [String] { items.map(\.task.title) }

  private func folded(_ titles: String...) -> Set<String> { Set(titles.map(id)) }

  func testNothingFoldedDrawsEveryRow() {
    XCTAssertEqual(TaskOutlineFolding.visible(tree, folded: []), tree)
  }

  func testFoldingHidesTheWholeBranchButKeepsTheTask() {
    XCTAssertEqual(titles(TaskOutlineFolding.visible(tree, folded: folded("project"))), ["project", "solo"])
  }

  func testFoldingANestedTaskKeepsItsSiblings() {
    XCTAssertEqual(
      titles(TaskOutlineFolding.visible(tree, folded: folded("step"))), ["project", "step", "other", "solo"])
  }

  func testAFoldBeneathAFoldChangesNothingUntilTheAncestorOpens() {
    XCTAssertEqual(
      titles(TaskOutlineFolding.visible(tree, folded: folded("project", "step"))), ["project", "solo"])
  }

  /// A board card closes the subtree of a subtask that is a card of its own
  /// in another column, as well as its folds: that card draws those rows.
  func testClosingARowLikeAFoldHidesItsSubtreeOnly() {
    let closed = folded("step")
    XCTAssertEqual(
      titles(TaskOutlineFolding.visible(tree) { closed.contains($0) }), ["project", "step", "other", "solo"])
    XCTAssertEqual(titles(TaskOutlineFolding.visible(tree) { _ in false }), titles(tree))
  }

  func testParentsAreTheRowsWithSomethingBeneathThem() {
    XCTAssertEqual(TaskOutlineFolding.parentIDs(tree), folded("project", "step"))
  }

  func testParentAndFirstChild() {
    XCTAssertEqual(TaskOutlineFolding.parentID(of: id("detail"), in: tree), id("step"))
    XCTAssertEqual(TaskOutlineFolding.parentID(of: id("other"), in: tree), id("project"))
    XCTAssertNil(TaskOutlineFolding.parentID(of: id("solo"), in: tree))
    XCTAssertEqual(TaskOutlineFolding.firstChildID(of: id("project"), in: tree), id("step"))
    XCTAssertNil(TaskOutlineFolding.firstChildID(of: id("other"), in: tree))
    XCTAssertNil(TaskOutlineFolding.firstChildID(of: id("solo"), in: tree))
  }

  func testDescendants() {
    XCTAssertEqual(
      TaskOutlineFolding.descendantIDs(of: id("project"), in: tree), ["step", "detail", "other"].map(id))
    XCTAssertEqual(TaskOutlineFolding.descendantIDs(of: id("solo"), in: tree), [])
  }
  /// A list's outline walks as Today's tree does: → opens a folded branch,
  /// then steps in; ← folds it, then steps out; at the top, leaves.
  func testTheOutlineWalksByTodaysRule() {
    let parents = TaskOutlineFolding.parentIDs(tree)
    let shut = folded("step")
    let rows = TaskOutlineFolding.dayOutlineRows(
      TaskOutlineFolding.visible(tree, folded: shut), parents: parents, folded: shut)
    XCTAssertEqual(rows.map(\.id), ["project", "step", "other", "solo"].map(id))
    XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
    XCTAssertEqual(rows.map(\.parentID), [nil, id("project"), id("project"), nil])
    XCTAssertEqual(rows.map(\.hasChildren), [true, true, false, false])
    XCTAssertEqual(rows.map(\.isUnfolded), [true, false, false, false])

    XCTAssertEqual(DayOutline.right(from: id("project"), in: rows), .select(id("step")))
    XCTAssertEqual(DayOutline.right(from: id("step"), in: rows), .unfold(id("step")))
    XCTAssertEqual(DayOutline.right(from: id("solo"), in: rows), .leave)
    XCTAssertEqual(DayOutline.left(from: id("other"), in: rows), .select(id("project")))
    XCTAssertEqual(DayOutline.left(from: id("project"), in: rows), .fold(id("project")))
    XCTAssertEqual(DayOutline.left(from: id("solo"), in: rows), .leave)
  }
}
