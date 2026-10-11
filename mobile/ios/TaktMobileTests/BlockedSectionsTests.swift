import TaktWorkspace
import XCTest
@testable import Takt

final class BlockedSectionsTests: XCTestCase {
  private func row(
    _ id: String, depth: Int = 0, parent: String? = nil, status: TaskStatus = .open
  ) -> OutlineRow {
    OutlineRow(
      id: id, title: id, depth: depth, status: status, isList: false, isPromoted: false, parentID: parent,
      listID: "L", dueAt: nil, estimateSeconds: nil, hasNotes: false, hasChildren: false, isFolded: false,
      isPlanned: false, listName: nil)
  }

  private func card(_ id: String, status: TaskStatus = .open) -> BoardCard {
    BoardCard(
      id: id, title: id, status: status, isList: false, isPromoted: false, listID: "L", parentID: nil, dueAt: nil,
      estimateSeconds: nil, isPlanned: false, listName: nil, parentTitle: nil, subtasks: [])
  }

  func testEachSiblingGroupLabelsTheFirstOfItsBlockedTail() {
    // a's children end with a blocked run (a2, a3); the roots end with c.
    let rows = [
      row("a"), row("a1", depth: 1, parent: "a"), row("a2", depth: 1, parent: "a"),
      row("a3", depth: 1, parent: "a"), row("b"), row("c"),
    ]
    let labels = BlockedSections.outlineLabels(rows: rows, blocked: ["a2", "a3", "c"])
    XCTAssertEqual(labels, ["a2", "c"])
  }

  func testABlockedTaskFollowedByAnOpenSiblingIsNotLabelled() {
    let rows = [row("a"), row("b"), row("c")]
    XCTAssertEqual(BlockedSections.outlineLabels(rows: rows, blocked: ["a"]), [])
  }

  func testADoneTaskIsNeverBlocked() {
    let rows = [row("a"), row("b", status: .completed)]
    XCTAssertEqual(BlockedSections.outlineLabels(rows: rows, blocked: ["b"]), [])
  }

  func testAColumnLabelsItsFirstBlockedCard() {
    let cards = [card("a"), card("b"), card("c")]
    XCTAssertEqual(BlockedSections.boardLabel(cards: cards, blocked: ["b", "c"]), "b")
    XCTAssertNil(BlockedSections.boardLabel(cards: cards, blocked: []))
  }

  func testEntriesPutTheLabelBeforeItsRowAtThatRowsDepth() {
    let rows = [row("a"), row("a1", depth: 1, parent: "a"), row("b")]
    let entries = OutlineEntry.entries(rows: rows, blocked: ["a1"])
    XCTAssertEqual(entries.map(\.id), ["a", "blocked-label.a1", "a1", "b"])
    XCTAssertEqual(entries[1], .blockedLabel(before: "a1", depth: 1))
  }

  func testADragAcrossTheLabelMovesByRowOffsets() {
    let rows = [row("a"), row("b"), row("c")]
    let entries = OutlineEntry.entries(rows: rows, blocked: ["c"])
    // c alone ends the roots blocked, so the label sits between b and c.
    XCTAssertEqual(entries.map(\.id), ["a", "b", "blocked-label.c", "c"])
    let move = OutlineEntry.rowMove(in: entries, source: [3], destination: 0)
    XCTAssertEqual(move?.source, [2])
    XCTAssertEqual(move?.destination, 0)
    XCTAssertEqual(OutlineEntry.rowMove(in: entries, source: [0], destination: 4)?.destination, 3)
    XCTAssertNil(OutlineEntry.rowMove(in: entries, source: [2], destination: 0))
  }
}
