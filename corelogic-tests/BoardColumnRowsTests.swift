import XCTest

@testable import TaktCore

final class BoardColumnRowsTests: XCTestCase {
  func testRowsRunCardThenItsSubtasksTopToBottom() {
    let rows = BoardColumnRows(cards: [(id: "a", rowIDs: ["a1", "a2"]), (id: "b", rowIDs: [])])
    XCTAssertEqual(rows.ids, ["a", "a1", "a2", "b"])
    XCTAssertEqual(rows.cardByRow, ["a": "a", "a1": "a", "a2": "a", "b": "b"])
    XCTAssertTrue(rows.contains("a2"))
    XCTAssertFalse(rows.contains("c"))
  }

  /// A subtask can be a row on its parent's card and a card of its own in the
  /// same column. The first match from the top wins, as the search it
  /// replaces found it.
  func testARowDrawnTwiceBelongsToTheFirstCardThatDrawsIt() {
    let rowFirst = BoardColumnRows(cards: [(id: "a", rowIDs: ["x"]), (id: "x", rowIDs: [])])
    XCTAssertEqual(rowFirst.cardByRow["x"], "a")
    let cardFirst = BoardColumnRows(cards: [(id: "x", rowIDs: []), (id: "a", rowIDs: ["x"])])
    XCTAssertEqual(cardFirst.cardByRow["x"], "x")
  }

  func testEmptyHasNoRows() {
    XCTAssertEqual(BoardColumnRows.empty.ids, [])
    XCTAssertFalse(BoardColumnRows.empty.contains("a"))
  }

  /// One arrow key on a column of forty cards with eight subtasks each: the
  /// flatten-and-search the board used to do, against a lookup in the index.
  /// Printed so the figures are in the test log.
  func testLookingUpTheCardBeatsFlatteningTheColumn() {
    let cards = (0..<40).map { card in (id: "c\(card)", rowIDs: (0..<8).map { "c\(card)-\($0)" }) }
    let target = "c39-7"
    let presses = 200
    let flattening = Self.seconds {
      for _ in 0..<presses {
        // `boardRowIDs(in:).contains`, then the column's card search.
        _ = cards.flatMap { [$0.id] + $0.rowIDs }.contains(target)
        _ = cards.first { $0.id == target || $0.rowIDs.contains(target) }?.id
      }
    }
    let index = BoardColumnRows(cards: cards)
    let lookingUp = Self.seconds {
      for _ in 0..<presses {
        _ = index.contains(target)
        _ = index.cardByRow[target]
      }
    }
    print(String(
      format: "Board arrow key, %d rows: flattening %.1f µs, index %.2f µs",
      index.ids.count, flattening / Double(presses) * 1_000_000, lookingUp / Double(presses) * 1_000_000))
    XCTAssertLessThan(lookingUp, flattening)
  }

  private static func seconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
