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
    order: Int = 0,
    rank: Int? = nil
  ) -> NextUpCandidate {
    NextUpCandidate(
      id: id, title: id, isDailyDueToday: daily,
      dueAt: due.map { now.addingTimeInterval($0) },
      startAt: start.map { now.addingTimeInterval($0) },
      matrixUrgency: urgency, matrixImportance: importance, priority: priority,
      estimateSeconds: estimate, kanbanColumn: column, focusRank: rank, sortOrder: order,
      createdAt: now)
  }

  private func rank(_ candidates: [NextUpCandidate]) -> [String] {
    NextUpSelector.rank(candidates, now: now, calendar: calendar).map(\.candidate.id)
  }

  func testOverdueTasksOutrankOutstandingDailies() throws {
    let ranked = NextUpSelector.rank(
      [
        candidate("overdue", due: -20 * 86_400),
        candidate("daily", daily: true),
        candidate("important", urgency: 1, importance: 1, priority: 4),
      ], now: now, calendar: calendar)

    XCTAssertEqual(ranked.map(\.candidate.id), ["overdue", "daily", "important"])
    XCTAssertEqual(ranked.first?.reason, .overdue)
  }

  func testOverdueBeatsDueTodayAndDeeperOverdueBeatsShallower() {
    XCTAssertEqual(
      rank([candidate("today", due: 0), candidate("late", due: -3 * 86_400), candidate("later", due: -9 * 86_400)]),
      ["later", "late", "today"])
  }

  func testOverdueAgeIsNotCappedAndOlderDeadlinesWin() {
    XCTAssertEqual(rank([candidate("month", due: -30 * 86_400),
                         candidate("ancient", due: -400 * 86_400), candidate("daily", daily: true)]),
                   ["ancient", "month", "daily"])
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

  // MARK: - The ladder

  func testRankOrdersTheWholeLadderNotJustTheWinner() {
    let ranked = NextUpSelector.rank(
      [
        candidate("order-only", order: 9),
        candidate("daily", daily: true),
        candidate("overdue", due: -2 * 86_400),
        candidate("important", urgency: 1, importance: 1),
      ], now: now, calendar: calendar)

    XCTAssertEqual(ranked.map(\.candidate.id), ["overdue", "daily", "important", "order-only"])
    // Every rung carries its own reason, so climbing can explain each one.
    XCTAssertEqual(ranked.map(\.reason), [.overdue, .daily, .importance, .order])
  }

  func testScoresDecreaseMonotonicallyUpTheLadder() {
    let ranked = NextUpSelector.rank(
      [
        candidate("a", daily: true),
        candidate("b", due: -1 * 86_400),
        candidate("c", due: 0),
        candidate("d", column: "today"),
        candidate("e", priority: 1),
        candidate("f"),
      ], now: now, calendar: calendar)

    XCTAssertEqual(ranked.count, 6)
    for (higher, lower) in zip(ranked, ranked.dropFirst()) {
      XCTAssertGreaterThanOrEqual(higher.score, lower.score, "\(higher.candidate.id) should outrank \(lower.candidate.id)")
    }
  }

  // MARK: - Hand-placed order

  func testHandPlacementCannotDisplaceDeadlines() {
    XCTAssertEqual(
      rank([
        candidate("daily", daily: true),
        candidate("overdue", due: -10 * 86_400),
        candidate("placed", rank: 0),
      ]),
      ["overdue", "placed", "daily"],
      "deadline precedence survives manual placement")
  }

  func testHandPlacedTasksKeepTheirOwnOrderAmongThemselves() {
    XCTAssertEqual(
      rank([
        candidate("third", daily: true, rank: 2),
        candidate("first", rank: 0),
        candidate("second", due: -40 * 86_400, rank: 1),
        candidate("scored", daily: true),
      ]),
      ["second", "first", "scored", "third"])
  }

  func testClearingOneTasksRankLetsItFallBackToItsScore() {
    XCTAssertEqual(
      rank([candidate("unplaced", daily: true), candidate("placed", rank: 0)]),
      ["placed", "unplaced"],
      "a task pinned to the top sits above even an outstanding daily")
    XCTAssertEqual(
      rank([candidate("unplaced", daily: true), candidate("placed")]),
      ["unplaced", "placed"])
  }

  func testRankingIsATotalOrderSoTheLadderNeverShuffles() {
    let candidates = [
      candidate("a", daily: true),
      candidate("b", daily: true),
      candidate("c", due: 0),
      candidate("d"),
    ]

    let first = rank(candidates)

    XCTAssertEqual(first, rank(candidates.reversed()), "order must not depend on input order")
    XCTAssertEqual(Set(first).count, first.count)
  }

  // MARK: - Hand placement

  func testAPinIsAPositionNotAPromotion() {
    // "loose" outscores everything; pinning "pinned" to slot 1 must not
    // displace it, only sit behind it.
    let ranked = rank([
      candidate("loose", daily: true),
      candidate("pinned", order: 9, rank: 1),
      candidate("a", order: 0),
      candidate("b", order: 1),
    ])

    XCTAssertEqual(ranked, ["loose", "pinned", "a", "b"])
  }

  func testPinningOneTaskLeavesEveryOtherTaskRankedByScore() {
    let ranked = rank([
      candidate("nudged", order: 5, rank: 0),
      candidate("daily", daily: true),
      candidate("overdue", due: -86_400),
      candidate("idle", order: 3),
    ])

    XCTAssertEqual(ranked.first, "overdue")
    XCTAssertEqual(
      Array(ranked.dropFirst()), ["nudged", "daily", "idle"],
      "the unpinned tail keeps its scored order")
  }

  func testTwoTasksPinnedToTheSameSlotBothSurvive() {
    let ranked = rank([
      candidate("first", rank: 0),
      candidate("second", rank: 0),
      candidate("free", order: 0),
    ])

    XCTAssertEqual(ranked.count, 3)
    XCTAssertEqual(Set(ranked), ["first", "second", "free"])
    XCTAssertEqual(Array(ranked.prefix(2)), ["first", "second"])
  }

  func testAPinPastTheEndOfTheLadderTakesTheLastSlotRatherThanVanishing() {
    let ranked = rank([
      candidate("far", rank: 99),
      candidate("a", order: 0),
      candidate("b", order: 1),
    ])

    XCTAssertEqual(ranked, ["a", "b", "far"])
  }

  func testEveryTaskPinnedReproducesTheRecordedOrderExactly() {
    let ranked = rank([
      candidate("third", daily: true, rank: 2),
      candidate("first", rank: 0),
      candidate("second", rank: 1),
    ])

    XCTAssertEqual(ranked, ["first", "second", "third"], "a fully pinned ladder ignores score")
  }
}
