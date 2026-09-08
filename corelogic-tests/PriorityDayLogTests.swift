import XCTest

@testable import PriorityCore

final class DayBoundaryTests: XCTestCase {

  /// Fixed UTC Gregorian calendar so these assertions don't depend on the
  /// machine's locale or timezone.
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
  }

  // MARK: - dayKey

  func testWorkAfterMidnightBelongsToThePreviousDay() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 15, 1, 30)), "2026-08-14")
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 14, 3, 59)), "2026-08-13")
  }

  func testWorkAfterRolloverBelongsToTheCurrentDay() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 14, 4, 0)), "2026-08-14")
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 14, 23, 59)), "2026-08-14")
  }

  func testMidnightRolloverMatchesTheCalendarDay() {
    let boundary = DayBoundary(rolloverHour: 0, calendar: calendar)
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 15, 0, 1)), "2026-08-15")
    XCTAssertEqual(boundary.dayKey(for: date(2026, 8, 14, 23, 59)), "2026-08-14")
  }

  func testRolloverHourIsClampedToAValidHour() {
    XCTAssertEqual(DayBoundary(rolloverHour: -5, calendar: calendar).rolloverHour, 0)
    XCTAssertEqual(DayBoundary(rolloverHour: 99, calendar: calendar).rolloverHour, 23)
  }

  // MARK: - Idempotence
  //
  // The anchors these produce get passed back in as day identifiers — into
  // `dayKey`, `summary(on:)`, and note paths. When `logicalDay` anchored to
  // midnight it sat *before* its own rollover, so every re-key shifted it
  // another day earlier and the chart's buckets were labelled a day off.

  func testLogicalDayIsIdempotent() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let once = boundary.logicalDay(for: date(2026, 8, 14, 10))
    XCTAssertEqual(boundary.logicalDay(for: once), once)
  }

  func testDayKeyOfALogicalDayIsThatSameDay() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let anchor = boundary.logicalDay(for: date(2026, 8, 14, 10))
    XCTAssertEqual(boundary.dayKey(for: anchor), "2026-08-14")
  }

  func testDayKeyOfALogicalDayIsStableAtMidnightRollover() {
    let boundary = DayBoundary(rolloverHour: 0, calendar: calendar)
    let anchor = boundary.logicalDay(for: date(2026, 8, 14, 10))
    XCTAssertEqual(boundary.dayKey(for: anchor), "2026-08-14")
  }

  func testWeekStartIsIdempotent() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let once = boundary.weekStart(for: date(2026, 8, 14, 10))
    XCTAssertEqual(boundary.weekStart(for: once), once)
  }

  func testSteppingBackADayAndRekeyingLandsOnYesterday() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let yesterday = boundary.day(offsetBy: -1, from: date(2026, 8, 14, 10))
    XCTAssertEqual(boundary.dayKey(for: yesterday), "2026-08-13")
  }

  // MARK: - Ranges

  func testDaysEndingOnProducesAnInclusiveOldestFirstWindow() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let days = boundary.days(endingOn: date(2026, 8, 14, 10), count: 3)
    XCTAssertEqual(days.map { boundary.dayKey(for: $0) }, ["2026-08-12", "2026-08-13", "2026-08-14"])
  }

  func testDaysEndingOnIsEmptyForANonPositiveCount() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    XCTAssertTrue(boundary.days(endingOn: date(2026, 8, 14, 10), count: 0).isEmpty)
  }

  func testWeeksEndingOnStepsBackOneWeekAtATime() {
    let boundary = DayBoundary(rolloverHour: 4, calendar: calendar)
    let weeks = boundary.weeks(endingOn: date(2026, 8, 14, 10), count: 3)
    XCTAssertEqual(weeks.count, 3)
    let gap = weeks[1].timeIntervalSince(weeks[0])
    XCTAssertEqual(gap, 7 * 24 * 3600, accuracy: 3600)
  }
}

