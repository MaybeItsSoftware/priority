import XCTest

@testable import TaktCore

final class BoardLinkNudgeTests: XCTestCase {
  private typealias End = BoardLinkNudge.End

  private func end(
    _ id: String, from sourceColumn: Int = 0, at sourceY: Double?, to childColumn: Int = 1, at targetY: Double?
  ) -> End {
    End(childID: id, sourceColumn: sourceColumn, childColumn: childColumn, sourceY: sourceY, targetY: targetY)
  }

  /// The ends as they would be measured once `offsets` are in place, given
  /// where they are with none: every card in a column moves down by the
  /// space opened above it and above every subtask card over it, and a row
  /// moves with the cards over it in its column.
  private func remeasured(_ ends: [End], natural: [End], offsets: [String: Double]) -> [End] {
    func moved(_ y: Double?, inColumn column: Int) -> Double? {
      guard let y else { return nil }
      return y + natural.filter { $0.childColumn == column && ($0.targetY ?? .infinity) <= y }
        .reduce(0) { $0 + (offsets[$1.childID] ?? 0) }
    }
    return natural.map { end in
      End(
        childID: end.childID, sourceColumn: end.sourceColumn, childColumn: end.childColumn,
        sourceY: moved(end.sourceY, inColumn: end.sourceColumn), targetY: moved(end.targetY, inColumn: end.childColumn))
    }
  }

  /// Works the offsets out, then again from the frames they produce, and
  /// checks the second time changes nothing.
  private func settled(_ natural: [End], cap: Double = 56) -> [String: Double] {
    let first = BoardLinkNudge.offsets(for: natural, current: [:], cap: cap)
    let again = BoardLinkNudge.offsets(
      for: remeasured(natural, natural: natural, offsets: first), current: first, cap: cap)
    XCTAssertEqual(again, first, "settling again from the moved frames moved something")
    return first
  }

  func testALevelCardIsLeftAlone() {
    XCTAssertEqual(settled([end("a", at: 100, at: 100)]), [:])
    // Within a fraction of a point, too.
    XCTAssertEqual(settled([end("a", at: 100.4, at: 100)]), [:])
  }

  func testACardALittleAboveItsRowMovesDownLevelWithIt() {
    XCTAssertEqual(settled([end("a", at: 140.3, at: 100)]), ["a": 40])
  }

  func testACardFurtherAboveThanTheCapStaysPut() {
    XCTAssertEqual(settled([end("a", at: 200, at: 100)]), [:])
    XCTAssertEqual(settled([end("a", at: 156, at: 100)]), ["a": 56])
  }

  func testACardBelowItsRowStaysPut() {
    XCTAssertEqual(settled([end("a", at: 100, at: 130)]), [:])
  }

  /// A subtask filed in an earlier column is never moved, however near.
  func testALinkPointingBackwardsIsNeverNudged() {
    XCTAssertEqual(settled([end("a", from: 1, at: 130, to: 0, at: 100)]), [:])
    XCTAssertEqual(
      BoardLinkNudge.offsets(for: [end("a", from: 1, at: 130, to: 0, at: 100)], current: ["a": 30]), [:])
  }

  /// Two subtasks of one card into one column: moving the first moves the
  /// second with it, and the second is then worked out from where it is.
  func testTwoLinksIntoOneColumn() {
    // Rows at 100 and 120; the cards at 60 and 116, 56 apart.
    let ends = [end("first", at: 100, at: 60), end("second", at: 120, at: 116)]
    // The first opens 40 and lands level; the second is pushed to 156,
    // below its row, and stays there.
    XCTAssertEqual(settled(ends), ["first": 40])
  }

  /// Two cards each a little above its row, one under the other: the lower
  /// one opens only what the upper one's move left it short.
  func testASecondCardOpensOnlyWhatTheFirstLeftItShort() {
    let ends = [end("first", at: 100, at: 80), end("second", at: 300, at: 260)]
    XCTAssertEqual(settled(ends), ["first": 20, "second": 20])
  }

  /// Across three columns: a card moved in the second column carries its
  /// own row for a subtask in the third down with it.
  func testChainedLinksSettleLeftToRight() {
    let ends = [
      end("middle", from: 0, at: 130, to: 1, at: 100),
      // The middle card's row, 20 below its heading, to a card in the third.
      end("last", from: 1, at: 120, to: 2, at: 120),
    ]
    // The middle card moves 30; its row with it, to 150; the last card
    // follows it 30 down.
    XCTAssertEqual(settled(ends), ["middle": 30, "last": 30])
  }

  /// An end not measured yet keeps whatever space it has.
  func testAnUnmeasuredEndKeepsItsSpace() {
    XCTAssertEqual(
      BoardLinkNudge.offsets(for: [end("a", at: nil, at: 120)], current: ["a": 12]), ["a": 12])
    XCTAssertEqual(BoardLinkNudge.offsets(for: [end("a", at: 140, at: nil)], current: [:]), [:])
  }

  /// Measured again with its space in place, a card keeps it, and a
  /// measure a fraction off does not move it.
  func testASettledCardStaysSettled() {
    XCTAssertEqual(BoardLinkNudge.offsets(for: [end("a", at: 140, at: 140)], current: ["a": 40]), ["a": 40])
    XCTAssertEqual(BoardLinkNudge.offsets(for: [end("a", at: 140.4, at: 140)], current: ["a": 40]), ["a": 40])
  }

  /// A card whose row has moved away gives its space back.
  func testACardGivesItsSpaceBackWhenItsRowRises() {
    // Measured with 40 open: the card at 140, its row now at 90.
    XCTAssertEqual(BoardLinkNudge.offsets(for: [end("a", at: 90, at: 140)], current: ["a": 40]), [:])
  }
}
