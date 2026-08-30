import XCTest

@testable import PriorityCore

/// Inheritance put two hundred tasks on seven points. These are the properties
/// that let the plot say something about a task that it does not already say
/// about that task's goal.
final class MatrixSpreadTests: XCTestCase {

  private let calendar = Calendar(identifier: .gregorian)
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func days(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: now)!
  }

  private func drift(due: Int?, rank: Int?) -> (urgency: Double, importance: Double) {
    MatrixSpread.drift(
      dueDate: due.map(days), priorityRank: rank, now: now, calendar: calendar)
  }

  // MARK: - Reading the task's own facts

  func testSoonerIsMoreUrgent() {
    XCTAssertGreaterThan(drift(due: -1, rank: nil).urgency, drift(due: 0, rank: nil).urgency)
    XCTAssertGreaterThan(drift(due: 0, rank: nil).urgency, drift(due: 2, rank: nil).urgency)
    XCTAssertGreaterThan(drift(due: 2, rank: nil).urgency, drift(due: 30, rank: nil).urgency)
  }

  /// An unscheduled task under an urgent goal is the one worth seeing sit below
  /// its siblings, so no due date is *less* urgent than a distant one.
  func testNoDueDateIsTheLeastUrgentOfAll() {
    XCTAssertLessThan(drift(due: nil, rank: nil).urgency, drift(due: 3650, rank: nil).urgency)
  }

  func testAHigherRankIsMoreImportant() {
    XCTAssertGreaterThan(drift(due: nil, rank: 1).importance, drift(due: nil, rank: 5).importance)
    XCTAssertGreaterThan(drift(due: nil, rank: 5).importance, drift(due: nil, rank: 9).importance)
  }

  func testAnUnrankedTaskSitsBelowEveryRankedOne() {
    XCTAssertLessThan(drift(due: nil, rank: nil).importance, drift(due: nil, rank: 9).importance)
  }

  func testTheDriftNeverExceedsItsReach() {
    for due in [-5, 0, 1, 4, 40] {
      for rank in [1, 4, 9] {
        let value = drift(due: due, rank: rank)
        XCTAssertLessThanOrEqual(abs(value.urgency), MatrixSpread.reach)
        XCTAssertLessThanOrEqual(abs(value.importance), MatrixSpread.reach)
      }
    }
  }

  // MARK: - What the drift is not allowed to do

  /// The whole constraint: a derived offset orders tasks inside a quadrant and
  /// never argues with which quadrant the goal was put in.
  func testSpreadingNeverChangesQuadrant() {
    let goals: [(Double, Double)] = [(5, 5), (-5, 5), (5, -5), (-5, -5), (1, 1), (-1, -1), (9, 9)]
    for goal in goals {
      let base = MatrixGeometry.quadrant(urgency: goal.0, importance: goal.1)
      for due in [-5, 0, 3, 40, 3650] {
        for rank in [1, 9] {
          let point = MatrixSpread.spread(
            base: (urgency: goal.0, importance: goal.1),
            drift: drift(due: due, rank: rank))
          XCTAssertEqual(
            MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance),
            base, "goal \(goal), due \(due), rank \(rank)")
        }
      }
    }
    // And with no facts at all, which drifts both axes downward.
    for goal in goals {
      let point = MatrixSpread.spread(
        base: (urgency: goal.0, importance: goal.1), drift: drift(due: nil, rank: nil))
      XCTAssertEqual(
        MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance),
        MatrixGeometry.quadrant(urgency: goal.0, importance: goal.1), "goal \(goal)")
    }
  }

  /// A goal sitting exactly on an axis reads as the lower side, so nothing
  /// beneath it can be drifted across onto the upper one.
  func testAGoalOnAnAxisStaysOnItsSideOfIt() {
    let point = MatrixSpread.spread(
      base: (urgency: 0, importance: 6), drift: drift(due: -5, rank: 1))

    XCTAssertLessThanOrEqual(point.urgency, 0)
    XCTAssertGreaterThan(point.importance, 0)
  }

  func testSpreadingStaysOnTheBoard() {
    let point = MatrixSpread.spread(
      base: (urgency: 9, importance: 9), drift: drift(due: -5, rank: 1))

    XCTAssertLessThanOrEqual(point.urgency, MatrixGeometry.extent)
    XCTAssertLessThanOrEqual(point.importance, MatrixGeometry.extent)
  }

  /// The point of the whole thing: two tasks under one goal stop being one dot.
  func testTwoTasksUnderOneGoalLandOnDifferentPoints() {
    let goal = (urgency: 5.0, importance: 5.0)
    let soonAndRanked = MatrixSpread.spread(base: goal, drift: drift(due: 0, rank: 1))
    let neither = MatrixSpread.spread(base: goal, drift: drift(due: nil, rank: nil))

    XCTAssertNotEqual(soonAndRanked.urgency, neither.urgency)
    XCTAssertNotEqual(soonAndRanked.importance, neither.importance)
  }
}