final class DayLogAggregatorTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private var boundary: DayBoundary {
    DayBoundary(rolloverHour: 4, calendar: calendar)
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
  }

  // MARK: - netCompletions

  func testReopenCancelsTheMatchingCompletion() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 14, 10)),
      .reopened(taskId: 1, title: "A", at: date(2026, 8, 14, 11)),
    ]
    XCTAssertTrue(DayLogAggregator.netCompletions(events).isEmpty)
  }

  func testReopenOnlyCancelsItsOwnTask() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 14, 10)),
      .completed(taskId: 2, title: "B", at: date(2026, 8, 14, 11)),
      .reopened(taskId: 1, title: "A", at: date(2026, 8, 14, 12)),
    ]
    XCTAssertEqual(DayLogAggregator.netCompletions(events).map(\.taskId), [2])
  }

  /// The point of netting across the whole log rather than per day: undoing
  /// yesterday's completion has to empty *yesterday*, not subtract one from
  /// today.
  func testReopenTheNextDayRemovesThePreviousDaysCompletion() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 13, 10)),
      .reopened(taskId: 1, title: "A", at: date(2026, 8, 14, 9)),
    ]
    let yesterday = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 13, 20))
    let today = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 12))
    XCTAssertEqual(yesterday.completedCount, 0)
    XCTAssertEqual(today.completedCount, 0)
  }

  func testReopenCancelsOnlyTheMostRecentCompletionOfARepeatingTask() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 12, 10)),
      .completed(taskId: 1, title: "A", at: date(2026, 8, 13, 10)),
      .reopened(taskId: 1, title: "A", at: date(2026, 8, 14, 9)),
    ]
    let surviving = DayLogAggregator.netCompletions(events)
    XCTAssertEqual(surviving.count, 1)
    XCTAssertEqual(boundary.dayKey(for: surviving[0].at), "2026-08-12")
  }

  func testInvalidationIsNeverCountedAsACompletion() {
    let events: [DayLogEvent] = [
      .invalidated(taskId: 1, title: "Abandoned", at: date(2026, 8, 14, 10))
    ]
    XCTAssertTrue(DayLogAggregator.netCompletions(events).isEmpty)
  }

  // MARK: - Buckets

  func testDailyBucketsZeroFillDaysWithNoActivity() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "A", at: date(2026, 8, 12, 10)),
      .dailyCompleted(dailyId: "b", title: "B", at: date(2026, 8, 14, 10)),
      .dailyCompleted(dailyId: "c", title: "C", at: date(2026, 8, 14, 15)),
    ]
    let buckets = DayLogAggregator.dailyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), days: 3)
    XCTAssertEqual(buckets.map(\.key), ["2026-08-12", "2026-08-13", "2026-08-14"])
    XCTAssertEqual(buckets.map(\.completed), [1, 0, 2])
  }

  func testDailyBucketsAlwaysReturnTheRequestedWindowLength() {
    let buckets = DayLogAggregator.dailyBuckets(
      events: [], boundary: boundary, endingOn: date(2026, 8, 14, 20), days: 30)
    XCTAssertEqual(buckets.count, 30)
    XCTAssertTrue(buckets.allSatisfy { $0.completed == 0 })
  }

  func testWeeklyBucketsAggregateAcrossTheWeek() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "A", at: date(2026, 8, 10, 10)),
      .dailyCompleted(dailyId: "b", title: "B", at: date(2026, 8, 12, 10)),
      .dailyCompleted(dailyId: "c", title: "C", at: date(2026, 8, 14, 10)),
    ]
    let buckets = DayLogAggregator.weeklyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), weeks: 2)
    XCTAssertEqual(buckets.count, 2)
    XCTAssertEqual(buckets.last?.completed, 3)
  }

  // MARK: - Summary

  func testSummaryCountsOnlyTheRequestedDay() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "Yesterday", at: date(2026, 8, 13, 10)),
      .completed(taskId: 2, title: "Today", at: date(2026, 8, 14, 10)),
    ]
    let summary = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.completed.map(\.taskId), [2])
    XCTAssertEqual(summary.key, "2026-08-14")
  }

  func testUnfinishedExcludesCompletedDeferredAndInvalidatedTasks() {
    let events: [DayLogEvent] = [
      .planSnapshot(taskIds: [1, 2, 3, 4], at: date(2026, 8, 14, 4)),
      .completed(taskId: 1, title: "Done", at: date(2026, 8, 14, 10)),
      .deferred(taskId: 2, title: "Pushed", at: date(2026, 8, 14, 11)),
      .invalidated(taskId: 3, title: "Dropped", at: date(2026, 8, 14, 12)),
    ]
    let summary = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.plannedTaskIds, [1, 2, 3, 4])
    XCTAssertEqual(summary.unfinishedTaskIds, [4])
    XCTAssertEqual(summary.deferredTaskIds, [2])
    XCTAssertEqual(summary.invalidatedTaskIds, [3])
  }

  func testASecondSnapshotOnTheSameDayWins() {
    let events: [DayLogEvent] = [
      .planSnapshot(taskIds: [1], at: date(2026, 8, 14, 4)),
      .planSnapshot(taskIds: [1, 2], at: date(2026, 8, 14, 9)),
    ]
    let summary = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.plannedTaskIds, [1, 2])
  }

  func testFocusSecondsSumAcrossSessions() {
    let events: [DayLogEvent] = [
      .focusSessionEnded(taskId: 1, title: "A", seconds: 1500, at: date(2026, 8, 14, 10)),
      .focusSessionEnded(taskId: 1, title: "A", seconds: 1500, at: date(2026, 8, 14, 11)),
      .focusSessionEnded(taskId: 1, title: "A", seconds: 900, at: date(2026, 8, 13, 11)),
    ]
    let summary = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.focusSeconds, 3000)
  }

  func testEmptyDaySummaryIsZeroedRatherThanMissing() {
    let summary = DayLogAggregator.summary(
      events: [], boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.completedCount, 0)
    XCTAssertEqual(summary.plannedCount, 0)
    XCTAssertEqual(summary.focusSeconds, 0)
  }

  // MARK: - History probes

  func testRecordedDayCountCountsDistinctDays() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 12, 10)),
      .completed(taskId: 2, title: "B", at: date(2026, 8, 12, 18)),
      .completed(taskId: 3, title: "C", at: date(2026, 8, 14, 10)),
    ]
    XCTAssertEqual(DayLogAggregator.recordedDayCount(events: events, boundary: boundary), 2)
  }

  func testFirstRecordedDayIsTheEarliestLogicalDay() {
    let events: [DayLogEvent] = [
      .completed(taskId: 2, title: "B", at: date(2026, 8, 14, 10)),
      .completed(taskId: 1, title: "A", at: date(2026, 8, 12, 10)),
    ]
    let first = DayLogAggregator.firstRecordedDay(events: events, boundary: boundary)
    XCTAssertEqual(first.map { boundary.dayKey(for: $0) }, "2026-08-12")
  }

  func testFirstRecordedDayIsNilForAnEmptyLog() {
    XCTAssertNil(DayLogAggregator.firstRecordedDay(events: [], boundary: boundary))
  }
}

