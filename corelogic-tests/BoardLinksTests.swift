import XCTest

@testable import TaktCore

final class BoardLinksTests: XCTestCase {
  func testASubtaskFurtherOnLeadsOutFromItsRow() throws {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["a", "x"])], [(id: "x", rowIDs: [])]], sources: ["x": "p"])
    let link = try XCTUnwrap(links.rowLink("x", onCard: "p"))
    XCTAssertEqual(link.childColumn, 1)
    XCTAssertTrue(link.pointsForward)
    XCTAssertNil(links.rowLink("a", onCard: "p"))
    XCTAssertEqual(links.link(forChild: "x"), link)
    XCTAssertTrue(links.headingBundles.isEmpty)
  }

  /// One filed in an earlier column is a link the other way, not a stray.
  func testASubtaskInAnEarlierColumnPointsBack() throws {
    let links = BoardLinks(
      columns: [[(id: "x", rowIDs: [])], [(id: "p", rowIDs: ["x"])]], sources: ["x": "p"])
    let link = try XCTUnwrap(links.rowLink("x", onCard: "p"))
    XCTAssertFalse(link.pointsForward)
    XCTAssertFalse(links.isStray("x"))
  }

  /// A row is only a link's end on the card the link names: a task drawn on
  /// two cards leads out from one.
  func testARowLeadsOutOnlyFromItsSourceCard() {
    let links = BoardLinks(
      columns: [[(id: "g", rowIDs: ["p", "x"]), (id: "p", rowIDs: ["x"])], [(id: "x", rowIDs: [])]],
      sources: ["x": "p"])
    XCTAssertNotNil(links.rowLink("x", onCard: "p"))
    XCTAssertNil(links.rowLink("x", onCard: "g"))
  }

  /// A folded card draws none of its rows, so its heading carries its links,
  /// one bundle per column rather than one mark per subtask.
  func testAFoldedCardsHeadingBundlesItsLinksByColumn() {
    let links = BoardLinks(
      columns: [
        [(id: "p", rowIDs: [])],
        [(id: "a", rowIDs: []), (id: "y", rowIDs: [])],
        [(id: "z", rowIDs: []), (id: "b", rowIDs: []), (id: "x", rowIDs: [])],
      ],
      sources: ["x": "p", "y": "p", "z": "p"])
    XCTAssertEqual(links.headingBundles["p"]?.map(\.column), [1, 2])
    XCTAssertEqual(links.headingBundles["p"]?.map(\.childIDs), [["y"], ["z", "x"]])
    XCTAssertEqual(links.bySource["p"], ["y", "z", "x"])
    XCTAssertNil(links.rowLink("x", onCard: "p"))
  }

  func testStraysAreTheOnesWithNoCardToName() {
    let links = BoardLinks(
      columns: [[(id: "p", rowIDs: ["x"])], [(id: "x", rowIDs: []), (id: "s", rowIDs: [])]],
      sources: ["x": "p"], strays: ["s"])
    XCTAssertTrue(links.isStray("s"))
    XCTAssertFalse(links.isStray("x"))
    XCTAssertFalse(links.isEmpty)
  }

  func testACardWithNoParentApartHasNoLink() {
    let links = BoardLinks(columns: [[(id: "p", rowIDs: ["x"])]], sources: [:])
    XCTAssertTrue(links.isEmpty)
    XCTAssertEqual(links.linkIDs(touching: "p"), [])
  }

  /// The board from the screenshot that asked for this: one card in Backlog
  /// with six subtasks, four of them filed further on — two in In progress,
  /// two in This week — and those columns holding cards of their own.
  private func campusToolbox() -> BoardLinks {
    BoardLinks(
      columns: [
        // Backlog
        [
          (id: "toolbox", rowIDs: ["tracker", "mandate", "policies", "bugs", "ios", "forms"]),
          (id: "other", rowIDs: []),
        ],
        // In progress
        [(id: "omnibus", rowIDs: []), (id: "mandate", rowIDs: []), (id: "bugs", rowIDs: [])],
        // This week
        [(id: "groceries", rowIDs: []), (id: "forms", rowIDs: []), (id: "ios", rowIDs: [])],
        // Waiting
        [(id: "reply", rowIDs: [])],
      ],
      sources: ["mandate": "toolbox", "bugs": "toolbox", "ios": "toolbox", "forms": "toolbox"])
  }

  func testTheCampusToolboxCardNamesWhereEachOfItsSubtasksWent() {
    let links = campusToolbox()
    // Every subtask keeps its row; the four filed elsewhere name the column.
    let marked = ["tracker", "mandate", "policies", "bugs", "ios", "forms"].map {
      links.rowLink($0, onCard: "toolbox")?.childColumn
    }
    XCTAssertEqual(marked, [nil, 1, nil, 1, 2, 2])
    // Every link leads forward and is carried by a row, so nothing piles up
    // on the heading.
    XCTAssertTrue(links.byChild.values.allSatisfy(\.pointsForward))
    XCTAssertNil(links.headingBundles["toolbox"])
    XCTAssertEqual(links.bySource["toolbox"], ["mandate", "bugs", "ios", "forms"])
    // The cards that are not anyone's subtask have no link.
    for card in ["other", "omnibus", "groceries", "reply"] {
      XCTAssertNil(links.link(forChild: card))
      XCTAssertEqual(links.linkIDs(touching: card), [])
    }
  }

  func testSelectingEitherEndLightsTheLinkAndTheParentLightsThemAll() {
    let links = campusToolbox()
    XCTAssertEqual(links.linkIDs(touching: "ios"), ["ios"])
    XCTAssertEqual(links.linkIDs(touching: "toolbox"), ["mandate", "bugs", "ios", "forms"])
    XCTAssertEqual(links.linkIDs(touching: nil), [])
    // Each column is handed only the links with an end in it.
    let all = links.linkIDs(touching: "toolbox")
    XCTAssertEqual(links.linkIDs(all, inColumn: 0), all)
    XCTAssertEqual(links.linkIDs(all, inColumn: 1), ["mandate", "bugs"])
    XCTAssertEqual(links.linkIDs(all, inColumn: 2), ["ios", "forms"])
    XCTAssertEqual(links.linkIDs(all, inColumn: 3), [])
  }

  /// Folded, the same card says it once per column.
  func testTheCampusToolboxFoldedSaysEachColumnOnce() {
    let links = BoardLinks(
      columns: [
        [(id: "toolbox", rowIDs: [])],
        [(id: "omnibus", rowIDs: []), (id: "mandate", rowIDs: []), (id: "bugs", rowIDs: [])],
        [(id: "groceries", rowIDs: []), (id: "forms", rowIDs: []), (id: "ios", rowIDs: [])],
      ],
      sources: ["mandate": "toolbox", "bugs": "toolbox", "ios": "toolbox", "forms": "toolbox"])
    let bundles = links.headingBundles["toolbox"] ?? []
    XCTAssertEqual(bundles.map(\.column), [1, 2])
    XCTAssertEqual(bundles.map(\.childIDs), [["mandate", "bugs"], ["forms", "ios"]])
  }

  /// A board of hundreds of cards and dozens of links is worked out well
  /// inside a frame.
  func testALargeBoardIsQuick() {
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
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(links.byChild.count, sources.count)
    XCTAssertLessThan(elapsed, 0.25)
  }
}
