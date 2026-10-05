import XCTest

@testable import TaktCore

/// The manual-order overlay is the one part of the board a user positions by
/// hand, and until now the only way to write it was a keyboard nudge that
/// swapped adjacent pairs. A drag inserts instead of swapping, and the index it
/// arrives with is measured against the list *including* the card being
/// dragged — so the compensation for a downward move is the whole reason this
/// has its own tests.
final class KanbanManualOrderTests: XCTestCase {

  private let visible = [10, 11, 12, 13]

  // MARK: - Dragging within a column

  func testMovingACardUpPutsItBeforeTheTarget() {
    let order = KanbanManualOrder.movingTask(13, toPositionBefore: 1, inVisibleOrder: visible)
    XCTAssertEqual(order, [10, 13, 11, 12])
  }

  /// The off-by-one this exists to pin down. Dropping card 10 before index 2
  /// means "after 11", not "before 11" — because lifting 10 out has already
  /// shifted 11 and 12 down a slot.
  func testMovingACardDownCompensatesForItsOwnRemoval() {
    let order = KanbanManualOrder.movingTask(10, toPositionBefore: 2, inVisibleOrder: visible)
    XCTAssertEqual(order, [11, 10, 12, 13])
  }

  func testMovingACardToItsOwnPositionIsANoOp() {
    let order = KanbanManualOrder.movingTask(11, toPositionBefore: 1, inVisibleOrder: visible)
    XCTAssertEqual(order, visible)
  }

  func testDroppingPastTheEndAppends() {
    let order = KanbanManualOrder.movingTask(10, toPositionBefore: 99, inVisibleOrder: visible)
    XCTAssertEqual(order, [11, 12, 13, 10])
  }

  func testDroppingBeforeTheStartPrepends() {
    let order = KanbanManualOrder.movingTask(13, toPositionBefore: -4, inVisibleOrder: visible)
    XCTAssertEqual(order, [13, 10, 11, 12])
  }

  // MARK: - Dragging in from another column

  /// A card arriving from elsewhere isn't in `visible`, so there is nothing to
  /// compensate for and the index means exactly what it says.
  func testACardFromAnotherColumnInsertsAtTheStatedIndex() {
    let order = KanbanManualOrder.movingTask(99, toPositionBefore: 2, inVisibleOrder: visible)
    XCTAssertEqual(order, [10, 11, 99, 12, 13])
  }

  func testACardDroppedIntoAnEmptyColumnIsTheWholeOrder() {
    let order = KanbanManualOrder.movingTask(99, toPositionBefore: 0, inVisibleOrder: [])
    XCTAssertEqual(order, [99])
  }

  // MARK: - Nudging

  func testNudgingSwapsWithTheNeighbour() {
    XCTAssertEqual(
      KanbanManualOrder.nudgingTask(11, direction: 1, inVisibleOrder: visible),
      [10, 12, 11, 13])
    XCTAssertEqual(
      KanbanManualOrder.nudgingTask(11, direction: -1, inVisibleOrder: visible),
      [11, 10, 12, 13])
  }

  /// Nothing rather than a clamp: a held key at the top of a column should stop
  /// writing, not rewrite the same order forever.
  func testNudgingOffEitherEndReturnsNothing() {
    XCTAssertNil(KanbanManualOrder.nudgingTask(10, direction: -1, inVisibleOrder: visible))
    XCTAssertNil(KanbanManualOrder.nudgingTask(13, direction: 1, inVisibleOrder: visible))
  }

  func testNudgingATaskThatIsNotInTheColumnReturnsNothing() {
    XCTAssertNil(KanbanManualOrder.nudgingTask(99, direction: 1, inVisibleOrder: visible))
  }

  func testNudgingRejectsADirectionThatIsNotOneSlot() {
    XCTAssertNil(KanbanManualOrder.nudgingTask(11, direction: 2, inVisibleOrder: visible))
    XCTAssertNil(KanbanManualOrder.nudgingTask(11, direction: 0, inVisibleOrder: visible))
  }

  // MARK: - Applying a saved order

  func testNamedTasksLeadAndTheRestKeepTheirNaturalSort() {
    let natural = [10, 11, 12, 13]
    let applied = KanbanManualOrder.apply([13, 11], to: natural, id: { $0 })
    XCTAssertEqual(applied, [13, 11, 10, 12])
  }

  func testAnEmptyOrderLeavesTheNaturalSortAlone() {
    let natural = [10, 11, 12]
    XCTAssertEqual(KanbanManualOrder.apply([], to: natural, id: { $0 }), natural)
  }

  /// A saved order outlives the tasks in it — a card completed elsewhere leaves
  /// an ID behind that no longer matches anything.
  func testStaleIdsInTheOrderAreIgnored() {
    let applied = KanbanManualOrder.apply([99, 12], to: [10, 11, 12], id: { $0 })
    XCTAssertEqual(applied, [12, 10, 11])
  }

  // MARK: - Pruning

  func testRemovingPrunesEveryColumnAndDropsEmptyOnes() {
    let orders = ["a": [1, 2, 3], "b": [2], "c": [4]]
    let updated = KanbanManualOrder.removing(taskIds: [2, 3], from: orders)
    XCTAssertEqual(updated?["a"], [1])
    XCTAssertNil(updated?["b"])
    XCTAssertEqual(updated?["c"], [4])
  }

  /// `nil` means "no write needed", which is what stops a prune on every
  /// refetch from invalidating the board's cache for no reason.
  func testRemovingNothingRelevantReportsNoChange() {
    XCTAssertNil(KanbanManualOrder.removing(taskIds: [99], from: ["a": [1, 2]]))
    XCTAssertNil(KanbanManualOrder.removing(taskIds: [], from: ["a": [1, 2]]))
  }
}
