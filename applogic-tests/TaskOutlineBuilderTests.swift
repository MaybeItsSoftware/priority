import XCTest

@testable import TaktAppLogic

/// Covers the outline flattening and the right/left decisions that read it.
final class TaskOutlineBuilderTests: XCTestCase {
  // A small tree: 1 has children 10 and 11; 10 has child 100. 2 is childless.
  private let tree: [CheckvistTask] = [
    makeTask(id: 1, content: "one"),
    makeTask(id: 10, content: "one-a", parentId: 1),
    makeTask(id: 100, content: "one-a-i", parentId: 10),
    makeTask(id: 11, content: "one-b", parentId: 1),
    makeTask(id: 2, content: "two"),
  ]

  private func rootRows() -> [CheckvistTask] {
    tree.filter { ($0.parentId ?? 0) == 0 }
  }

  func testNothingExpandedLeavesTheListAlone() {
    let rows = TaskOutlineBuilder.flatten(
      base: rootRows(), tasks: tree, expandedTaskIds: [])
    XCTAssertEqual(rows.map(\.task.id), [1, 2])
    XCTAssertEqual(rows.map(\.depth), [0, 0])
  }

  func testExpandedRowIsFollowedByItsChildrenIndented() {
    let rows = TaskOutlineBuilder.flatten(
      base: rootRows(), tasks: tree, expandedTaskIds: [1])
    XCTAssertEqual(rows.map(\.task.id), [1, 10, 11, 2])
    XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
  }

  func testExpansionNests() {
    let rows = TaskOutlineBuilder.flatten(
      base: rootRows(), tasks: tree, expandedTaskIds: [1, 10])
    XCTAssertEqual(rows.map(\.task.id), [1, 10, 100, 11, 2])
    XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
  }

  func testExpandingSomethingWithoutChildrenChangesNothing() {
    let rows = TaskOutlineBuilder.flatten(
      base: rootRows(), tasks: tree, expandedTaskIds: [2])
    XCTAssertEqual(rows.map(\.task.id), [1, 2])
  }

  /// The filtered tabs list descendants alongside their ancestors. A task must
  /// appear once — under its expanded ancestor — and not twice.
  func testATaskListedAlongsideItsExpandedAncestorIsNotDuplicated() {
    let base = [tree[1], tree[0]]  // child 10 sorted *before* parent 1
    let rows = TaskOutlineBuilder.flatten(base: base, tasks: tree, expandedTaskIds: [1])
    XCTAssertEqual(rows.map(\.task.id), [1, 10, 11])
    XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
  }

  func testChildrenUseTheSuppliedOrder() {
    let rows = TaskOutlineBuilder.flatten(
      base: rootRows(),
      tasks: tree,
      expandedTaskIds: [1],
      sortChildren: { $0.sorted { $0.id > $1.id } }
    )
    XCTAssertEqual(rows.map(\.task.id), [1, 11, 10, 2])
  }

  func testAParentCycleTerminates() {
    // 7 and 8 claim each other as parent — malformed, but it must not hang.
    let cyclic = [
      makeTask(id: 7, parentId: 8),
      makeTask(id: 8, parentId: 7),
    ]
    let rows = TaskOutlineBuilder.flatten(
      base: [cyclic[0]], tasks: cyclic, expandedTaskIds: [7, 8])
    XCTAssertEqual(rows.map(\.task.id), [7, 8])
  }

  // MARK: - Right / left

  private func outlineRows(expanded: Set<Int>) -> [TaskOutlineRow] {
    TaskOutlineBuilder.flatten(base: rootRows(), tasks: tree, expandedTaskIds: expanded)
  }

  private var childCounts: [Int: Int] { [1: 2, 10: 1] }

  func testRightExpandsAShutRow() {
    let outcome = TaskNavigationCoordinator().expandOrDescend(
      selectedIndex: 0,
      rows: outlineRows(expanded: []),
      expandedTaskIds: [],
      childCountByTaskId: childCounts
    )
    XCTAssertEqual(outcome, .expand(taskId: 1))
  }

  func testRightAgainStepsIntoTheFirstChild() {
    let outcome = TaskNavigationCoordinator().expandOrDescend(
      selectedIndex: 0,
      rows: outlineRows(expanded: [1]),
      expandedTaskIds: [1],
      childCountByTaskId: childCounts
    )
    XCTAssertEqual(outcome, .select(index: 1))
  }

  func testRightOnALeafDoesNothing() {
    let outcome = TaskNavigationCoordinator().expandOrDescend(
      selectedIndex: 1,
      rows: outlineRows(expanded: []),
      expandedTaskIds: [],
      childCountByTaskId: childCounts
    )
    XCTAssertEqual(outcome, .none)
  }

  func testLeftShutsAnOpenRow() {
    let outcome = TaskNavigationCoordinator().collapseOrAscend(
      selectedIndex: 0,
      rows: outlineRows(expanded: [1]),
      expandedTaskIds: [1],
      childCountByTaskId: childCounts
    )
    XCTAssertEqual(outcome, .collapse(taskId: 1))
  }

  func testLeftOnAChildGoesUpToItsParentRow() {
    // Rows: 1, 10, 100, 11, 2 — from the deepest child, up to 10 then to 1.
    let rows = outlineRows(expanded: [1, 10])
    let coordinator = TaskNavigationCoordinator()
    XCTAssertEqual(
      coordinator.collapseOrAscend(
        selectedIndex: 2, rows: rows, expandedTaskIds: [1, 10], childCountByTaskId: childCounts),
      .select(index: 1)
    )
    XCTAssertEqual(
      coordinator.collapseOrAscend(
        selectedIndex: 3, rows: rows, expandedTaskIds: [1, 10], childCountByTaskId: childCounts),
      .select(index: 0)
    )
  }

  func testLeftOnAShutTopLevelRowLeavesTheScope() {
    let outcome = TaskNavigationCoordinator().collapseOrAscend(
      selectedIndex: 1,
      rows: outlineRows(expanded: []),
      expandedTaskIds: [],
      childCountByTaskId: childCounts
    )
    XCTAssertEqual(outcome, .exitScope)
  }
}
