import XCTest

@testable import TaktCore

/// The matrix could only ever be read, never written by pointing at it, because
/// the coordinate-to-point mapping was inlined in the view and the inverse did
/// not exist. These pin down the inverse, since a drag that lands a card
/// somewhere other than where it was dropped is the failure everyone notices.
final class MatrixGeometryTests: XCTestCase {

  private let plot: Double = 400

  // MARK: - Forward

  func testTheCentreIsTheOrigin() {
    let offset = MatrixGeometry.offset(urgency: 0, importance: 0, plotSize: plot)
    XCTAssertEqual(offset.x, 0)
    XCTAssertEqual(offset.y, 0)
  }

  /// Importance grows upward, which is downward in view coordinates.
  func testPositiveImportanceOffsetsUpward() {
    let offset = MatrixGeometry.offset(urgency: 0, importance: 5, plotSize: plot)
    XCTAssertLessThan(offset.y, 0)
  }

  func testPositiveUrgencyOffsetsRightward() {
    let offset = MatrixGeometry.offset(urgency: 5, importance: 0, plotSize: plot)
    XCTAssertGreaterThan(offset.x, 0)
  }

  /// The tenth of margin: an extreme coordinate stays inside the square.
  func testTheExtremeCoordinateStaysInsideTheSquare() {
    let offset = MatrixGeometry.offset(urgency: 9, importance: 9, plotSize: plot)
    XCTAssertLessThan(abs(offset.x), plot / 2)
    XCTAssertLessThan(abs(offset.y), plot / 2)
  }

  // MARK: - Round trip

  func testACoordinateSurvivesARoundTrip() {
    for urgency in stride(from: -9.0, through: 9.0, by: 3.0) {
      for importance in stride(from: -9.0, through: 9.0, by: 3.0) {
        let offset = MatrixGeometry.offset(
          urgency: urgency, importance: importance, plotSize: plot)
        let back = MatrixGeometry.coordinate(
          offsetX: offset.x, offsetY: offset.y, plotSize: plot)
        XCTAssertEqual(back.urgency, urgency, accuracy: 0.0001)
        XCTAssertEqual(back.importance, importance, accuracy: 0.0001)
      }
    }
  }

  // MARK: - Inverse

  func testADropOutsideTheSquareClampsOntoTheBoard() {
    let far = MatrixGeometry.coordinate(offsetX: 10_000, offsetY: -10_000, plotSize: plot)
    XCTAssertEqual(far.urgency, 9)
    XCTAssertEqual(far.importance, 9)
  }

  func testSnappingCommitsWholeSteps() {
    let offset = MatrixGeometry.offset(urgency: 4.4, importance: -2.6, plotSize: plot)
    let snapped = MatrixGeometry.snappedCoordinate(
      offsetX: offset.x, offsetY: offset.y, plotSize: plot)
    XCTAssertEqual(snapped.urgency, 4)
    XCTAssertEqual(snapped.importance, -3)
  }

  /// A zero-sized plot happens for one layout pass before the view has a frame.
  /// Dividing by it would place every card at NaN, which persists.
  func testAZeroSizedPlotYieldsTheOriginRatherThanNaN() {
    let coordinate = MatrixGeometry.coordinate(offsetX: 10, offsetY: 10, plotSize: 0)
    XCTAssertEqual(coordinate.urgency, 0)
    XCTAssertEqual(coordinate.importance, 0)
  }

  // MARK: - Quadrants

  func testEachSignPairNamesItsQuadrant() {
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: 5, importance: 5), .doNow)
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: -5, importance: 5), .schedule)
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: 5, importance: -5), .delegate)
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: -5, importance: -5), .eliminate)
  }

  /// The axis itself has to belong somewhere, or a card on the line has no
  /// column on a quadrant-driven board.
  func testACoordinateOnAnAxisFallsToTheLowerSide() {
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: 0, importance: 5), .schedule)
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: 5, importance: 0), .delegate)
    XCTAssertEqual(MatrixGeometry.quadrant(urgency: 0, importance: 0), .eliminate)
  }

  func testTheOriginIsTheUnplacedSentinel() {
    XCTAssertFalse(MatrixGeometry.isPlaced(urgency: 0, importance: 0))
    XCTAssertTrue(MatrixGeometry.isPlaced(urgency: 0, importance: -1))
    XCTAssertTrue(MatrixGeometry.isPlaced(urgency: 1, importance: 0))
  }

  /// Every representative coordinate must land back in the quadrant that
  /// offered it, or a drop-by-quadrant puts the card in a different box than
  /// the one the user aimed at.
  func testEveryQuadrantsRepresentativeCoordinateLandsInIt() {
    for quadrant in MatrixQuadrant.allCases {
      let point = quadrant.representativeCoordinate
      XCTAssertEqual(
        MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance),
        quadrant)
      XCTAssertTrue(MatrixGeometry.isPlaced(urgency: point.urgency, importance: point.importance))
    }
  }

  // MARK: - Naming

  func testQuadrantsAreNamedByTheirCommandWords() {
    XCTAssertEqual(MatrixQuadrant.named("do"), .doNow)
    XCTAssertEqual(MatrixQuadrant.named("  SCHEDULE "), .schedule)
    XCTAssertEqual(MatrixQuadrant.named("bin"), .eliminate)
    XCTAssertNil(MatrixQuadrant.named("urgent"))
  }
}
