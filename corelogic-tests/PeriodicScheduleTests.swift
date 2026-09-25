import XCTest

@testable import PriorityCore

final class PeriodicScheduleTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }()

  /// Wednesday 2025-09-24, 09:00 UTC.
  private let wednesday = Date(timeIntervalSince1970: 1_758_704_400)

  private func weekday(of date: Date) -> Int { calendar.component(.weekday, from: date) }

  func testReadsThePhrasesTheAppAlreadyStores() {
    XCTAssertEqual(PeriodicSchedule("daily")?.cadence, .days(1))
    XCTAssertEqual(PeriodicSchedule(" Weekly ")?.cadence, .weeks(1))
    XCTAssertEqual(PeriodicSchedule("weekdays")?.cadence, .weekdays)
    XCTAssertEqual(PeriodicSchedule("every 3 days")?.cadence, .days(3))
    XCTAssertEqual(PeriodicSchedule("every 2 weeks")?.cadence, .weeks(2))
    XCTAssertEqual(PeriodicSchedule("every monday")?.cadence, .weekday(2))
    XCTAssertEqual(PeriodicSchedule("friday")?.cadence, .weekday(6))
  }

  func testRefusesWhatItCannotSchedule() {
    XCTAssertNil(PeriodicSchedule(""))
    XCTAssertNil(PeriodicSchedule("   "))
    XCTAssertNil(PeriodicSchedule("every so often"))
    XCTAssertNil(PeriodicSchedule("every 0 days"))
    XCTAssertNil(PeriodicSchedule("every 2 months"))
  }

  func testStepsOneCadenceForwardAndKeepsTheTimeOfDay() {
    let schedule = PeriodicSchedule("every 3 days")!
    let next = schedule.nextOccurrence(after: wednesday, calendar: calendar)

    XCTAssertEqual(next, wednesday.addingTimeInterval(3 * 86_400))
    XCTAssertEqual(calendar.component(.hour, from: next!), 9)
  }

  func testWeekdaysSkipTheWeekend() {
    let schedule = PeriodicSchedule("weekdays")!
    let friday = calendar.date(byAdding: .day, value: 2, to: wednesday)!
    let next = schedule.nextOccurrence(after: friday, calendar: calendar)

    XCTAssertEqual(weekday(of: next!), 2)  // Monday
    XCTAssertEqual(next, friday.addingTimeInterval(3 * 86_400))
  }

  func testANamedWeekdayLandsOnThatDay() {
    let schedule = PeriodicSchedule("every monday")!
    let next = schedule.nextOccurrence(after: wednesday, calendar: calendar)

    XCTAssertEqual(weekday(of: next!), 2)
    XCTAssertEqual(next, wednesday.addingTimeInterval(5 * 86_400))
  }

  /// The point of the whole thing: a rhythm you ignored for a fortnight has to
  /// come back in the future, not immediately overdue again.
  func testCatchesUpPastAGapWithoutBreakingTheRhythm() {
    let schedule = PeriodicSchedule("every 3 days")!
    let longAgo = wednesday.addingTimeInterval(-20 * 86_400)
    let next = schedule.nextOccurrence(after: longAgo, notBefore: wednesday, calendar: calendar)

    XCTAssertNotNil(next)
    XCTAssertGreaterThan(next!, wednesday)
    // Still on the original grid: a whole number of periods from where it began.
    let elapsed = next!.timeIntervalSince(longAgo)
    XCTAssertEqual(elapsed.truncatingRemainder(dividingBy: 3 * 86_400), 0, accuracy: 0.001)
    // And the first such date, not some later one.
    XCTAssertLessThanOrEqual(elapsed, 21 * 86_400 + 3 * 86_400)
  }

  func testNotBeforeNeverPullsAnOccurrenceBackwards() {
    let schedule = PeriodicSchedule("daily")!
    let next = schedule.nextOccurrence(
      after: wednesday, notBefore: wednesday.addingTimeInterval(-86_400), calendar: calendar)

    XCTAssertEqual(next, wednesday.addingTimeInterval(86_400))
  }

  func testLabelsReadAsSomeoneWouldSayThem() {
    XCTAssertEqual(PeriodicSchedule("daily")?.displayLabel, "Daily")
    XCTAssertEqual(PeriodicSchedule("weekdays")?.displayLabel, "Weekdays")
    XCTAssertEqual(PeriodicSchedule("every 1 week")?.displayLabel, "Weekly")
    XCTAssertEqual(PeriodicSchedule("every 4 days")?.displayLabel, "Every 4 days")
    XCTAssertEqual(PeriodicSchedule("every thu")?.displayLabel, "Every Thursday")
  }
}
