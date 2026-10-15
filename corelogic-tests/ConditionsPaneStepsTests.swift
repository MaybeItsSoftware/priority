import XCTest

@testable import TaktCore

final class ConditionsPaneStepsTests: XCTestCase {
  private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  /// 14:10 UTC on 15 October 2026.
  private let now = Date(timeIntervalSince1970: 1_792_073_400)

  func testPlacesStepFromNowhereAndStopAtTheEnds() {
    let places = ["home", "campus", "library"]
    XCTAssertEqual(ConditionsPaneSteps.place(from: nil, in: places, by: 1), "home")
    XCTAssertEqual(ConditionsPaneSteps.place(from: "home", in: places, by: 1), "campus")
    XCTAssertEqual(ConditionsPaneSteps.place(from: "library", in: places, by: 1), "library")
    XCTAssertNil(ConditionsPaneSteps.place(from: "home", in: places, by: -1))
    XCTAssertNil(ConditionsPaneSteps.place(from: nil, in: places, by: -1))
    // A place that is no longer offered steps as nowhere.
    XCTAssertEqual(ConditionsPaneSteps.place(from: "gone", in: places, by: 1), "home")
  }

  func testTimeStepsInQuartersWithNoLimitBelowTheFirst() {
    XCTAssertEqual(ConditionsPaneSteps.minutes(from: nil, by: 1), 15)
    XCTAssertEqual(ConditionsPaneSteps.minutes(from: 15, by: 1), 30)
    XCTAssertNil(ConditionsPaneSteps.minutes(from: 15, by: -1))
    XCTAssertNil(ConditionsPaneSteps.minutes(from: nil, by: -1))
    // Between steps it snaps the way the key points.
    XCTAssertEqual(ConditionsPaneSteps.minutes(from: 22, by: 1), 30)
    XCTAssertEqual(ConditionsPaneSteps.minutes(from: 22, by: -1), 15)
    XCTAssertEqual(ConditionsPaneSteps.minutes(from: 12 * 60, by: 1), 12 * 60)
  }

  func testExpiryReadsAsTheNearestStopAndSteps() {
    typealias Expiry = ConditionsPaneSteps.Expiry
    XCTAssertEqual(Expiry.nearest(to: nil, now: now, calendar: utc), .never)
    XCTAssertEqual(Expiry.nearest(to: now.addingTimeInterval(1800), now: now, calendar: utc), .oneHour)
    XCTAssertEqual(Expiry.nearest(to: now.addingTimeInterval(3 * 3600), now: now, calendar: utc), .fourHours)
    XCTAssertEqual(Expiry.never.stepped(by: 1), .oneHour)
    XCTAssertEqual(Expiry.never.stepped(by: -1), .never)
    XCTAssertEqual(Expiry.endOfDay.stepped(by: 1), .endOfDay)
    XCTAssertEqual(
      Expiry.endOfDay.date(now: now, calendar: utc), Date(timeIntervalSince1970: 1_792_108_800))
  }

  func testTypedTimesReadAsDurationsOrClockTimes() {
    func typed(_ text: String) -> TimeInterval? {
      ConditionsPaneSteps.time(typed: text, now: now, calendar: utc).map { $0.timeIntervalSince(now) }
    }
    XCTAssertEqual(typed("45"), 45 * 60)
    XCTAssertEqual(typed("90m"), 90 * 60)
    XCTAssertEqual(typed("1h"), 3600)
    XCTAssertEqual(typed("1h30"), 90 * 60)
    XCTAssertEqual(typed("1h 30m"), 90 * 60)
    XCTAssertEqual(typed("1.5h"), 90 * 60)
    // 17:00 today is 2h50m away; 9am has passed, so it is tomorrow's.
    XCTAssertEqual(typed("17:00"), (2 * 60 + 50) * 60)
    XCTAssertEqual(typed("5pm"), (2 * 60 + 50) * 60)
    XCTAssertEqual(typed("5:30pm"), (3 * 60 + 20) * 60)
    XCTAssertEqual(typed("9am"), (18 * 60 + 50) * 60)
    XCTAssertNil(typed(""))
    XCTAssertNil(typed("soon"))
    XCTAssertNil(typed("25:00"))
    XCTAssertNil(typed("0"))
  }

  func testTheTimeRowsSitBetweenTheConditionsAndTheNewRow() {
    let rows = ConditionsPaneLayout.rows(
      available: ["desk"], sections: [], folded: [], archived: [], showsArchived: false,
      hasPlaces: true, hasTimeLimit: false)
    XCTAssertEqual(rows, [.location, .available("desk"), .time, .expiry, .add])
    let timed = ConditionsPaneLayout.rows(
      available: [], sections: [], folded: [], archived: [], showsArchived: false,
      hasPlaces: false, hasTimeLimit: true)
    XCTAssertEqual(timed, [.time, .finishOnly, .expiry, .add])
    XCTAssertEqual(ConditionsPaneLayout.landing(.finishOnly, in: rows, sections: []), .time)
  }
}