final class DayLogFormattingTests: XCTestCase {

  func testFocusDurationRendersEmDashForNothing() {
    XCTAssertEqual(DayLogFormatting.focusDuration(seconds: 0), "—")
  }

  func testFocusDurationUnderAnHourIsMinutes() {
    XCTAssertEqual(DayLogFormatting.focusDuration(seconds: 1500), "25m")
    // Never rounds a real session down to "0m".
    XCTAssertEqual(DayLogFormatting.focusDuration(seconds: 30), "1m")
  }

  func testFocusDurationOverAnHourSplitsHoursAndMinutes() {
    XCTAssertEqual(DayLogFormatting.focusDuration(seconds: 3600), "1h")
    XCTAssertEqual(DayLogFormatting.focusDuration(seconds: 6000), "1h 40m")
  }

  func testPluralisation() {
    XCTAssertEqual(DayLogFormatting.pluralised(1, "task", "tasks"), "1 task")
    XCTAssertEqual(DayLogFormatting.pluralised(2, "task", "tasks"), "2 tasks")
    XCTAssertEqual(DayLogFormatting.pluralised(0, "task", "tasks"), "0 tasks")
  }
}

final class DayLogFileStoreTests: XCTestCase {

  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("daylog-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testAppendedEventsRoundTripInOrder() throws {
    let store = DayLogFileStore(directoryURL: directoryURL)
    let first = DayLogEvent.completed(taskId: 1, title: "First", at: Date(timeIntervalSince1970: 100))
    let second = DayLogEvent.completed(
      taskId: 2, title: "Second", at: Date(timeIntervalSince1970: 200))

    try store.append(first)
    try store.append(second)

    let loaded = store.loadAll()
    XCTAssertEqual(loaded.map(\.taskId), [1, 2])
    XCTAssertEqual(loaded.map(\.title), ["First", "Second"])
  }

  func testFocusSessionFieldsSurviveTheRoundTrip() throws {
    let store = DayLogFileStore(directoryURL: directoryURL)
    try store.append(
      .focusSessionEnded(taskId: 7, title: "Deep work", seconds: 1500, at: Date()))
    try store.append(.planSnapshot(taskIds: [1, 2, 3], at: Date()))

    let loaded = store.loadAll()
    XCTAssertEqual(loaded.first?.durationSeconds, 1500)
    XCTAssertEqual(loaded.last?.plannedTaskIds, [1, 2, 3])
  }

