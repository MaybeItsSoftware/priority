import Foundation
import PriorityWorkspace
import XCTest

/// Points for focused work: minutes spent, multiplied by how well it went.
final class WorkspaceFocusPointsTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var list: TaskList!
  private let calendar = Calendar(identifier: .gregorian)

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityPointsTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    list = try XCTUnwrap(store.inbox(in: workspace.id))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  // MARK: - The arithmetic

  func testAScoreIsMinutesTimesTheMultiplierToOneDecimalPlace() throws {
    XCTAssertEqual(FocusPoints.minutes(seconds: 1_500), 25)
    XCTAssertEqual(FocusPoints.minutes(seconds: 750), 12.5)
    // Not rounded down to 12: a short sitting should not be quietly shaved.
    XCTAssertEqual(FocusPoints.score(seconds: 750, multiplier: 1), 12.5)
    XCTAssertEqual(FocusPoints.score(seconds: 1_500, multiplier: 1.5), 37.5)
    XCTAssertEqual(FocusPoints.score(seconds: 1_500, multiplier: 0.5), 12.5)
    XCTAssertEqual(FocusPoints.score(seconds: 0, multiplier: 2), 0)
  }

  func testAnOutOfRangeOrNonsenseMultiplierCannotDistortTheTotals() throws {
    XCTAssertEqual(FocusPoints.clamped(multiplier: 900), FocusPoints.multiplierRange.upperBound)
    XCTAssertEqual(FocusPoints.clamped(multiplier: -3), FocusPoints.multiplierRange.lowerBound)
    // A nonsense multiplier falls back to ordinary work rather than throwing
    // the block's time away with it. Infinity counts as nonsense, not as "very
    // large": clamping it to the ceiling would reward a bad number.
    XCTAssertEqual(FocusPoints.clamped(multiplier: .nan), FocusQuality.solid.multiplier)
    XCTAssertEqual(FocusPoints.clamped(multiplier: .infinity), FocusQuality.solid.multiplier)
    XCTAssertEqual(FocusPoints.score(seconds: 600, multiplier: .infinity), 10)
  }

  func testScoresAreFormattedWithoutATrailingZero() throws {
    XCTAssertEqual(FocusPoints.formatted(25), "25")
    XCTAssertEqual(FocusPoints.formatted(12.5), "12.5")
    XCTAssertEqual(FocusPoints.formatted(0), "0")
  }

  func testEveryPresetQualityMapsBackToItself() throws {
    for quality in FocusQuality.allCases {
      XCTAssertEqual(FocusQuality.matching(multiplier: quality.multiplier), quality)
    }
    XCTAssertNil(FocusQuality.matching(multiplier: 1.23))
  }

  // MARK: - Awarding

  func testFinishingABlockWithAQualityScoresItAgainstTheTaskTitle() throws {
    let task = try store.createTask(listId: list.id, title: "Draft the brief")
    let session = try store.startFocusSession(taskId: task.id)

    let completion = try store.completeActiveFocusTask(
      sessionId: session.id, elapsedSeconds: 1_500, qualityMultiplier: FocusQuality.sharp.multiplier)

    let award = try XCTUnwrap(completion.award)
    XCTAssertEqual(award.taskTitle, "Draft the brief")
    XCTAssertEqual(award.minutes, 25)
    XCTAssertEqual(award.points, 37.5)
    XCTAssertEqual(award.quality, .sharp)
    XCTAssertEqual(try store.focusAwards().map(\.id), [award.id])
  }

  func testFinishingWithoutAQualityScoresNothing() throws {
    let task = try store.createTask(listId: list.id, title: "Tidy up")
    let session = try store.startFocusSession(taskId: task.id)

    let completion = try store.completeActiveFocusTask(sessionId: session.id, elapsedSeconds: 600)

    XCTAssertNil(completion.award)
    XCTAssertTrue(try store.focusAwards().isEmpty)
  }

  func testABlockThatTookNoTimeScoresNothingEvenWithAQuality() throws {
    let task = try store.createTask(listId: list.id, title: "Misfire")
    let session = try store.startFocusSession(taskId: task.id)

    let completion = try store.completeActiveFocusTask(
      sessionId: session.id, elapsedSeconds: 0, qualityMultiplier: FocusQuality.flow.multiplier)

    XCTAssertNil(completion.award)
    XCTAssertTrue(try store.focusAwards().isEmpty)
  }

  func testTimeCreditedToADailyIsStillScored() throws {
    let task = try store.createTask(listId: list.id, title: "Write 500 words")
    _ = try store.makeDaily(taskId: task.id)
    let session = try store.startFocusSession(taskId: task.id)

    let completion = try store.completeActiveFocusTask(
      sessionId: session.id, elapsedSeconds: 1_800, qualityMultiplier: FocusQuality.solid.multiplier)

    XCTAssertEqual(completion.outcome, .contributionLogged(seconds: 1_800))
    XCTAssertEqual(try store.task(id: task.id)?.status, .open)
    XCTAssertEqual(try XCTUnwrap(completion.award).points, 30)
  }

  func testDeletingTheTaskLeavesTheScoreStanding() throws {
    let task = try store.createTask(listId: list.id, title: "Ship the thing")
    let session = try store.startFocusSession(taskId: task.id)
    _ = try store.completeActiveFocusTask(
      sessionId: session.id, elapsedSeconds: 1_200, qualityMultiplier: 2)

    try store.deleteTask(id: task.id)

    let award = try XCTUnwrap(try store.focusAwards().first)
    XCTAssertNil(award.taskId)
    XCTAssertEqual(award.taskTitle, "Ship the thing")
    XCTAssertEqual(award.points, 40)
  }

  // MARK: - Totals

  func testTheSummaryCountsTodayTheTrailingWeekAndEverything() throws {
    let task = try store.createTask(listId: list.id, title: "Work")
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 17)))

    func score(daysAgo: Int, seconds: Int, multiplier: Double) throws {
      let when = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: now))
      let session = try store.startFocusSession(taskId: task.id, now: when)
      _ = try store.completeActiveFocusTask(
        sessionId: session.id, elapsedSeconds: seconds, qualityMultiplier: multiplier, now: when,
        calendar: calendar)
    }

    try score(daysAgo: 0, seconds: 1_500, multiplier: 1)     // 25
    try score(daysAgo: 0, seconds: 600, multiplier: 1.5)     //  15
    try score(daysAgo: 3, seconds: 1_800, multiplier: 1)     //  30
    try score(daysAgo: 30, seconds: 3_600, multiplier: 2)    // 120

    let summary = try store.focusPointsSummary(now: now, calendar: calendar)

    XCTAssertEqual(summary.today, 40)
    XCTAssertEqual(summary.blocksToday, 2)
    XCTAssertEqual(summary.last7Days, 70)
    XCTAssertEqual(summary.allTime, 190)
    XCTAssertEqual(try store.focusAwards(onDayOf: now, calendar: calendar).count, 2)
  }

  func testAnEmptyLedgerReportsZeroRatherThanFailing() throws {
    XCTAssertEqual(try store.focusPointsSummary(), .zero)
  }
}
