import XCTest

@testable import TaktCore

/// The add field's trailing tokens. The property that matters most is the one
/// that is easiest to break: a title is only ever trimmed from the end, and
/// only while every word being trimmed is something the field understands.
final class TaskCaptureSyntaxTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// Tuesday 29 September 2026, mid-morning.
  private var now: Date { date(2026, 9, 29, hour: 10) }

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  private func parse(_ text: String) -> TaskCapture {
    TaskCapture.parse(text, now: now, calendar: calendar)
  }

  func testAPlainTitleIsLeftExactlyAsTyped() {
    XCTAssertEqual(parse("  Write the release notes "), TaskCapture(title: "Write the release notes"))
  }

  func testCheckvistsCaretMarksADueDayToo() {
    let capture = parse("Ring the bank ^fri")
    XCTAssertEqual(capture.title, "Ring the bank")
    XCTAssertEqual(capture.dueAt, date(2026, 10, 2))
    XCTAssertEqual(parse("Ring the bank ^fri").dueAt, parse("Ring the bank @fri").dueAt)
  }

  func testEveryKindOfTokenAtTheEnd() {
    let capture = parse("Write the release notes 45m #work @fri !1")
    XCTAssertEqual(capture.title, "Write the release notes")
    XCTAssertEqual(capture.estimateSeconds, 45 * 60)
    XCTAssertEqual(capture.dueAt, date(2026, 10, 2))
    XCTAssertEqual(capture.tags, ["work"])
    XCTAssertEqual(capture.priority, 1)
    XCTAssertTrue(capture.hasDetails)
  }

  func testTokensInTheMiddleOfATitleStayInIt() {
    XCTAssertEqual(parse("Buy 2m of cable"), TaskCapture(title: "Buy 2m of cable"))
    XCTAssertEqual(parse("Read 30 pages"), TaskCapture(title: "Read 30 pages"))
  }

  func testAWordTheFieldDoesNotKnowEndsTheScan() {
    let capture = parse("Call mum @home 10m")
    XCTAssertEqual(capture.title, "Call mum @home")
    XCTAssertEqual(capture.estimateSeconds, 10 * 60)
  }

  func testTheFirstWordIsAlwaysTheTitle() {
    XCTAssertEqual(parse("30m"), TaskCapture(title: "30m"))
    let capture = parse("30m #admin")
    XCTAssertEqual(capture.title, "30m")
    XCTAssertEqual(capture.tags, ["admin"])
  }

  func testEstimateSpellings() {
    let cases: [(String, Int?)] = [
      ("30m", 30), ("90min", 90), ("5mins", 5), ("1h", 60), ("2hrs", 120), ("1.5h", 90),
      ("1h30m", 90), ("1h30", 90), ("~20m", 20), ("2hours", 120), ("45minutes", 45),
      ("0m", nil), ("25h", nil), ("1h75m", nil), ("1.5h30", nil), ("m", nil), ("10", nil),
    ]
    for (word, minutes) in cases {
      XCTAssertEqual(
        TaskCaptureToken.estimate(word), minutes.map { $0 * 60 }, "\(word) should be \(String(describing: minutes))m")
    }
  }

  func testDueSpellings() {
    let cases: [(String, Date?)] = [
      ("today", date(2026, 9, 29)), ("tod", date(2026, 9, 29)),
      ("tomorrow", date(2026, 9, 30)), ("tmr", date(2026, 9, 30)),
      // Today is a Tuesday, so "tue" is today rather than a week away.
      ("tue", date(2026, 9, 29)), ("wednesday", date(2026, 9, 30)), ("mon", date(2026, 10, 5)),
      ("3d", date(2026, 10, 2)), ("2w", date(2026, 10, 13)),
      ("2026-12-25", date(2026, 12, 25)), ("2027-1-4", date(2027, 1, 4)),
      ("2026-02-31", nil), ("home", nil), ("0d", nil),
    ]
    for (word, expected) in cases {
      XCTAssertEqual(TaskCaptureToken.due(word, now: now, calendar: calendar), expected, word)
    }
  }

  func testDueNeedsItsAt() {
    XCTAssertEqual(parse("Stand up tomorrow"), TaskCapture(title: "Stand up tomorrow"))
    XCTAssertEqual(parse("Stand up @tomorrow").dueAt, date(2026, 9, 30))
  }

  func testTagsMustStartWithALetter() {
    XCTAssertEqual(parse("Fix issue #123"), TaskCapture(title: "Fix issue #123"))
    XCTAssertEqual(parse("Chapter #1"), TaskCapture(title: "Chapter #1"))
    XCTAssertEqual(parse("Plan #q4-launch").tags, ["q4-launch"])
  }

  func testSeveralTagsKeepTheirOrderAndDropRepeats() {
    let capture = parse("Plan offsite #Work #travel #work")
    XCTAssertEqual(capture.title, "Plan offsite")
    XCTAssertEqual(capture.tags, ["Work", "travel"])
  }

  func testPriorityIsOneToFour() {
    XCTAssertEqual(parse("Ship it !4").priority, 4)
    XCTAssertEqual(parse("Ship it !5"), TaskCapture(title: "Ship it !5"))
    XCTAssertEqual(parse("Ship it !"), TaskCapture(title: "Ship it !"))
  }

  /// The last one typed wins, and the earlier one stays visible in the title
  /// rather than disappearing.
  func testASecondTokenOfOneKindStaysInTheTitle() {
    let capture = parse("Draft 30m 45m")
    XCTAssertEqual(capture.title, "Draft 30m")
    XCTAssertEqual(capture.estimateSeconds, 45 * 60)
  }

  func testLabelsNameWhatWasFound() {
    XCTAssertEqual(
      parse("Write notes 1h30m @tomorrow #work !2").detailLabels(now: now, calendar: calendar),
      ["1h 30m", "Tomorrow", "#work", "!2"])
    XCTAssertEqual(parse("Book flights @2026-10-02").detailLabels(now: now, calendar: calendar), ["Fri 2 Oct"])
    XCTAssertEqual(parse("Renew passport @2027-03-01").detailLabels(now: now, calendar: calendar), ["1 Mar 2027"])
  }

  func testWaitColonFilesItAsWaitingOnSomeone() {
    let capture = parse("Contract signed wait:Sam ^fri")
    XCTAssertEqual(capture.title, "Contract signed")
    XCTAssertEqual(capture.waitingOn, "Sam")
    XCTAssertEqual(capture.dueAt, date(2026, 10, 2))
    XCTAssertEqual(parse("Can't wait").title, "Can't wait", "a bare word is never a token")
    XCTAssertNil(parse("Ask wait:").waitingOn)
  }
}