  func testAMissingFileIsAnEmptyLogRatherThanAnError() {
    let store = DayLogFileStore(directoryURL: directoryURL)
    XCTAssertTrue(store.loadAll().isEmpty)
  }

  /// A torn write must cost one event, not the whole history — that is the
  /// entire reason the format is one JSON object per line.
  func testACorruptLineIsSkippedRatherThanFailingTheLoad() throws {
    let store = DayLogFileStore(directoryURL: directoryURL)
    try store.append(.completed(taskId: 1, title: "Good", at: Date()))

    let handle = try FileHandle(forWritingTo: store.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"kind\":\"comple".utf8))
    try handle.close()

    XCTAssertEqual(store.loadAll().map(\.taskId), [1])
  }

  func testAppendingAfterACorruptTailStillWorks() throws {
    let store = DayLogFileStore(directoryURL: directoryURL)
    try store.append(.completed(taskId: 1, title: "Good", at: Date()))

    let handle = try FileHandle(forWritingTo: store.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("garbage\n".utf8))
    try handle.close()

    try store.append(.completed(taskId: 2, title: "Later", at: Date()))
    XCTAssertEqual(store.loadAll().map(\.taskId), [1, 2])
  }
}

/// The streak behind `CompletionMilestone.dailyStreak`.
///
/// Today is excluded on purpose, which is the only subtle thing here: the task
/// completion path classifies its milestone *before* the close is recorded and
/// the daily path *after*, so a streak that counted today would come out a day
/// apart depending on which funnel asked. Callers add the day they are in the
/// middle of earning.
final class DayLogStreakTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private var boundary: DayBoundary {
    DayBoundary(rolloverHour: 4, calendar: calendar)
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  func testNoHistoryIsNoStreak() {
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: [], boundary: boundary, now: date(2026, 8, 19)),
      0
    )
  }

  func testConsecutiveDaysAccumulate() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 16)),
      .completed(taskId: 2, title: "B", at: date(2026, 8, 17)),
      .completed(taskId: 3, title: "C", at: date(2026, 8, 18)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19)),
      3
    )
  }

  /// The whole point of a streak is that it can be lost.
  func testAGapEndsTheStreak() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 15)),
      // Nothing on the 16th.
      .completed(taskId: 2, title: "B", at: date(2026, 8, 17)),
      .completed(taskId: 3, title: "C", at: date(2026, 8, 18)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19)),
      2
    )
  }

  /// Today is deliberately not counted — see the type's doc comment.
  func testTodaysOwnCompletionsAreExcluded() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 19)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19, 22)),
      0
    )
  }

  /// A day spent entirely on recurring intentions is still a day you showed up.
  func testDailyTicksKeepAStreakAlive() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 17)),
      .dailyCompleted(dailyId: "habit", title: "Read", at: date(2026, 8, 18)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19)),
      2
    )
  }

  /// A tick taken back the same day leaves the day empty, so it must not prop
  /// the streak up.
  func testAnUnTickedDailyDoesNotCountAsADay() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "habit", title: "Read", at: date(2026, 8, 18, 9)),
      .dailyUncompleted(dailyId: "habit", title: "Read", at: date(2026, 8, 18, 11)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19)),
      0
    )
  }

  /// A completion undone on a later day retroactively empties the day it was
  /// made on, exactly as it does in the chart.
  func testAReopenedTaskCannotHoldADayOpen() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "A", at: date(2026, 8, 18)),
      .reopened(taskId: 1, title: "A", at: date(2026, 8, 19, 9)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19, 12)),
      0
    )
  }

  /// Work after midnight belongs to the previous logical day, so a 1am
  /// completion must extend yesterday's streak rather than start a new one.
  func testTheStreakFollowsTheRolloverHour() {
    let events: [DayLogEvent] = [
      // 1am on the 19th is still the 18th under a 4am rollover.
      .completed(taskId: 1, title: "A", at: date(2026, 8, 19, 1)),
    ]
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 8, 19, 12)),
      1
    )
  }

  /// The walk is bounded by the log's own history, so a long run terminates
  /// rather than counting back to the epoch.
  func testALongRunTerminates() {
    let events = (1...20).map {
      DayLogEvent.completed(taskId: $0, title: "T\($0)", at: date(2026, 7, $0))
    }
    XCTAssertEqual(
      DayLogAggregator.priorCompletionStreak(
        events: events, boundary: boundary, now: date(2026, 7, 21)),
      20
    )
  }
}
