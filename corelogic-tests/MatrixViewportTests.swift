import XCTest

@testable import PriorityCore

/// Zooming is a change of viewport, not of data — so the unzoomed window has to
/// keep drawing exactly what it drew before, and a round trip through both
/// directions has to land where it started at either zoom level.
final class MatrixViewportTests: XCTestCase {

  private let size: Double = 400

  func testTheFullViewportDrawsWhatItAlwaysDrew() {
    for point in [(0.0, 0.0), (9.0, 9.0), (-9.0, 4.0), (3.0, -7.0)] {
      let old = MatrixGeometry.offset(urgency: point.0, importance: point.1, plotSize: size)
      let new = MatrixViewport.full.offset(
        urgency: point.0, importance: point.1, plotSize: size)
      XCTAssertEqual(new.x, old.x, accuracy: 0.0001)
      XCTAssertEqual(new.y, old.y, accuracy: 0.0001)
    }
  }

  func testAQuadrantsMiddleIsTheMiddleOfTheZoomedGrid() {
    for quadrant in MatrixQuadrant.allCases {
      let viewport = MatrixViewport.quadrant(quadrant)
      let point = quadrant.representativeCoordinate
      let offset = viewport.offset(
        urgency: point.urgency, importance: point.importance, plotSize: size)
      XCTAssertEqual(offset.x, 0, accuracy: 0.0001, "\(quadrant)")
      XCTAssertEqual(offset.y, 0, accuracy: 0.0001, "\(quadrant)")
    }
  }

  /// The reason to zoom: the same two points are drawn twice as far apart.
  func testZoomingSeparatesPointsItUsedToCrowd() {
    let full = MatrixViewport.full
    let zoomed = MatrixViewport.quadrant(.doNow)
    let apart = { (v: MatrixViewport) -> Double in
      v.offset(urgency: 6, importance: 6, plotSize: self.size).x
        - v.offset(urgency: 5, importance: 5, plotSize: self.size).x
    }
    XCTAssertEqual(apart(zoomed), apart(full) * 2, accuracy: 0.0001)
  }

  func testARoundTripLandsWhereItStarted() {
    for viewport in [MatrixViewport.full] + MatrixQuadrant.allCases.map(MatrixViewport.quadrant) {
      for point in [(5.0, 5.0), (-5.0, 5.0), (5.0, -5.0), (-5.0, -5.0), (1.0, 8.0)] {
        let offset = viewport.offset(
          urgency: point.0, importance: point.1, plotSize: size)
        let back = viewport.coordinate(
          offsetX: offset.x, offsetY: offset.y, plotSize: size)
        // Only for points the viewport can actually show; others clamp.
        guard abs(offset.x) <= size / 2, abs(offset.y) <= size / 2 else { continue }
        XCTAssertEqual(back.urgency, point.0, accuracy: 0.0001)
        XCTAssertEqual(back.importance, point.1, accuracy: 0.0001)
      }
    }
  }

  /// A drop inside a focused quadrant must not land outside it — you placed it
  /// where you were looking.
  func testADropStaysInsideTheQuadrantYouAreLookingAt() {
    let viewport = MatrixViewport.quadrant(.doNow)
    for corner in [(-size, -size), (size, size), (size, -size), (-size, size)] {
      let point = viewport.placement(
        offsetX: corner.0, offsetY: corner.1, plotSize: size)
      XCTAssertEqual(
        MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance), .doNow,
        "corner \(corner) → \(point)")
    }
  }

  func testNothingEscapesTheBoard() {
    for quadrant in MatrixQuadrant.allCases {
      let point = MatrixViewport.quadrant(quadrant).placement(
        offsetX: size * 4, offsetY: -size * 4, plotSize: size)
      XCTAssertLessThanOrEqual(abs(point.urgency), MatrixGeometry.extent)
      XCTAssertLessThanOrEqual(abs(point.importance), MatrixGeometry.extent)
    }
  }

  /// Every quadrant, not just `Do`: a drop anywhere in a zoomed window commits
  /// a coordinate belonging to that window.
  func testADropInAnyZoomedQuadrantStaysInIt() {
    for quadrant in MatrixQuadrant.allCases {
      let viewport = MatrixViewport.quadrant(quadrant)
      for corner in [(-size, -size), (size, size), (size, -size), (-size, size), (0.0, 0.0)] {
        let point = viewport.placement(offsetX: corner.0, offsetY: corner.1, plotSize: size)
        XCTAssertEqual(
          MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance),
          quadrant, "\(quadrant) corner \(corner) → \(point)")
        XCTAssertTrue(
          MatrixGeometry.isPlaced(urgency: point.urgency, importance: point.importance),
          "\(quadrant) corner \(corner) landed on the unplaced sentinel")
      }
    }
  }

  func testNoFocusedQuadrantIsTheFullBoard() {
    XCTAssertEqual(MatrixViewport.viewport(for: nil), .full)
    XCTAssertEqual(MatrixViewport.viewport(for: .schedule), .quadrant(.schedule))
  }
}
