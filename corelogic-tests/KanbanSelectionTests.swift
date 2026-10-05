import XCTest

@testable import TaktCore

/// The other half of `KanbanManager`. `KanbanFilter` decides which column a
/// card lands in; `KanbanSelection` decides which card is selected once it has.
///
/// It was index arithmetic threaded through `dataSource` reads, so a keyboard-
/// first app's entire board navigation had no coverage.
final class KanbanSelectionTests: XCTestCase {

  private typealias Placement = KanbanSelection.Placement

  /// Three columns, so "the focused one" and "the one holding the selection"
  /// can differ — which is the case most of this code exists to handle.
  private let board = [[10, 11, 12], [20, 21], [30]]

  private func placement(column: Int, selected: Int?, row: Int) -> Placement {
    Placement(focusedColumnIndex: column, selectedTaskId: selected, siblingIndex: row)
  }

  // MARK: - Locating

  func testLocateFindsTheColumnAndRow() {
    let found = KanbanSelection.locate(21, in: board)
    XCTAssertEqual(found?.column, 1)
    XCTAssertEqual(found?.row, 1)
  }

  func testLocateReturnsNilForATaskNotOnTheBoard() {
    XCTAssertNil(KanbanSelection.locate(99, in: board))
  }

  /// Focus can be left pointing at the wrong column when an edit elsewhere
  /// moves the selected card. The selection wins.
  func testTheResolvedColumnIsTheOneHoldingTheSelectionNotTheFocusedOne() {
    XCTAssertEqual(
      KanbanSelection.resolvedFocusedColumnIndex(selectedTaskId: 30, in: board, fallback: 0), 2)
  }

  func testTheResolvedColumnFallsBackWhenNothingIsSelected() {
    XCTAssertEqual(
      KanbanSelection.resolvedFocusedColumnIndex(selectedTaskId: nil, in: board, fallback: 1), 1)
  }

  func testTheResolvedColumnFallsBackWhenTheSelectionIsGone() {
    XCTAssertEqual(
      KanbanSelection.resolvedFocusedColumnIndex(selectedTaskId: 99, in: board, fallback: 1), 1)
  }

  // MARK: - Column focus

  /// The board is displayed reversed, so moving visually right is a *lower*
  /// array index. Getting this backwards would invert the whole board.
  func testFocusingRightMovesToTheLowerColumnIndex() {
    let moved = KanbanSelection.focusColumn(from: 1, direction: 1, in: board)
    XCTAssertEqual(moved, placement(column: 0, selected: 10, row: 0))
  }

  func testFocusingLeftMovesToTheHigherColumnIndex() {
    let moved = KanbanSelection.focusColumn(from: 1, direction: -1, in: board)
    XCTAssertEqual(moved, placement(column: 2, selected: 30, row: 0))
  }

  /// `nil` rather than a clamped placement, so the caller leaves the existing
  /// selection alone instead of resetting it to the top of the same column.
  func testFocusingPastEitherEndDoesNotMove() {
    XCTAssertNil(KanbanSelection.focusColumn(from: 0, direction: 1, in: board))
    XCTAssertNil(KanbanSelection.focusColumn(from: 2, direction: -1, in: board))
  }

  func testFocusingIntoAnEmptyColumnClearsTheSelection() {
    let grid = [[1, 2], []]
    XCTAssertEqual(
      KanbanSelection.focusColumn(from: 0, direction: -1, in: grid),
      placement(column: 1, selected: nil, row: 0))
  }

  // MARK: - Moving within a column

  func testNextMovesDownOneCard() {
    let moved = KanbanSelection.next(from: placement(column: 0, selected: 10, row: 0), in: board)
    XCTAssertEqual(moved, placement(column: 0, selected: 11, row: 1))
  }

  func testPreviousMovesUpOneCard() {
    let moved = KanbanSelection.previous(
      from: placement(column: 0, selected: 12, row: 2), in: board)
    XCTAssertEqual(moved, placement(column: 0, selected: 11, row: 1))
  }

  /// Clamps rather than wrapping, and never spills into the next column —
  /// vertical keys stay vertical.
  func testMovingPastTheEndsClampsWithinTheColumn() {
    XCTAssertEqual(
      KanbanSelection.next(from: placement(column: 0, selected: 12, row: 2), in: board),
      placement(column: 0, selected: 12, row: 2))
    XCTAssertEqual(
      KanbanSelection.previous(from: placement(column: 0, selected: 10, row: 0), in: board),
      placement(column: 0, selected: 10, row: 0))
  }

  /// With nothing selected, down starts *above* the first card and up starts
  /// *below* the last, so a single press lands on an end rather than skipping
  /// past it.
  func testMovingWithNoSelectionLandsOnTheNearEndOfTheColumn() {
    XCTAssertEqual(
      KanbanSelection.next(from: placement(column: 0, selected: nil, row: 0), in: board),
      placement(column: 0, selected: 10, row: 0))
    XCTAssertEqual(
      KanbanSelection.previous(from: placement(column: 0, selected: nil, row: 0), in: board),
      placement(column: 0, selected: 12, row: 2))
  }

