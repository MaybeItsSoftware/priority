import XCTest

@testable import PriorityCore

final class DailyModelTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  /// 2026-08-14 is a Friday, 2026-08-15 a Saturday.
  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  func testAnEveryDayDailyIsDueOnAWeekend() {
    let daily = Daily(title: "Stretch")
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 15), calendar: calendar))
  }

  func testAWeekdaysDailyIsNotDueOnSaturday() {
    let daily = Daily(title: "Standup", activeWeekdays: Daily.mondayToFriday)
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 14), calendar: calendar))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 15), calendar: calendar))
  }

  func testAnArchivedDailyIsNeverDue() {
    let daily = Daily(title: "Old habit", archivedAt: date(2026, 8, 1))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 14), calendar: calendar))
  }

  /// An empty weekday set would make a daily permanently invisible with no way
  /// to get it back from the UI, so it is coerced rather than stored.
  func testAnEmptyWeekdaySetFallsBackToEveryDay() {
    let daily = Daily(title: "Anything", activeWeekdays: [])
    XCTAssertEqual(daily.activeWeekdays, Daily.allWeekdays)
  }

  func testScheduleLabelNamesTheCommonCases() {
    XCTAssertEqual(Daily(title: "A").scheduleLabel, "Every day")
    XCTAssertEqual(
      Daily(title: "B", activeWeekdays: Daily.mondayToFriday).scheduleLabel, "Weekdays")
    XCTAssertEqual(Daily(title: "C", activeWeekdays: [2, 4]).scheduleLabel, "Mon Wed")
    XCTAssertEqual(Daily(title: "D", activeWeekdays: Daily.weekend).scheduleLabel, "Weekends")
  }

  // MARK: - Rotating schedules

  /// The point of an interval schedule: it walks through the week rather than
  /// sitting on the same days, so weekday membership says nothing about it.
  func testAnIntervalDailyIsDueEveryNthDayRegardlessOfWeekday() {
    var daily = Daily(title: "Water the plants")
    daily.setSchedule(.everyNDays(3), anchor: date(2026, 8, 14))

    XCTAssertTrue(daily.isDue(on: date(2026, 8, 14), calendar: calendar))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 15), calendar: calendar))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 16), calendar: calendar))
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 17), calendar: calendar))
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 20), calendar: calendar))
  }

  /// The cycle runs backwards from the anchor too, so the history behind a
  /// newly-anchored daily isn't a run of days it was "never expected on".
  func testTheCycleExtendsBackwardsFromTheAnchor() {
    var daily = Daily(title: "Bins")
    daily.setSchedule(.everyNDays(2), anchor: date(2026, 8, 14))

    XCTAssertTrue(daily.isDue(on: date(2026, 8, 12), calendar: calendar))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 13), calendar: calendar))
  }

  /// Set at 22:00, asked about at 09:00 — the times differ, only the days count.
  func testDuenessIgnoresTheTimeOfDayWithinEachDay() {
    var daily = Daily(title: "Long run")
    daily.setSchedule(.everyNDays(2), anchor: date(2026, 8, 14, 22))
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 16, 9), calendar: calendar))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 17, 9), calendar: calendar))
  }

  func testAnEveryOneDayCycleIsJustEveryDay() {
    var daily = Daily(title: "Stretch")
    daily.setSchedule(.everyNDays(1), anchor: date(2026, 8, 14))
    XCTAssertTrue(daily.isEveryDay)
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 15), calendar: calendar))
    XCTAssertEqual(daily.scheduleLabel, "Every day")
  }

  func testAnArchivedIntervalDailyIsStillNeverDue() {
    var daily = Daily(title: "Old cycle", archivedAt: date(2026, 8, 1))
    daily.setSchedule(.everyNDays(2), anchor: date(2026, 8, 14))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 14), calendar: calendar))
  }

  func testIntervalScheduleLabels() {
    XCTAssertEqual(Daily.scheduleLabel(for: .everyNDays(2)), "Every other day")
    XCTAssertEqual(Daily.scheduleLabel(for: .everyNDays(3)), "Every 3 days")
    XCTAssertEqual(Daily.scheduleLabel(for: .weekdays(Daily.mondayToFriday)), "Weekdays")
  }

  /// A hand-edited file (or a future client) can put anything in the field; a
  /// daily that never comes round again is worse than a clamped one.
  func testAnAbsurdIntervalIsClampedRatherThanHonoured() {
    XCTAssertEqual(Daily(title: "A", intervalDays: 0).intervalDays, 1)
    XCTAssertEqual(Daily(title: "B", intervalDays: 10_000).intervalDays, 366)
  }

  /// Weekdays stay stored while a cycle is running, so switching back restores
  /// what was chosen rather than resetting to every day.
  func testSwitchingToACycleAndBackKeepsTheWeekdaySet() {
    var daily = Daily(title: "Gym", activeWeekdays: [2, 4, 6])
    daily.setSchedule(.everyNDays(3), anchor: date(2026, 8, 14))
    XCTAssertEqual(daily.activeWeekdays, [2, 4, 6])

    daily.setSchedule(.weekdays(daily.activeWeekdays))
    XCTAssertNil(daily.intervalDays)
    XCTAssertNil(daily.intervalAnchor)
    XCTAssertEqual(daily.scheduleLabel, "Mon Wed Fri")
  }

  /// Changing the length re-spaces the cycle from where it already was;
  /// re-anchoring on every edit would silently restart the habit.
  func testChangingTheIntervalKeepsTheExistingAnchor() {
    var daily = Daily(title: "Bins")
    daily.setSchedule(.everyNDays(2), anchor: date(2026, 8, 14))
    daily.setSchedule(.everyNDays(4), anchor: date(2026, 8, 20))
    XCTAssertEqual(daily.intervalAnchor, date(2026, 8, 14))
    XCTAssertTrue(daily.isDue(on: date(2026, 8, 18), calendar: calendar))
  }

  /// Files written before cycles existed have neither field, and must keep
  /// behaving exactly as they did.
  func testADailyWithoutAnIntervalIsUnchanged() {
    let daily = Daily(title: "Standup", activeWeekdays: Daily.mondayToFriday)
    XCTAssertNil(daily.intervalDays)
    XCTAssertEqual(daily.schedule, .weekdays(Daily.mondayToFriday))
    XCTAssertFalse(daily.isDue(on: date(2026, 8, 15), calendar: calendar))
  }
}

