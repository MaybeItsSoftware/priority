import Foundation
import TaktCore
import XCTest

final class HabitPolicyTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// 2026-10-05 is a Monday.
  private func day(_ value: Int, month: Int = 10, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: value, hour: hour))!
  }

  // MARK: - Frequency

  func testFrequencyRoundTripsThroughTheDailyStorage() {
    for frequency: HabitFrequency in [.daily, .weekly, .everyNDays(3), .weekdays([2, 4, 6])] {
      let stored = frequency.storage
      XCTAssertEqual(HabitFrequency(weekdays: stored.weekdays, intervalDays: stored.intervalDays), frequency)
    }
    XCTAssertEqual(HabitFrequency.everyNDays(1), HabitFrequency.everyNDays(1))
    XCTAssertEqual(HabitFrequency(weekdays: [], intervalDays: nil), .daily)
  }

  func testScheduledDaysFollowWeekdaysAndIntervalsFromTheAnchor() {
    let weekdays = HabitRule(weekdays: [2, 4], anchor: day(5))
    XCTAssertTrue(HabitPolicy.isScheduled(weekdays, on: day(5), calendar: calendar))   // Mon
    XCTAssertFalse(HabitPolicy.isScheduled(weekdays, on: day(6), calendar: calendar))  // Tue
    XCTAssertTrue(HabitPolicy.isScheduled(weekdays, on: day(7), calendar: calendar))   // Wed

    let weekly = HabitRule(intervalDays: 7, anchor: day(5))
    XCTAssertTrue(HabitPolicy.isScheduled(weekly, on: day(12), calendar: calendar))
    XCTAssertFalse(HabitPolicy.isScheduled(weekly, on: day(13), calendar: calendar))
    XCTAssertFalse(HabitPolicy.isScheduled(weekly, on: day(28, month: 9), calendar: calendar),
                   "nothing before the day it was made")
  }

  // MARK: - Expiry

  func testExpiryRules() {
    let base = HabitRule(anchor: day(1))
    var rule = base
    XCTAssertFalse(HabitPolicy.isExpired(rule, on: day(30), sourceCompleted: true, calendar: calendar))

    rule.expiry = .whenSourceCompleted
    XCTAssertFalse(HabitPolicy.isExpired(rule, on: day(30), sourceCompleted: false, calendar: calendar))
    XCTAssertTrue(HabitPolicy.isExpired(rule, on: day(30), sourceCompleted: true, calendar: calendar))

    rule.expiry = .on(day(10, hour: 18))
    XCTAssertFalse(HabitPolicy.isExpired(rule, on: day(9), sourceCompleted: false, calendar: calendar))
    XCTAssertTrue(HabitPolicy.isExpired(rule, on: day(10, hour: 1), sourceCompleted: false, calendar: calendar))
    XCTAssertNil(HabitPolicy.appearance(rule, on: day(11), lastDoneDay: nil, sourceCompleted: false, calendar: calendar))
  }

  func testStoredExpiryReadsBackAndFallsBackToNever() {
    XCTAssertEqual(HabitExpiry(rule: "source", date: nil), .whenSourceCompleted)
    XCTAssertEqual(HabitExpiry(rule: "date", date: day(3)), .on(day(3)))
    XCTAssertEqual(HabitExpiry(rule: "date", date: nil), .never)
    XCTAssertEqual(HabitExpiry(rule: "nonsense", date: nil), .never)
  }

  // MARK: - Appearance

  func testADueHabitAppearsInItsColumnUntilItIsDone() {
    let rule = HabitRule(anchor: day(5), placement: .thisWeek)
    let appearance = HabitPolicy.appearance(rule, on: day(6), lastDoneDay: day(5), sourceCompleted: false, calendar: calendar)
    XCTAssertEqual(appearance, HabitAppearance(column: "this-week", dueDay: day(6, hour: 0), isCarriedOver: false))
    XCTAssertNil(HabitPolicy.appearance(rule, on: day(6), lastDoneDay: day(6, hour: 9), sourceCompleted: false, calendar: calendar))
  }

  func testAMissedDayIsDroppedWhenTheHabitDisappearsAtTheEndOfTheDay() {
    let rule = HabitRule(intervalDays: 7, anchor: day(5), dropsAtDayEnd: true)
    XCTAssertNotNil(HabitPolicy.appearance(rule, on: day(5), lastDoneDay: nil, sourceCompleted: false, calendar: calendar))
    XCTAssertNil(HabitPolicy.appearance(rule, on: day(6), lastDoneDay: nil, sourceCompleted: false, calendar: calendar))
  }

  func testAMissedDayIsCarriedUntilDoneWhenItDoesNotDisappear() {
    let rule = HabitRule(intervalDays: 7, anchor: day(5), dropsAtDayEnd: false, placement: .waiting)
    let carried = HabitPolicy.appearance(rule, on: day(8), lastDoneDay: nil, sourceCompleted: false, calendar: calendar)
    XCTAssertEqual(carried, HabitAppearance(column: "waiting-on", dueDay: day(5, hour: 0), isCarriedOver: true))
    // Done on the 8th: owed nothing on the 9th.
    XCTAssertNil(HabitPolicy.appearance(rule, on: day(9), lastDoneDay: day(8), sourceCompleted: false, calendar: calendar))
    // Done before the owed day does not count for it.
    XCTAssertNotNil(HabitPolicy.appearance(rule, on: day(13), lastDoneDay: day(8), sourceCompleted: false, calendar: calendar))
  }

  func testAnExpiredHabitNeverAppears() {
    let rule = HabitRule(anchor: day(5), dropsAtDayEnd: false, expiry: .whenSourceCompleted)
    XCTAssertNil(HabitPolicy.appearance(rule, on: day(6), lastDoneDay: nil, sourceCompleted: true, calendar: calendar))
  }

  // MARK: - Column

  func testReconciledColumnOnlyManagesTheHabitsOwnColumn() {
    let appearance = HabitAppearance(column: "today", dueDay: day(5), isCarriedOver: false)
    XCTAssertEqual(HabitPolicy.reconciledColumn(current: nil, appearance: appearance, placement: .today), .some("today"))
    XCTAssertNil(HabitPolicy.reconciledColumn(current: "today", appearance: appearance, placement: .today))
    XCTAssertNil(HabitPolicy.reconciledColumn(current: "in-progress", appearance: appearance, placement: .today),
                 "a card moved by hand stays where it was put")
    XCTAssertEqual(HabitPolicy.reconciledColumn(current: "today", appearance: nil, placement: .today), .some(nil))
    XCTAssertNil(HabitPolicy.reconciledColumn(current: "backlog", appearance: nil, placement: .today))
    XCTAssertNil(HabitPolicy.reconciledColumn(current: nil, appearance: nil, placement: .today))
  }

  // MARK: - Parsing

  func testEstimateAndDateText() {
    XCTAssertEqual(HabitPolicy.estimateSeconds(from: "30m"), 1_800)
    XCTAssertEqual(HabitPolicy.estimateSeconds(from: "1h30"), 5_400)
    XCTAssertEqual(HabitPolicy.estimateSeconds(from: "45"), 2_700)
    XCTAssertNil(HabitPolicy.estimateSeconds(from: ""))
    XCTAssertNil(HabitPolicy.estimateSeconds(from: "soon"))
    XCTAssertEqual(HabitPolicy.date(from: "2026-12-31", now: day(5), calendar: calendar),
                   calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)))
    XCTAssertEqual(HabitPolicy.date(from: "2w", now: day(5), calendar: calendar), day(19, hour: 0))
  }
}
