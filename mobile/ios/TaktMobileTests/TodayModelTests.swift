import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

@MainActor
final class TodayModelTests: XCTestCase {
  private var model: WorkspaceModel!
  private var today: TodayModel!
  private var listID: String!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    today = TodayModel()
    listID = try XCTUnwrap(model.inbox?.id)
  }

  private func add(_ title: String, estimate: Int? = nil, due: Date? = nil) throws -> WorkspaceTask {
    try model.store.createTask(listId: listID, title: title, dueAt: due, estimateSeconds: estimate)
  }

  func testDayListsPlannedThenOverdueWithReasons() async throws {
    let planned = try add("Planned", estimate: 1_800)
    let overdue = try add("Overdue", due: Calendar.current.date(byAdding: .day, value: -2, to: .now))
    _ = try add("Unrelated")
    try model.store.setPlannedForToday(true, taskIds: [planned.id])
    await today.load(model)

    XCTAssertTrue(today.day.isPlanned)
    XCTAssertEqual(today.day.cards.map(\.id), [planned.id, overdue.id])
    XCTAssertEqual(today.day.cards.map(\.reason), [.planned, .overdue])
    XCTAssertEqual(today.day.cards.last?.detail, "Overdue")
  }

  func testUnplannedDayFallsBackToTheRanking() async throws {
    _ = try add("Something")
    await today.load(model)
    XCTAssertFalse(today.day.isPlanned)
    XCTAssertEqual(today.day.cards.first?.title, "Something")
    XCTAssertNil(today.day.cards.first?.reason)
  }

  func testMovingAPlannedCardRewritesTheDayOrder() async throws {
    let a = try add("A"), b = try add("B"), c = try add("C")
    try model.store.setPlannedForToday(true, taskIds: [a.id, b.id, c.id])
    await today.load(model)
    let before = today.day.plannedIDs
    XCTAssertEqual(before.count, 3)

    today.movePlanned(before[2], by: -2, model: model)
    let expected = [before[2], before[0], before[1]]
    XCTAssertEqual(today.day.plannedIDs, expected, "shown straight away")
    await today.load(model)
    XCTAssertEqual(today.day.plannedIDs, expected, "and persisted")
  }

  func testDragOnlyMovesPlannedCards() async throws {
    let planned = try add("Planned")
    _ = try add("Due", due: Calendar.current.startOfDay(for: .now))
    try model.store.setPlannedForToday(true, taskIds: [planned.id])
    await today.load(model)
    let order = today.day.cards.map(\.id)
    today.move(from: IndexSet(integer: 1), to: 0, model: model)
    XCTAssertEqual(today.day.cards.map(\.id), order)
  }

  func testStartPauseAndDoneCompletesTheTaskAndScoresTheBlock() async throws {
    let task = try add("Write", estimate: 600)
    try model.store.setPlannedForToday(true, taskIds: [task.id])
    await today.load(model)
    let card = try XCTUnwrap(today.day.cards.first)

    today.start(card, model: model)
    await today.load(model)
    XCTAssertEqual(today.day.session?.activeTaskId, task.id)
    XCTAssertTrue(today.day.cards.first?.isRunning ?? false)
    XCTAssertEqual(today.day.cards.first?.reason, .running)

    today.togglePause(model: model)
    await today.load(model)
    XCTAssertNotNil(today.day.session?.pausedAt)

    today.requestCompletion(completeTask: true, model: model)
    XCTAssertNotNil(model.pendingBlock)
    model.confirmBlockCompletion(multiplier: 1.5)
    XCTAssertNil(model.pendingBlock)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .completed)
  }

  func testLogLeavesTheTaskOpen() async throws {
    let task = try add("Read")
    await today.load(model)
    today.start(try XCTUnwrap(today.day.cards.first), model: model)
    await today.load(model)
    today.requestCompletion(completeTask: false, model: model)
    model.confirmBlockCompletion(multiplier: nil)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .open)
    XCTAssertEqual(try model.store.workBlocks(for: task.id).count, 1)
  }

  func testCancellingTheQuestionResumesTheBlock() async throws {
    _ = try add("Draft")
    await today.load(model)
    today.start(try XCTUnwrap(today.day.cards.first), model: model)
    await today.load(model)
    today.requestCompletion(completeTask: true, model: model)
    await today.load(model)
    XCTAssertNotNil(today.day.session?.pausedAt)
    model.cancelBlockCompletion()
    await today.load(model)
    XCTAssertNil(today.day.session?.pausedAt)
  }

  func testTickingADailyLogsTodayAndKeepsTheTaskOpen() async throws {
    let task = try add("Practice")
    try model.store.makeDaily(taskId: task.id)
    await today.load(model)
    let daily = try XCTUnwrap(today.day.dailies.first)
    today.toggleDaily(daily, model: model)
    await today.load(model)
    XCTAssertTrue(today.day.dailies.first?.isDone ?? false)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .open)
    today.toggleDaily(try XCTUnwrap(today.day.dailies.first), model: model)
    await today.load(model)
    XCTAssertFalse(today.day.dailies.first?.isDone ?? true)
  }

  func testDeferringTakesATaskOffTheDay() async throws {
    let task = try add("Later")
    try model.store.setPlannedForToday(true, taskIds: [task.id])
    await today.load(model)
    today.deferToTomorrow(try XCTUnwrap(today.day.cards.first), model: model)
    await today.load(model)
    XCTAssertFalse(today.day.cards.contains { $0.id == task.id })
  }

  func testForecastCountsEstimatesAgainstLoggedTime() {
    var day = DaySnapshot()
    day.cards = [
      DayCard(
        id: "a", title: "A", listName: nil, listColorHex: nil, reason: .planned, estimateSeconds: 3_600,
        loggedSeconds: 600, dueAt: nil, isList: false, dailyID: nil, isDailyDoneToday: false, isRunning: false),
      DayCard(
        id: "b", title: "B", listName: nil, listColorHex: nil, reason: .planned, estimateSeconds: nil,
        loggedSeconds: 0, dueAt: nil, isList: false, dailyID: nil, isDailyDoneToday: false, isRunning: false),
    ]
    let now = Date(timeIntervalSince1970: 1_000_000)
    let forecast = day.forecast(now: now)
    XCTAssertEqual(forecast.estimatedSeconds, 3_600)
    XCTAssertEqual(forecast.loggedSeconds, 600)
    XCTAssertEqual(forecast.unestimatedCount, 1)
    XCTAssertEqual(DayHeader.spent(forecast), "10m of 1h")
  }
}
