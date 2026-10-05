import XCTest

@testable import TaktAppLogic

final class TaskNavigationCoordinatorTests: XCTestCase {
  func testNextSiblingIndexWrapsAround() {
    let coord = TaskNavigationCoordinator()
    XCTAssertEqual(coord.nextSiblingIndex(currentSiblingIndex: 0, visibleCount: 3), 1)
    XCTAssertEqual(coord.nextSiblingIndex(currentSiblingIndex: 2, visibleCount: 3), 0)
  }

  func testNextSiblingIndexClampsOutOfRange() {
    let coord = TaskNavigationCoordinator()
    XCTAssertEqual(coord.nextSiblingIndex(currentSiblingIndex: 99, visibleCount: 3), 0)
    XCTAssertEqual(coord.nextSiblingIndex(currentSiblingIndex: -5, visibleCount: 3), 1)
  }

  func testNextSiblingIndexReturnsNilWhenEmpty() {
    let coord = TaskNavigationCoordinator()
    XCTAssertNil(coord.nextSiblingIndex(currentSiblingIndex: 0, visibleCount: 0))
  }

  func testPreviousSiblingIndexWrapsAround() {
    let coord = TaskNavigationCoordinator()
    XCTAssertEqual(coord.previousSiblingIndex(currentSiblingIndex: 0, visibleCount: 3), 2)
    XCTAssertEqual(coord.previousSiblingIndex(currentSiblingIndex: 2, visibleCount: 3), 1)
  }

  func testEnterChildrenReturnsNilWhenNoCurrentTask() {
    let coord = TaskNavigationCoordinator()
    XCTAssertNil(coord.enterChildren(currentTask: nil, childCount: 1))
  }

  func testEnterChildrenReturnsNilWhenZeroChildren() {
    let coord = TaskNavigationCoordinator()
    let task = makeTask(id: 1)
    XCTAssertNil(coord.enterChildren(currentTask: task, childCount: 0))
  }

  func testEnterChildrenSetsParentToCurrentTask() {
    let coord = TaskNavigationCoordinator()
    let task = makeTask(id: 7)
    let selection = coord.enterChildren(currentTask: task, childCount: 3)
    XCTAssertEqual(selection?.currentParentId, 7)
    XCTAssertEqual(selection?.currentSiblingIndex, 0)
  }

  func testExitToParentReturnsNilAtRoot() {
    let coord = TaskNavigationCoordinator()
    XCTAssertNil(coord.exitToParent(currentParentId: 0, tasks: []))
  }

  func testExitToParentResolvesSiblingIndexFromGrandparentLevel() {
    let coord = TaskNavigationCoordinator()
    let tasks = [
      makeTask(id: 1, parentId: nil),
      makeTask(id: 2, parentId: 1),
      makeTask(id: 3, parentId: 1),
    ]
    let selection = coord.exitToParent(currentParentId: 3, tasks: tasks)
    XCTAssertEqual(selection?.currentParentId, 1)
    XCTAssertEqual(selection?.currentSiblingIndex, 1)
  }

  func testExitToParentFallsBackToRootWhenParentMissing() {
    let coord = TaskNavigationCoordinator()
    let selection = coord.exitToParent(currentParentId: 999, tasks: [])
    XCTAssertEqual(selection?.currentParentId, 0)
    XCTAssertEqual(selection?.currentSiblingIndex, 0)
  }

  func testNavigateToTaskFindsSiblingIndex() {
    let coord = TaskNavigationCoordinator()
    let tasks = [
      makeTask(id: 1, parentId: 5),
      makeTask(id: 2, parentId: 5),
      makeTask(id: 3, parentId: 5),
    ]
    let selection = coord.navigate(to: tasks[2], tasks: tasks)
    XCTAssertEqual(selection.currentParentId, 5)
    XCTAssertEqual(selection.currentSiblingIndex, 2)
  }
}
