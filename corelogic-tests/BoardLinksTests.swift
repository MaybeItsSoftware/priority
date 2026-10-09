import XCTest

@testable import TaktCore

final class BoardLinksTests: XCTestCase {
  // MARK: - Structure

  func testASubtaskFurtherOnLinksToTheRowOnItsParentsCard() throws {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["a", "x"])], [(id: "x", rowIDs: [])]], sources: ["x": "p"])
    let link = try XCTUnwrap(links.link(forChild: "x"))
    XCTAssertTrue(link.isAligned)
    XCTAssertTrue(link.meetsRow)
    XCTAssertTrue(link.pointsForward)
    XCTAssertEqual(links.linkedRows, ["p": ["x"]])
    XCTAssertEqual(links.measuredColumns, [0, 1])
  }

  /// A subtask filed in an earlier column than its parent is not drawn level
  /// — that would pull its parent's column into its own — and so shows the
  /// hint instead.
  func testASubtaskInAnEarlierColumnIsNotLevelled() throws {
    let links = BoardLinks(
      columns: [[(id: "x", rowIDs: [])], [(id: "p", rowIDs: ["x"])]], sources: ["x": "p"])
    let link = try XCTUnwrap(links.link(forChild: "x"))
    XCTAssertFalse(link.isAligned)
    XCTAssertFalse(link.pointsForward)
    XCTAssertTrue(links.linkedRows.isEmpty)
    XCTAssertTrue(links.measuredColumns.isEmpty)
  }

  /// A folded parent draws none of its rows, so the link meets its heading.
  func testAFoldedParentIsMetAtItsHeading() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: [])], [(id: "x", rowIDs: [])]], sources: ["x": "p"])
    XCTAssertEqual(links.link(forChild: "x")?.meetsRow, false)
    XCTAssertEqual(links.headingLinks, ["p": "x"])
    XCTAssertEqual(links.headingCards, ["p", "x"])
  }

  /// Two subtasks of one folded card would both have to sit level with its
  /// one heading; the first keeps it.
  func testOnlyOneLinkCanHoldAHeading() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: [])], [(id: "x", rowIDs: []), (id: "y", rowIDs: [])]],
      sources: ["x": "p", "y": "p"])
    XCTAssertEqual(links.link(forChild: "x")?.isAligned, true)
    XCTAssertEqual(links.link(forChild: "y")?.isAligned, false)
  }

  /// Links that cross — x above y on the parent, below it in the later
  /// column — cannot both be level; one is given up and the other kept.
  func testCrossingLinksKeepOne() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["x", "y"])], [(id: "y", rowIDs: []), (id: "x", rowIDs: [])]],
      sources: ["x": "p", "y": "p"])
    let aligned = ["x", "y"].filter { links.link(forChild: $0)?.isAligned == true }
    XCTAssertEqual(aligned.count, 1)
  }

  /// Only the subtasks that are not drawn level say whose they are in words.
  func testTheHintIsForSubtasksNotDrawnLevel() {
    let links = BoardLinks(
      columns: [[(id: "y", rowIDs: []), (id: "p", rowIDs: ["x"])], [(id: "x", rowIDs: []), (id: "s", rowIDs: [])]],
      sources: ["x": "p", "y": "p"], strays: ["s"])
    XCTAssertFalse(links.needsHint("x"))
    XCTAssertFalse(links.needsHint("p"))
    XCTAssertTrue(links.needsHint("s"))
    XCTAssertTrue(links.needsHint("y"))
    XCTAssertFalse(links.isEmpty)
  }

  func testACardWithNoParentApartHasNoLink() {
    let links = BoardLinks(columns: [[(id: "p", rowIDs: ["x"])]], sources: [:])
    XCTAssertTrue(links.isEmpty)
    XCTAssertEqual(BoardLinkLayout.solve(links, metrics: BoardLinkMetrics()), .empty)
  }

  // MARK: - Layout

  private func metrics(
    heights: [String: Double] = [:], headings: [String: Double] = [:],
    rows: [BoardRowKey: (top: Double, mid: Double)] = [:]
  ) -> BoardLinkMetrics {
    var metrics = BoardLinkMetrics(cardSpacing: 0)
    metrics.cardHeights = heights
    metrics.headingMids = headings
    metrics.rowTops = rows.mapValues(\.top)
    metrics.rowMids = rows.mapValues(\.mid)
    return metrics
  }

  /// The card in the later column drops to sit level with its row.
  func testTheCardDropsToItsRow() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["a", "x"])], [(id: "x", rowIDs: [])]], sources: ["x": "p"])
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["p": 80, "x": 30], headings: ["p": 15, "x": 15],
      rows: [BoardRowKey(card: "p", row: "x"): (top: 50, mid: 60)]))
    XCTAssertEqual(layout.column(1).gapAbove["x"], 45)
    XCTAssertEqual(layout.lineY["x"], 60)
    XCTAssertTrue(layout.column(0).spaceAboveRow.isEmpty)
  }

  /// When the card is already lower than its row, the row moves down inside
  /// its parent's card instead.
  func testTheRowDropsToItsCard() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["x"])], [(id: "q", rowIDs: []), (id: "x", rowIDs: [])]],
      sources: ["x": "p"])
    let key = BoardRowKey(card: "p", row: "x")
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["p": 60, "q": 100, "x": 30], headings: ["p": 15, "x": 15],
      rows: [key: (top: 30, mid: 40)]))
    XCTAssertEqual(layout.column(0).spaceAboveRow[key], 75)
    XCTAssertNil(layout.column(1).gapAbove["x"])
    XCTAssertEqual(layout.lineY["x"], 115)
    XCTAssertEqual(layout.column(0).spaceInside(card: "p", rows: ["x"]), 75)
  }

  /// Two subtasks moved on together: their cards are taller than their rows,
  /// so the second row opens a gap inside the parent to meet its card.
  func testSiblingRowsSpreadToMeetTheirCards() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["x", "y"])], [(id: "x", rowIDs: []), (id: "y", rowIDs: [])]],
      sources: ["x": "p", "y": "p"])
    let x = BoardRowKey(card: "p", row: "x")
    let y = BoardRowKey(card: "p", row: "y")
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["p": 70, "x": 40, "y": 40], headings: ["p": 15, "x": 15, "y": 15],
      rows: [x: (top: 30, mid: 40), y: (top: 50, mid: 60)]))
    // x's card drops 25 to its row at 40; y's card is then at 65, its
    // heading at 80, its row at 60, so the row opens 20 above itself.
    XCTAssertEqual(layout.column(1).gapAbove["x"], 25)
    XCTAssertEqual(layout.lineY["x"], 40)
    XCTAssertEqual(layout.column(0).spaceAboveRow[y], 20)
    XCTAssertEqual(layout.lineY["y"], 80)
    XCTAssertNil(layout.column(0).spaceAboveRow[x])
  }

  /// A link two columns on passes through the column between, at its height.
  func testALinkPassesThroughTheColumnsBetween() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["x"])], [(id: "b", rowIDs: [])], [(id: "x", rowIDs: [])]],
      sources: ["x": "p"])
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["p": 60, "b": 30, "x": 30], headings: ["p": 15, "x": 15],
      rows: [BoardRowKey(card: "p", row: "x"): (top: 30, mid: 40)]))
    XCTAssertEqual(layout.column(1).passingLines, [.init(childID: "x", y: 40)])
    XCTAssertEqual(layout.column(2).gapAbove["x"], 25)
    XCTAssertFalse(links.measuredColumns.contains(1))
  }

  /// A chain — a subtask's subtask further on again — settles left to right,
  /// so the grandchild meets its parent where its parent has been moved to.
  func testAChainSettlesLeftToRight() {
    let links = BoardLinks(
      columns: [
        [(id: "g", rowIDs: ["p"])],
        [(id: "p", rowIDs: ["x"])],
        [(id: "x", rowIDs: [])],
      ],
      sources: ["p": "g", "x": "p"])
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["g": 100, "p": 60, "x": 30], headings: ["g": 15, "p": 15, "x": 15],
      rows: [
        BoardRowKey(card: "g", row: "p"): (top: 70, mid: 80),
        BoardRowKey(card: "p", row: "x"): (top: 30, mid: 40),
      ]))
    XCTAssertEqual(layout.column(1).gapAbove["p"], 65)
    XCTAssertEqual(layout.lineY["p"], 80)
    // p's top is now 65, its row's middle 105.
    XCTAssertEqual(layout.lineY["x"], 105)
    XCTAssertEqual(layout.column(2).gapAbove["x"], 90)
  }

  /// A card not yet measured — off screen in a lazy column — is taken at the
  /// column's average, and the estimate gives way once it is measured.
  func testUnmeasuredCardsAreEstimated() {
    let links = BoardLinks(
      columns: [[(id: "a", rowIDs: []), (id: "b", rowIDs: []), (id: "p", rowIDs: [])], [(id: "x", rowIDs: [])]],
      sources: ["x": "p"])
    let layout = BoardLinkLayout.solve(links, metrics: metrics(
      heights: ["a": 50, "x": 30], headings: ["p": 10, "x": 10]))
    // b counts as a's 50, so p sits at 100.
    XCTAssertEqual(layout.lineY["x"], 110)
    XCTAssertEqual(layout.column(1).gapAbove["x"], 100)
  }

  /// Neighbours sharing a rule overlap by it, and the layout counts that.
  func testCardSpacingIsCounted() {
    let links = BoardLinks(
      columns: [[(id: "a", rowIDs: []), (id: "p", rowIDs: [])], [(id: "x", rowIDs: [])]], sources: ["x": "p"])
    var metrics = metrics(heights: ["a": 50, "p": 40, "x": 30], headings: ["p": 10, "x": 10])
    metrics.cardSpacing = -1
    let layout = BoardLinkLayout.solve(links, metrics: metrics)
    XCTAssertEqual(layout.lineY["x"], 59)
  }

  /// A board of hundreds of cards and dozens of links settles well inside a
  /// frame. Printed so the figure is in the test log.
  func testALargeBoardSettlesQuickly() {
    var columns: [[(id: String, rowIDs: [String])]] = [[], [], [], []]
    var sources: [String: String] = [:]
    for card in 0..<400 {
      let rows = (0..<4).map { "c\(card)-\($0)" }
      columns[0].append((id: "c\(card)", rowIDs: rows))
      if card % 10 == 0 {
        columns[1 + card % 3].append((id: rows[1], rowIDs: []))
        sources[rows[1]] = "c\(card)"
      }
    }
    for card in 0..<400 { columns[2].append((id: "other\(card)", rowIDs: [])) }
    let start = Date()
    let links = BoardLinks(columns: columns, sources: sources)
    let layout = BoardLinkLayout.solve(links, metrics: BoardLinkMetrics())
    let elapsed = Date().timeIntervalSince(start)
    print("BoardLinks: \(sources.count) links over \(columns.map(\.count).reduce(0, +)) cards in \(elapsed * 1000) ms")
    XCTAssertEqual(layout.lineY.count, links.byChild.values.filter(\.isAligned).count)
    XCTAssertLessThan(elapsed, 0.25)
  }
}
