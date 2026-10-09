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
