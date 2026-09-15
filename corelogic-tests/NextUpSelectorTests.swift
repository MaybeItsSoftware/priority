import Foundation
import PriorityCore
import XCTest

final class NextUpSelectorTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)
  private let now = Date(timeIntervalSince1970: 1_750_000_000)

  private func candidate(
    _ id: String,
    daily: Bool = false,
    due: TimeInterval? = nil,
    start: TimeInterval? = nil,
    urgency: Int? = nil,
    importance: Int? = nil,
    priority: Int? = nil,
    estimate: Int? = nil,
    column: String? = nil,
    order: Int = 0
  ) -> NextUpCandidate {
    NextUpCandidate(
      id: id, title: id, isDailyDueToday: daily,
      dueAt: due.map { now.addingTimeInterval($0) },
      startAt: start.map { now.addingTimeInterval($0) },
      matrixUrgency: urgency, matrixImportance: importance, priority: priority,
      estimateSeconds: estimate, kanbanColumn: column, sortOrder: order, createdAt: now)
  }

  private func rank(_ candidates: [NextUpCandidate]) -> [String] {
    NextUpSelector.rank(candidates, now: now, calendar: calendar).map(\.candidate.id)
  }

  func testAnOutstandingDailyOutranksEverythingElse() throws {
    let ranked = NextUpSelector.rank(
      [
        candidate("overdue", due: -20 * 86_400),
        candidate("daily", daily: true),
        candidate("important", urgency: 1, importance: 1, priority: 4),
      ], now: now, calendar: calendar)

    XCTAssertEqual(ranked.map(\.candidate.id), ["daily", "overdue", "important"])
    XCTAssertEqual(ranked.first?.reason, .daily)
  }

  func testOverdueBeatsDueTodayAndDeeperOverdueBeatsShallower() {
    XCTAssertEqual(
      rank([candidate("today", due: 0), candidate("late", due: -3 * 86_400), candidate("later", due: -9 * 86_400)]),
      ["later", "late", "today"])
  }

  func testOverdueContributionIsCappedSoOneForgottenTaskCannotBuryTheQueue() {
    let ancient = NextUpSelector.score(candidate("ancient", due: -400 * 86_400), now: now, calendar: calendar)
    let month = NextUpSelector.score(candidate("month", due: -30 * 86_400), now: now, calendar: calendar)

    XCTAssertEqual(ancient.score, month.score)
    XCTAssertLessThan(ancient.score, NextUpSelector.score(candidate("daily", daily: true), now: now, calendar: calendar).score)
  }

  func testDueDatesBeyondTheHorizonStopContributing() {
    let far = NextUpSelector.score(
      candidate("far", due: Double(NextUpSelector.dueHorizonDays + 40) * 86_400), now: now, calendar: calendar)
    let none = NextUpSelector.score(candidate("none"), now: now, calendar: calendar)

    XCTAssertEqual(far.score, none.score)
    XCTAssertEqual(far.reason, .order)
  }

  func testImportanceCanOvertakeADistantDueDate() {
    XCTAssertEqual(
      rank([candidate("soon", due: 12 * 86_400), candidate("important", urgency: 1, importance: 1)]),
      ["important", "soon"])
  }

  func testTodayColumnBeatsBarePriority() {
    XCTAssertEqual(rank([candidate("prio", priority: 4), candidate("today", column: "today")]), ["today", "prio"])
  }

  func testTasksScheduledForLaterAreDroppedUntilTheirTimeArrives() {
    let ranked = rank([
      candidate("later", daily: true, start: 3_600),
      candidate("ordinary"),
    ])

    XCTAssertEqual(ranked, ["ordinary"])
    XCTAssertEqual(rank([candidate("due", due: 0, start: -60)]), ["due"])
  }

  func testEqualScoresPreferTheShorterJobThenManualOrder() {
    XCTAssertEqual(
      rank([
        candidate("long", priority: 2, estimate: 3_600, order: 0),
        candidate("short", priority: 2, estimate: 600, order: 1),
        candidate("unestimated", priority: 2, order: 2),
      ]),
      ["short", "long", "unestimated"])
  }

  func testAnUntouchedListStillProducesAPickInManualOrder() throws {
    let pick = try XCTUnwrap(
      NextUpSelector.next(
        from: [candidate("second", order: 1), candidate("first", order: 0)], now: now, calendar: calendar))

    XCTAssertEqual(pick.candidate.id, "first")
    XCTAssertEqual(pick.reason, .order)
  }

  func testEmptyInputHasNoPick() {
    XCTAssertNil(NextUpSelector.next(from: [], now: now, calendar: calendar))
  }
}
