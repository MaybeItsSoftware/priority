import XCTest

@testable import TaktCore

final class MatrixQuadrantIndexTests: XCTestCase {
  private struct Item: Equatable {
    let id: Int
    let urgency: Int?
    let importance: Int?
  }

  private let items = [
    Item(id: 0, urgency: 1, importance: 1),
    Item(id: 1, urgency: nil, importance: 1),
    Item(id: 2, urgency: 0, importance: 1),
    Item(id: 3, urgency: 1, importance: 1),
    Item(id: 4, urgency: 1, importance: nil),
    Item(id: 5, urgency: 0, importance: 0),
  ]

  /// Exactly what the four filters it replaces returned, in the same order.
  func testItSortsAsTheFiltersDid() {
    let index = MatrixQuadrantIndex(items) { ($0.urgency, $0.importance) }
    XCTAssertEqual(index.unplaced, items.filter { $0.urgency == nil || $0.importance == nil })
    for urgency in 0...1 {
      for importance in 0...1 {
        XCTAssertEqual(
          index.items(urgency: urgency, importance: importance),
          items.filter { $0.urgency == urgency && $0.importance == importance })
      }
    }
    XCTAssertEqual(index.items(urgency: 0, importance: 0).map(\.id), [5])
    XCTAssertEqual(index.items(urgency: 1, importance: 0), [])
  }

  /// Ranked tasks first, lowest rank first; ties and the unranked keep the
  /// board's order.
  func testAQuadrantReadsRankedTasksFirstThenTheRestInBoardOrder() {
    let board = (0..<6).map { Item(id: $0, urgency: 1, importance: 1) }
    let ranks: [Int: Int] = [4: 0, 2: 1, 5: 1]
    let index = MatrixQuadrantIndex(board, position: { ($0.urgency, $0.importance) }, rank: { ranks[$0.id] })
    XCTAssertEqual(index.items(urgency: 1, importance: 1).map(\.id), [4, 2, 5, 0, 1, 3])
  }

  func testTheDrawnOrderIsUnplacedThenTheQuadrantsInReadingOrder() {
    let index = MatrixQuadrantIndex(items) { ($0.urgency, $0.importance) }
    // Unplaced 1 and 4; do now 0 and 3; schedule 2; delegate none; eliminate 5.
    XCTAssertEqual(index.drawnOrder.map(\.id), [1, 4, 0, 3, 2, 5])
  }

  func testMovingPutsATaskBeforeItsTargetOrLast() {
    let order = ["a", "b", "c"]
    XCTAssertEqual(MatrixQuadrantOrder.moving("c", before: "a", in: order), ["c", "a", "b"])
    XCTAssertEqual(MatrixQuadrantOrder.moving("a", before: "c", in: order), ["b", "a", "c"])
    XCTAssertEqual(MatrixQuadrantOrder.moving("a", before: nil, in: order), ["b", "c", "a"])
    // From another quadrant, so not in the order yet.
    XCTAssertEqual(MatrixQuadrantOrder.moving("x", before: "b", in: order), ["a", "x", "b", "c"])
    XCTAssertEqual(MatrixQuadrantOrder.moving("x", before: "gone", in: order), ["a", "b", "c", "x"])
    XCTAssertEqual(MatrixQuadrantOrder.moving("b", before: "b", in: order), ["a", "c", "b"])
  }

  func testSteppingMovesOnePlaceAndStopsAtTheEnds() {
    let order = ["a", "b", "c"]
    XCTAssertEqual(MatrixQuadrantOrder.stepping("b", by: -1, in: order), ["b", "a", "c"])
    XCTAssertEqual(MatrixQuadrantOrder.stepping("b", by: 1, in: order), ["a", "c", "b"])
    XCTAssertNil(MatrixQuadrantOrder.stepping("a", by: -1, in: order))
    XCTAssertNil(MatrixQuadrantOrder.stepping("c", by: 1, in: order))
    XCTAssertNil(MatrixQuadrantOrder.stepping("x", by: 1, in: order))
  }

  func testADropLandsBeforeTheRowWhoseMiddleItIsAbove() {
    let order = ["a", "b", "c", "d"]
    // "a" has scrolled out of sight; "d" is below the fold, not drawn yet.
    let frames: [String: ClosedRange<Double>] = ["b": 40...60, "c": 60...80]
    XCTAssertEqual(MatrixQuadrantOrder.dropTarget(at: 45, order: order, frames: frames).before, "b")
    XCTAssertEqual(MatrixQuadrantOrder.dropTarget(at: 45, order: order, frames: frames).line, 40)
    XCTAssertEqual(MatrixQuadrantOrder.dropTarget(at: 55, order: order, frames: frames).before, "c")
    XCTAssertEqual(MatrixQuadrantOrder.dropTarget(at: 75, order: order, frames: frames).before, "d")
    XCTAssertEqual(MatrixQuadrantOrder.dropTarget(at: 75, order: order, frames: frames).line, 80)
    let foot = MatrixQuadrantOrder.dropTarget(at: 75, order: ["b", "c"], frames: frames)
    XCTAssertNil(foot.before)
    XCTAssertEqual(foot.line, 80)
    let empty = MatrixQuadrantOrder.dropTarget(at: 10, order: [String](), frames: [:])
    XCTAssertNil(empty.before)
    XCTAssertNil(empty.line)
  }

  func testAnEmptyIndexHasNothingAnywhere() {
    let index = MatrixQuadrantIndex<Item>()
    XCTAssertEqual(index.unplaced, [])
    XCTAssertEqual(index.items(urgency: 1, importance: 1), [])
  }

  /// One render of the matrix before and after: thirteen filters of the board
  /// against four lookups into an index built once per board read. Printed so
  /// the figures are in the test log.
  func testLookingUpQuadrantsBeatsFilteringTheBoard() {
    let board = (0..<400).map {
      Item(id: $0, urgency: $0 % 5 == 0 ? nil : $0 % 2, importance: $0 % 3 == 0 ? 0 : 1)
    }
    let renders = 50
    let filtering = Self.seconds {
      for _ in 0..<renders {
        _ = board.filter { $0.urgency == nil || $0.importance == nil }.count
        for urgency in 0...1 {
          for importance in 0...1 {
            for _ in 0..<3 { _ = board.filter { $0.urgency == urgency && $0.importance == importance }.count }
          }
        }
      }
    }
    let index = MatrixQuadrantIndex(board) { ($0.urgency, $0.importance) }
    let lookingUp = Self.seconds {
      for _ in 0..<renders {
        _ = index.unplaced.count
        for urgency in 0...1 {
          for importance in 0...1 { _ = index.items(urgency: urgency, importance: importance).count }
        }
      }
    }
    print(String(
      format: "Matrix render, %d tasks: filtering %.1f µs, index %.1f µs",
      board.count, filtering / Double(renders) * 1_000_000, lookingUp / Double(renders) * 1_000_000))
    XCTAssertLessThan(lookingUp, filtering)
  }

  private static func seconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
