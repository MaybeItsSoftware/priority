import XCTest

@testable import TaktCore

/// Five views used to give four different answers to "what am I looking at",
/// two of them implemented privately in their own files, and none of them said
/// which answer it had picked. These pin the single rule they now share.
final class TaskScopeResolverTests: XCTestCase {

  private struct Node: VisibilityTask {
    var id: Int
    var content: String = ""
    var position: Int?
    var parentId: Int?
    var due: String?
    var dueDate: Date? { nil }
    var status: Int = 0
  }

  //  1 ── 2 ── 4
  //    └── 3
  //  5 (a second root)
  private let tasks = [
    Node(id: 1, position: 1, parentId: 0),
    Node(id: 2, position: 1, parentId: 1),
    Node(id: 3, position: 2, parentId: 1),
    Node(id: 4, position: 1, parentId: 2),
    Node(id: 5, position: 2, parentId: 0),
  ]

  private func isDescendant(_ node: Node, of parentId: Int) -> Bool {
    if parentId == 0 { return true }
    var current: Node? = node
    var hops = 0
    while let node = current, hops < 16 {
      guard let next = node.parentId else { return false }
      if next == parentId { return true }
      current = tasks.first { $0.id == next }
      hops += 1
    }
    return false
  }

  private func scoped(_ mode: TaskScopeMode, parentId: Int, level: [Int]) -> [Int] {
    TaskScopeResolver.scoped(
      tasks,
      currentLevelTasks: tasks.filter { level.contains($0.id) },
      parentId: parentId,
      mode: mode,
      isDescendant: isDescendant
    ).map(\.id)
  }

  func testTheToggleNamesTheMode() {
    XCTAssertEqual(TaskScopeResolver.mode(showChildrenInMenus: true), .wholeSubtree)
    XCTAssertEqual(TaskScopeResolver.mode(showChildrenInMenus: false), .strictlyParented)
  }

  func testStrictlyParentedIsExactlyTheCurrentLevel() {
    XCTAssertEqual(scoped(.strictlyParented, parentId: 1, level: [2, 3]), [2, 3])
  }

  /// Depth is the difference: a grandchild counts, which is what the Priority
  /// and Kanban views were reaching for when they read the whole list instead.
  func testWholeSubtreeReachesGrandchildren() {
    XCTAssertEqual(scoped(.wholeSubtree, parentId: 1, level: [2, 3]), [2, 3, 4])
  }

  /// The bug this replaces. Priority answered "whole subtree" with the *entire
  /// list*, so a sibling branch appeared in a view the user had scoped.
  func testWholeSubtreeExcludesASiblingBranch() {
    XCTAssertFalse(scoped(.wholeSubtree, parentId: 1, level: [2, 3]).contains(5))
  }

  func testAtTheRootWholeSubtreeIsEverything() {
    XCTAssertEqual(scoped(.wholeSubtree, parentId: 0, level: [1, 5]), [1, 2, 3, 4, 5])
  }

  func testAtTheRootStrictlyParentedIsTheTopLevelOnly() {
    XCTAssertEqual(scoped(.strictlyParented, parentId: 0, level: [1, 5]), [1, 5])
  }

  // MARK: - The label

  /// Drag makes this load-bearing: dropping a card into a view whose scope you
  /// cannot see is how a task goes missing.
  func testTheRootLabelsSayWhichModeIsActive() {
    XCTAssertEqual(
      TaskScopeResolver.scopeLabel(mode: .wholeSubtree, parentTitle: nil), "All tasks")
    XCTAssertEqual(
      TaskScopeResolver.scopeLabel(mode: .strictlyParented, parentTitle: nil), "Top level")
    XCTAssertEqual(
      TaskScopeResolver.scopeLabel(mode: .strictlyParented, parentTitle: ""), "Top level")
  }

  func testAScopedLabelNamesTheParentAndTheMode() {
    XCTAssertEqual(
      TaskScopeResolver.scopeLabel(mode: .strictlyParented, parentTitle: "Summer Projects"),
      "Summer Projects")
    XCTAssertEqual(
      TaskScopeResolver.scopeLabel(mode: .wholeSubtree, parentTitle: "Summer Projects"),
      "Summer Projects — everything below")
  }
}
