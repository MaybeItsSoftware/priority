import PriorityCore
import PriorityWorkspace
import XCTest
@testable import Priority

@MainActor
final class FocusModelTests: XCTestCase {
  private var model: WorkspaceModel!
  private var focus: FocusModel!
  private var listID: String!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    listID = try XCTUnwrap(model.inbox?.id)
    focus = FocusModel(model: model)
    focus.conditionIDs = []
  }

  private func add(_ title: String, estimate: Int? = nil) throws -> WorkspaceTask {
    try model.store.createTask(listId: listID, title: title, estimateSeconds: estimate)
  }

  func testLadderRanksOpenTasks() throws {
    _ = try add("Alpha")
    _ = try add("Beta")
    focus.loadNow()
    XCTAssertEqual(Set(focus.ladder.map(\.candidate.title)), ["Alpha", "Beta"])
  }

  func testStagingSeedsTheEstimateFromTheTask() throws {
    let task = try add("Write", estimate: 45 * 60)
    focus.loadNow()
    focus.stage(task.id)
    XCTAssertEqual(focus.stagedTaskID, task.id)
    XCTAssertEqual(focus.estimateMinutes, 45)
  }

  func testBeginThenDoneScoresTheBlockAndCompletesTheTask() throws {
    let task = try add("Write", estimate: 25 * 60)
    focus.loadNow()
    focus.stage(task.id)
    focus.beginStaged()
    XCTAssertNil(focus.startOverride)
    XCTAssertEqual(focus.session?.activeTaskId, task.id)
    XCTAssertNil(focus.stagedTaskID)

    // Backdate the block so it has measurable time.
    let session = try XCTUnwrap(focus.session)
    try model.store.rebaseFocusClock(id: session.id, elapsedSeconds: 600, now: .now)
    focus.loadNow()
    focus.requestCompletion(completeTask: true)
    let pending = try XCTUnwrap(focus.pendingCompletion)
    XCTAssertGreaterThanOrEqual(pending.seconds, 600)

    focus.confirmCompletion(multiplier: 1.5)
    XCTAssertNil(focus.pendingCompletion)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .completed)
    XCTAssertEqual(focus.lastAward?.multiplier, 1.5)
    XCTAssertNil(focus.session, "the queue is empty, so the session ends")
    XCTAssertGreaterThan(focus.snapshot.points.today, 0)
  }

  func testLogAndKeepLeavesTheTaskOpen() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 1_500)
    let session = try XCTUnwrap(focus.session)
    try model.store.rebaseFocusClock(id: session.id, elapsedSeconds: 300, now: .now)
    focus.loadNow()
    focus.requestCompletion(completeTask: false)
    focus.confirmCompletion(multiplier: 1)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .open)
    if case .progressLogged(let seconds) = focus.lastOutcome {
      XCTAssertGreaterThanOrEqual(seconds, 300)
    } else {
      XCTFail("expected progress logged, got \(String(describing: focus.lastOutcome))")
    }
  }

  func testCancellingThePromptResumesTheBlock() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 1_500)
    focus.requestCompletion()
    XCTAssertNotNil(focus.session?.pausedAt)
    focus.cancelCompletion()
    XCTAssertNil(focus.pendingCompletion)
    XCTAssertNil(focus.session?.pausedAt)
  }

  func testPauseAndResume() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 1_500)
    focus.togglePause()
    XCTAssertNotNil(focus.session?.pausedAt)
    focus.togglePause()
    XCTAssertNil(focus.session?.pausedAt)
  }

  func testFinishEndsTheSessionWithoutCompletingTheTask() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 1_500)
    focus.finish()
    XCTAssertNil(focus.session)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .open)
  }

  func testABlockLongerThanTheTimeAvailableAsksFirst() throws {
    let task = try add("Long", estimate: 3_600)
    focus.setAvailable(minutes: 15)
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 3_600)
    XCTAssertNotNil(focus.startOverride)
    XCTAssertNil(focus.session)
    focus.confirmOverride()
    XCTAssertEqual(focus.session?.activeTaskId, task.id)
  }

  func testTickingOffWithoutASession() throws {
    let task = try add("Quick")
    focus.loadNow()
    focus.completeWithoutSession(task.id)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .completed)
    focus.loadNow()
    XCTAssertFalse(focus.ladder.contains { $0.id == task.id })
  }

  func testDeferringTakesTheTaskOffTheLadder() throws {
    let task = try add("Later")
    focus.loadNow()
    focus.deferTask(task.id, .tomorrow)
    focus.loadNow()
    XCTAssertFalse(focus.ladder.contains { $0.id == task.id })
    XCTAssertTrue(focus.snapshot.blocked.contains { $0.id == task.id })
  }

  func testReorderPinsAndResetClears() throws {
    _ = try add("One")
    _ = try add("Two")
    _ = try add("Three")
    focus.loadNow()
    let last = try XCTUnwrap(focus.ladder.last)
    focus.moveRung(last.id, by: -2)
    focus.loadNow()
    XCTAssertEqual(focus.ladder.first?.id, last.id)
    XCTAssertTrue(focus.snapshot.hasManualOrder)
    focus.resetOrder()
    focus.loadNow()
    XCTAssertFalse(focus.snapshot.hasManualOrder)
  }

  func testARequestFromElsewhereIsStagedOnce() throws {
    let task = try add("Asked for")
    model.focusRequestTaskID = task.id
    focus.takeRequest()
    XCTAssertEqual(focus.stagedTaskID, task.id)
    XCTAssertNil(model.focusRequestTaskID)
  }

  func testLocationConditionsReplaceEachOther() throws {
    let home = try model.store.createCondition(workspaceId: model.workspace.id, name: "Home", isLocation: true)
    let office = try model.store.createCondition(workspaceId: model.workspace.id, name: "Office", isLocation: true)
    focus.loadNow()
    focus.toggleCondition(home)
    focus.toggleCondition(office)
    XCTAssertEqual(focus.conditionIDs, [office.id])
  }

  func testDeferralTimes() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 16))!
    let tomorrow = FocusDeferral.tomorrow.date(from: now, calendar: calendar)
    XCTAssertEqual(calendar.component(.day, from: tomorrow), 3)
    XCTAssertEqual(calendar.component(.hour, from: tomorrow), 9)
    // Past two o'clock, "this afternoon" means an hour from now.
    XCTAssertEqual(FocusDeferral.thisAfternoon.date(from: now, calendar: calendar), now.addingTimeInterval(3_600))
  }
}
