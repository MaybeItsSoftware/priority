import XCTest

@testable import PriorityCore

final class CompletedWorkDigestTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2  // Monday
    return calendar
  }()

  /// Wednesday 2025-09-24, mid-afternoon.
  private let now = Date(timeIntervalSince1970: 1_758_726_000)

  private func day(_ offset: Int, hour: Int = 10) -> Date {
    let start = calendar.startOfDay(for: now)
    let shifted = calendar.date(byAdding: .day, value: offset, to: start)!
    return calendar.date(byAdding: .hour, value: hour, to: shifted)!
  }

  private struct Item: Equatable {
    let name: String
    let at: Date
  }

  private func group(_ items: [Item]) -> [CompletedWorkGroup<Item>] {
    CompletedWorkDigest.group(items, completedAt: \.at, now: now, calendar: calendar)
  }

  func testDaysComeBackNewestFirst() {
    let groups = group([
      Item(name: "old", at: day(-3)),
      Item(name: "now", at: day(0)),
      Item(name: "mid", at: day(-1)),
    ])
    XCTAssertEqual(groups.map(\.items.first?.name), ["now", "mid", "old"])
  }

  func testOneDaysItemsComeBackNewestFirst() {
    let groups = group([
      Item(name: "morning", at: day(0, hour: 9)),
      Item(name: "evening", at: day(0, hour: 21)),
      Item(name: "lunch", at: day(0, hour: 13)),
    ])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].items.map(\.name), ["evening", "lunch", "morning"])
  }

  /// The boundary the rail is read across: something closed late last night is
  /// yesterday's work when you look at the rail this morning, not "recent".
  func testLateLastNightIsYesterdayNotToday() {
    let groups = group([
      Item(name: "late", at: day(-1, hour: 23)),
      Item(name: "early", at: day(0, hour: 1)),
    ])
    XCTAssertEqual(groups.map(\.kind), [.today, .yesterday])
    XCTAssertEqual(groups.map(\.items.first?.name), ["early", "late"])
  }

  func testTheWeekEndsAtSixDaysSoAWeekdayNameStaysUnambiguous() {
    XCTAssertEqual(CompletedWorkDigest.kind(of: day(0), now: now, calendar: calendar), .today)
    XCTAssertEqual(CompletedWorkDigest.kind(of: day(-1), now: now, calendar: calendar), .yesterday)
    XCTAssertEqual(CompletedWorkDigest.kind(of: day(-2), now: now, calendar: calendar), .thisWeek)
    XCTAssertEqual(CompletedWorkDigest.kind(of: day(-6), now: now, calendar: calendar), .thisWeek)
    XCTAssertEqual(CompletedWorkDigest.kind(of: day(-7), now: now, calendar: calendar), .earlier)
  }

  /// A clock that has run ahead of the database, or a task completed by a sync
  /// from a device in a timezone east of this one.
  func testSomethingDatedLaterTodayIsStillToday() {
    XCTAssertEqual(
      CompletedWorkDigest.kind(of: day(1), now: now, calendar: calendar), .today)
  }

  func testNothingFinishedIsNoDays() {
    XCTAssertTrue(group([]).isEmpty)
  }
}
