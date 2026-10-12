import XCTest

@testable import TaktCore

final class BoardLinkRouteTests: XCTestCase {
  private typealias Route = BoardLinkRoute
  private typealias Point = BoardLinkRoute.Point

  /// Three columns 200 wide, edge to edge: 0–200, 201–401, 402–602.
  private func column(_ index: Int) -> Route.Rect {
    let minX = Double(index) * 201
    return Route.Rect(minX: minX, minY: 40, maxX: minX + 200, maxY: 800)
  }

  /// A row on the parent's card, running to the column's content edge.
  private func row(inColumn index: Int, y: Double) -> Route.Rect {
    Route.Rect(minX: column(index).minX + 8, minY: y - 8, maxX: column(index).maxX - 8, maxY: y + 8)
  }

  private func path(
    from source: Route.Rect, to target: Route.Rect, sourceColumn: Int, forward: Bool = true, radius: Double = 6
  ) -> Route.Path {
    Route.path(
      from: source, to: target, sourceColumn: column(sourceColumn), pointsForward: forward,
      inset: 2, rail: 0.5, radius: radius)
  }

  /// To the next column, lower down: out to the rule, down it, into the card.
  func testANeighbouringCardLowerDownTurnsDownTheRule() {
    let route = path(from: row(inColumn: 0, y: 100), to: row(inColumn: 1, y: 300), sourceColumn: 0)
    XCTAssertEqual(
      route.points,
      [Point(x: 194, y: 100), Point(x: 200.5, y: 100), Point(x: 200.5, y: 300), Point(x: 207, y: 300)])
    // Each leg at the ends is 6.5 long, so the full 6pt corners fit.
    XCTAssertEqual(route.radii, [0, 6, 6, 0])
  }

  func testACardHigherUpTurnsUpTheRule() {
    let route = path(from: row(inColumn: 0, y: 300), to: row(inColumn: 1, y: 100), sourceColumn: 0)
    XCTAssertEqual(route.points.map(\.y), [300, 300, 100, 100])
    XCTAssertEqual(route.points[1].x, route.points[2].x)
  }

  /// Level within half a point, the line runs straight across.
  func testALevelCardIsAStraightLine() {
    let route = path(from: row(inColumn: 0, y: 100), to: row(inColumn: 1, y: 100.3), sourceColumn: 0)
    XCTAssertEqual(route.points, [Point(x: 194, y: 100), Point(x: 207, y: 100)])
    XCTAssertEqual(route.radii, [0, 0])
  }

  /// Two columns on, the line turns on the rule beside the source column and
  /// crosses the column between at the card's height.
  func testACardTwoColumnsOnIsCrossedToAtItsHeight() {
    let route = path(from: row(inColumn: 0, y: 100), to: row(inColumn: 2, y: 260), sourceColumn: 0)
    XCTAssertEqual(
      route.points,
      [Point(x: 194, y: 100), Point(x: 200.5, y: 100), Point(x: 200.5, y: 260), Point(x: 408, y: 260)])
  }

  /// A subtask filed in an earlier column: the line leaves the row's leading
  /// end and turns on the rule to its left.
  func testALinkBackwardsIsMirrored() {
    let route = path(
      from: row(inColumn: 2, y: 100), to: row(inColumn: 0, y: 200), sourceColumn: 2, forward: false)
    XCTAssertEqual(
      route.points,
      [Point(x: 408, y: 100), Point(x: 401.5, y: 100), Point(x: 401.5, y: 200), Point(x: 194, y: 200)])
  }

  /// A rise smaller than two corners shares it between them.
  func testCornersShrinkToASmallRise() {
    let route = path(from: row(inColumn: 0, y: 100), to: row(inColumn: 1, y: 104), sourceColumn: 0)
    XCTAssertEqual(route.radii, [0, 2, 2, 0])
  }

  /// The ends' legs bound the corners as well.
  func testCornersShrinkToShortEndLegs() {
    let route = Route.path(
      from: row(inColumn: 0, y: 100), to: row(inColumn: 1, y: 300), sourceColumn: column(0),
      pointsForward: true, inset: 6, rail: 0.5, radius: 6)
    // From 198 to the rule at 200.5 is 2.5.
    XCTAssertEqual(route.radii[1], 2.5)
  }

  /// A label that runs past its column's edge, or a target nearer than the
  /// rule, never makes the line double back.
  func testTheLineNeverDoublesBack() {
    let wide = Route.Rect(minX: 8, minY: 92, maxX: 230, maxY: 108)
    let route = path(from: wide, to: row(inColumn: 1, y: 300), sourceColumn: 0)
    let xs = route.points.map(\.x)
    XCTAssertEqual(xs, xs.sorted())
    XCTAssertEqual(route.points[1].x, 232)
  }
}