  /// Moving re-resolves the column first, so navigation continues in the column
  /// the card is actually in and focus catches up.
  func testMovingFollowsTheSelectionIntoAnotherColumn() {
    let moved = KanbanSelection.next(from: placement(column: 0, selected: 20, row: 0), in: board)
    XCTAssertEqual(moved, placement(column: 1, selected: 21, row: 1))
  }

  func testMovingInAnEmptyOrMissingColumnDoesNothing() {
    XCTAssertNil(KanbanSelection.next(from: placement(column: 0, selected: nil, row: 0), in: [[]]))
    XCTAssertNil(
      KanbanSelection.next(from: placement(column: 7, selected: nil, row: 0), in: board))
  }

  // MARK: - Leaving the column

  func testTheTopCardIsAtTheTop() {
    XCTAssertTrue(
      KanbanSelection.isAtTopOfFocusedColumn(
        placement(column: 0, selected: 10, row: 0), in: board))
    XCTAssertFalse(
      KanbanSelection.isAtTopOfFocusedColumn(
        placement(column: 0, selected: 11, row: 1), in: board))
  }

  /// An empty or out-of-range column counts as "at the top" so UP still leaves
  /// the column instead of doing nothing at all.
  func testAnEmptyOrMissingColumnCountsAsAtTheTop() {
    XCTAssertTrue(
      KanbanSelection.isAtTopOfFocusedColumn(
        placement(column: 0, selected: nil, row: 0), in: [[]]))
    XCTAssertTrue(
      KanbanSelection.isAtTopOfFocusedColumn(
        placement(column: 9, selected: nil, row: 0), in: board))
  }

  // MARK: - Repairing a stale selection

  /// The important one: a valid selection comes back *identical*, so
  /// `clampKanbanSelection` can skip the write and avoid firing the cache
  /// invalidation bus on every mutation.
  func testAValidSelectionIsReturnedUntouched() {
    let original = placement(column: 0, selected: 30, row: 5)
    XCTAssertEqual(KanbanSelection.clamp(original, in: board), original)
  }

  /// Nearest *by row*, so deleting a card leaves the selection where the eye
  /// already is rather than jumping to the top.
  func testAStaleSelectionFallsToTheSameRowInTheFocusedColumn() {
    XCTAssertEqual(
      KanbanSelection.clamp(placement(column: 0, selected: 99, row: 1), in: board),
      placement(column: 0, selected: 11, row: 1))
  }

  func testAStaleSelectionClampsToTheLastRowOfAShorterColumn() {
    XCTAssertEqual(
      KanbanSelection.clamp(placement(column: 2, selected: 99, row: 4), in: board),
      placement(column: 2, selected: 30, row: 0))
  }

  func testAStaleSelectionInAnEmptyOrMissingColumnClears() {
    XCTAssertEqual(
      KanbanSelection.clamp(placement(column: 1, selected: 99, row: 3), in: [[1], []]),
      placement(column: 1, selected: nil, row: 0))
    XCTAssertEqual(
      KanbanSelection.clamp(placement(column: 9, selected: 99, row: 3), in: board),
      placement(column: 9, selected: nil, row: 0))
  }

  func testANegativeRowClampsToTheFirstCard() {
    XCTAssertEqual(
      KanbanSelection.clamp(placement(column: 0, selected: nil, row: -3), in: board),
      placement(column: 0, selected: 10, row: 0))
  }

  // MARK: - Choosing a selection after a scope change

  func testTheFirstAvailableCardSkipsLeadingEmptyColumns() {
    XCTAssertEqual(
      KanbanSelection.firstAvailable(in: [[], [], [7, 8]]),
      placement(column: 2, selected: 7, row: 0))
  }

  /// An empty board keeps the drilled scope with nothing selected, so the user
  /// sees an empty board rather than being silently bounced back out.
  func testAnEmptyBoardYieldsNoSelection() {
    XCTAssertEqual(
      KanbanSelection.firstAvailable(in: [[], []], fallbackColumnIndex: 1),
      placement(column: 1, selected: nil, row: 0))
  }

  /// Popping out of a scope re-selects the task just left, so the move feels
  /// reversible.
  func testSelectingAKnownTaskLandsOnItExactly() {
    XCTAssertEqual(
      KanbanSelection.select(21, in: board), placement(column: 1, selected: 21, row: 1))
  }

  func testSelectingATaskNotOnTheBoardFallsBackToTheFirstCard() {
    XCTAssertEqual(
      KanbanSelection.select(99, in: board), placement(column: 0, selected: 10, row: 0))
    XCTAssertEqual(
      KanbanSelection.select(nil, in: board), placement(column: 0, selected: 10, row: 0))
  }
}