final class DailyCollectionTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
  }

  func testAddAssignsAnIncreasingSortIndex() {
    var collection = DailyCollection()
    collection.add(Daily(title: "First"))
    collection.add(Daily(title: "Second"))
    XCTAssertEqual(collection.active.map(\.title), ["First", "Second"])
    XCTAssertEqual(collection.active.map(\.sortIndex), [0, 1])
  }

  func testArchivingKeepsTheRecordButDropsItFromActive() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "Gone"))
    collection.archive(id: "a")
    XCTAssertTrue(collection.active.isEmpty)
    // Still resolvable, so a past day that ticked it renders with a title.
    XCTAssertEqual(collection.daily(withId: "a")?.title, "Gone")
  }

  /// What makes archiving safe to offer as "delete" in the UI: it is
  /// reversible, so deleting needs no confirmation step.
  func testRestoringPutsAnArchivedDailyBack() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "Back again"))
    collection.archive(id: "a")
    collection.restore(id: "a")

    XCTAssertEqual(collection.active.map(\.id), ["a"])
    XCTAssertNil(collection.daily(withId: "a")?.archivedAt)
  }

  /// The sort index is untouched by the round trip, so a restored daily lands
  /// back in the middle of the routine rather than at the end of it.
  func testRestoringKeepsThePositionItHad() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "First"))
    collection.add(Daily(id: "b", title: "Second"))
    collection.add(Daily(id: "c", title: "Third"))

    collection.archive(id: "b")
    XCTAssertEqual(collection.active.map(\.id), ["a", "c"])

    collection.restore(id: "b")
    XCTAssertEqual(collection.active.map(\.id), ["a", "b", "c"])
  }

  /// A daily is only due when it is active, so archiving takes it off today's
  /// checklist and restoring puts it back — the behaviour the Daily view's
  /// delete depends on.
  func testAnArchivedDailyIsNotDueAndARestoredOneIs() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "Every day"))
    let today = date(2026, 8, 18)

    collection.archive(id: "a")
    XCTAssertTrue(collection.due(on: today, calendar: calendar).isEmpty)

    collection.restore(id: "a")
    XCTAssertEqual(collection.due(on: today, calendar: calendar).map(\.id), ["a"])
  }

  func testDueFiltersBySchedule() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "Every day"))
    collection.add(Daily(id: "b", title: "Weekdays", activeWeekdays: Daily.mondayToFriday))
    // Saturday.
    let saturday = collection.due(on: date(2026, 8, 15), calendar: calendar)
    XCTAssertEqual(saturday.map(\.id), ["a"])
  }

  func testDueFiltersByRotatingSchedule() {
    var collection = DailyCollection()
    var rotating = Daily(id: "a", title: "Every third day")
    rotating.setSchedule(.everyNDays(3), anchor: date(2026, 8, 15))
    collection.add(rotating)
    collection.add(Daily(id: "b", title: "Every day"))

    XCTAssertEqual(collection.due(on: date(2026, 8, 15), calendar: calendar).map(\.id), ["a", "b"])
    XCTAssertEqual(collection.due(on: date(2026, 8, 16), calendar: calendar).map(\.id), ["b"])
    XCTAssertEqual(collection.due(on: date(2026, 8, 18), calendar: calendar).map(\.id), ["a", "b"])
  }

  func testMoveReordersAndRenumbers() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "A"))
    collection.add(Daily(id: "b", title: "B"))
    collection.add(Daily(id: "c", title: "C"))

    collection.move(id: "c", by: -2)
    XCTAssertEqual(collection.active.map(\.id), ["c", "a", "b"])
    XCTAssertEqual(collection.active.map(\.sortIndex), [0, 1, 2])
  }

  func testMovingPastTheEndClampsRatherThanWrapping() {
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "A"))
    collection.add(Daily(id: "b", title: "B"))

    collection.move(id: "a", by: 99)
    XCTAssertEqual(collection.active.map(\.id), ["b", "a"])
  }
}

final class DailyDefinitionsStoreTests: XCTestCase {

  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dailies-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testDailiesRoundTrip() throws {
    let store = DailyDefinitionsStore(directoryURL: directoryURL)
    var collection = DailyCollection()
    collection.add(Daily(id: "a", title: "Read", activeWeekdays: Daily.mondayToFriday))
    try store.save(collection)

    let loaded = store.load()
    XCTAssertEqual(loaded.dailies.count, 1)
    XCTAssertEqual(loaded.dailies.first?.title, "Read")
    XCTAssertEqual(loaded.dailies.first?.activeWeekdays, Daily.mondayToFriday)
  }

  func testAMissingFileIsAnEmptySetRatherThanAnError() {
    let store = DailyDefinitionsStore(directoryURL: directoryURL)
    XCTAssertTrue(store.load().dailies.isEmpty)
  }

  func testACorruptFileDoesNotCrashTheLoad() throws {
    let store = DailyDefinitionsStore(directoryURL: directoryURL)
    try Data("not json".utf8).write(to: store.fileURL)
    XCTAssertTrue(store.load().dailies.isEmpty)
  }
}

final class DailyTickAggregationTests: XCTestCase {

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

  func testATickIsRecordedForItsDay() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 10))
    ]
    XCTAssertEqual(
      DayLogAggregator.completedDailyIds(
        events: events, boundary: boundary, on: date(2026, 8, 14, 20)),
      ["a"]
    )
  }

  func testUnTickingTheSameDayCancelsTheTick() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 10)),
      .dailyUncompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 11)),
    ]
    XCTAssertTrue(
      DayLogAggregator.completedDailyIds(
        events: events, boundary: boundary, on: date(2026, 8, 14, 20)
      ).isEmpty
    )
  }

  /// The defining difference between a daily and a task. A task reopen reaches
  /// back to whichever day the completion happened on; a daily is a fresh
  /// question each day, so today's un-tick must not blank yesterday's square.
  func testUnTickingTodayCannotCancelYesterdaysTick() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 13, 10)),
      .dailyUncompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 9)),
    ]
    XCTAssertEqual(
      DayLogAggregator.completedDailyIds(
        events: events, boundary: boundary, on: date(2026, 8, 13, 20)),
      ["a"]
    )
    XCTAssertTrue(
      DayLogAggregator.completedDailyIds(
        events: events, boundary: boundary, on: date(2026, 8, 14, 20)
      ).isEmpty
    )
  }

  func testRetickingAfterAnUnTickCountsOnce() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 10)),
      .dailyUncompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 11)),
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 12)),
    ]
    let buckets = DayLogAggregator.dailyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), days: 1)
    XCTAssertEqual(buckets.map(\.completed), [1])
  }

  func testATickAfterMidnightBelongsToThePreviousDay() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 15, 1, 30))
    ]
    XCTAssertEqual(
      DayLogAggregator.completedDailyIds(
        events: events, boundary: boundary, on: date(2026, 8, 14, 20)),
      ["a"]
    )
  }

  // MARK: - Chart folding

  /// The chart plots the checklist it sits under, so a busy task day must not
  /// swamp it. Tasks used to be summed in alongside the ticks.
  func testChartCountsOnlyDailies() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "Task", at: date(2026, 8, 14, 10)),
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 11)),
      .dailyCompleted(dailyId: "b", title: "Walk", at: date(2026, 8, 14, 12)),
    ]
    let buckets = DayLogAggregator.dailyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), days: 1)
    XCTAssertEqual(buckets.map(\.completed), [2])
  }

  func testWeeklyChartCountsOnlyDailies() {
    let events: [DayLogEvent] = [
      .completed(taskId: 1, title: "Task", at: date(2026, 8, 12, 10)),
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 12, 11)),
    ]
    let buckets = DayLogAggregator.weeklyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), weeks: 1)
    XCTAssertEqual(buckets.last?.completed, 1)
  }

  func testWeeklyBucketsRollUpDailyTicksWithoutNettingAcrossDays() {
    // Ticked Monday, un-ticked Tuesday. If the netting ran across the week the
    // Tuesday un-tick would wipe the Monday tick and the bar would read 0.
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 10, 10)),
      .dailyUncompleted(dailyId: "a", title: "Read", at: date(2026, 8, 11, 10)),
    ]
    let buckets = DayLogAggregator.weeklyBuckets(
      events: events, boundary: boundary, endingOn: date(2026, 8, 14, 20), weeks: 1)
    XCTAssertEqual(buckets.last?.completed, 1)
  }

  func testDailyTicksDoNotLeakIntoTaskCompletions() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(2026, 8, 14, 10))
    ]
    // taskId is 0 on a daily event; it must not be mistaken for a task
    // completion in the "Done today" list.
    XCTAssertTrue(DayLogAggregator.netCompletions(events).isEmpty)
    let summary = DayLogAggregator.summary(
      events: events, boundary: boundary, on: date(2026, 8, 14, 20))
    XCTAssertEqual(summary.completedCount, 0)
    XCTAssertEqual(summary.completedDailyIds, ["a"])
  }

  /// The schema gained `dailyId` after the log format shipped. Lines written
  /// before it must still decode, or a year of history dies on an upgrade.
  func testAnEventWrittenBeforeDailyIdExistedStillDecodes() throws {
    let legacy = """
      {"at":"2026-08-14T10:00:00Z","kind":"completed","taskId":7,"title":"Old"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let event = try decoder.decode(DayLogEvent.self, from: Data(legacy.utf8))
    XCTAssertEqual(event.taskId, 7)
    XCTAssertNil(event.dailyId)
  }
}

final class DailyNoteDailiesRenderingTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private var boundary: DayBoundary {
    DayBoundary(rolloverHour: 4, calendar: calendar)
  }

  private func date(_ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: hour))!
  }

  func testTickedAndMissedDailiesBothAppear() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(10))
    ]
    let summary = DayLogAggregator.summary(events: events, boundary: boundary, on: date(20))
    let section = DailyNoteMarkdown.section(
      summary: summary,
      dailies: [Daily(id: "a", title: "Read"), Daily(id: "b", title: "Walk")]
    )
    XCTAssertTrue(section.contains("- [x] Read"))
    XCTAssertTrue(section.contains("- [ ] Walk"))
    XCTAssertTrue(section.contains("**1/2 dailies**"))
  }

  /// A day where the dailies got done is not a blank day, even with no tasks.
  func testADayWithOnlyDailiesIsNotReportedAsNothingRecorded() {
    let events: [DayLogEvent] = [
      .dailyCompleted(dailyId: "a", title: "Read", at: date(10))
    ]
    let summary = DayLogAggregator.summary(events: events, boundary: boundary, on: date(20))
    let section = DailyNoteMarkdown.section(
      summary: summary, dailies: [Daily(id: "a", title: "Read")])
    XCTAssertFalse(section.contains("_Nothing recorded._"))
  }

  func testAGenuinelyEmptyDayStillSaysNothingRecorded() {
    let summary = DayLogAggregator.summary(events: [], boundary: boundary, on: date(20))
    let section = DailyNoteMarkdown.section(summary: summary)
    XCTAssertTrue(section.contains("_Nothing recorded._"))
  }
}

/// The on-disk contract for `dailies.json`.
///
/// The Rust CLI writes this same file from a separate
/// process, so the serialised shape is a cross-implementation interface, not an
/// internal detail. These pin the two properties the Python side has to match.
final class DailyDefinitionsStoreFormatTests: XCTestCase {

  private func makeStore() -> (DailyDefinitionsStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dailies-format-\(UUID().uuidString)", isDirectory: true)
    return (DailyDefinitionsStore(directoryURL: directory), directory)
  }

  /// Dates are written as `yyyy-MM-ddTHH:mm:ssZ`, with no fractional seconds.
  ///
  /// The decoder uses `.iso8601`, which rejects fractional seconds, and
  /// `load()` turns any decode failure into an *empty* collection — so a writer
  /// that emits microseconds doesn't cause a visible error, it makes every
  /// daily silently vanish and the next save persist that emptiness.
  func testCreatedAtIsWrittenWithoutFractionalSeconds() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var collection = DailyCollection()
    collection.add(Daily(title: "Read"))
    try store.save(collection)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    let pattern = #""createdAt"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#
    XCTAssertNotNil(
      json.range(of: pattern, options: .regularExpression),
      "createdAt must be whole-second UTC; got:\n\(json)"
    )
  }

  /// A timestamp in the shape `datetime.isoformat()` produces must not be what
  /// the app writes, and must be recognised as unreadable if it ever appears —
  /// this is the exact string that wiped the fixture during development.
  func testFractionalSecondTimestampsFailToDecode() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let hostile = """
      {"version":1,"dailies":[{"id":"x","title":"Read","activeWeekdays":[1,2,3,4,5,6,7],\
      "sortIndex":0,"createdAt":"2026-08-15T16:08:31.149480+01:00"}]}
      """
    try hostile.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(
      store.load().dailies.isEmpty,
      "If this ever starts decoding, the Python server's format constraint can be relaxed."
    )
  }

  /// A daily on fixed weekdays writes neither interval field, so files written
  /// by this app stay byte-identical to what they were before cycles existed —
  /// and to what the Python and Rust servers write for the same daily.
  func testAWeekdayDailyWritesNoIntervalFields() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var collection = DailyCollection()
    collection.add(Daily(title: "Read"))
    try store.save(collection)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(json.contains("intervalDays"))
    XCTAssertFalse(json.contains("intervalAnchor"))
  }

  /// The anchor is a timestamp in the same whole-second UTC shape as
  /// `createdAt`, for the same reason: the decoder rejects fractional seconds,
  /// and a rejected decode empties the file rather than erroring.
  func testAnIntervalDailyRoundTripsWithAWholeSecondAnchor() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var collection = DailyCollection()
    var daily = Daily(id: "cycle", title: "Bins")
    daily.setSchedule(.everyNDays(3))
    collection.add(daily)
    try store.save(collection)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertNotNil(
      json.range(
        of: #""intervalAnchor"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#,
        options: .regularExpression),
      "intervalAnchor must be whole-second UTC; got:\n\(json)"
    )
    XCTAssertEqual(store.load().daily(withId: "cycle")?.intervalDays, 3)
    XCTAssertNotNil(store.load().daily(withId: "cycle")?.intervalAnchor)
  }

  /// Weekdays round-trip sorted, so the file is stable across saves and can be
  /// compared byte-for-byte with the one the MCP server writes.
  func testActiveWeekdaysAreWrittenInSortedOrder() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var collection = DailyCollection()
    collection.add(Daily(title: "Gym", activeWeekdays: [6, 2, 4]))
    try store.save(collection)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertNotNil(
      json.range(of: #""activeWeekdays"\s*:\s*\[\s*2,\s*4,\s*6\s*\]"#, options: .regularExpression),
      "activeWeekdays must be sorted; got:\n\(json)"
    )
  }
}
