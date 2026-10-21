import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

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

    model.confirmBlockCompletion(multiplier: 1.5)
    focus.loadNow()
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
    model.confirmBlockCompletion(multiplier: 1)
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
    model.cancelBlockCompletion()
    focus.loadNow()
    XCTAssertNil(focus.pendingCompletion)
    XCTAssertNil(focus.session?.pausedAt)
  }

  func testWhereYouAreOffersOnlyWhatOpenTasksNeedUnderCategoryHeadings() throws {
    let mat = try XCTUnwrap(model.createCondition(named: "Mat", category: "Equipment"))
    let home = try XCTUnwrap(model.store.conditions(in: model.workspace.id).first { $0.name == "Home" })
    focus.loadNow()
    XCTAssertTrue(focus.conditionSections.isEmpty, "nothing open needs a condition")

    let gym = try add("Gym")
    let inspector = InspectorModel(taskID: gym.id, draftsURL: FileManager.default.temporaryDirectory
      .appending(path: "drafts-\(UUID().uuidString).json"))
    inspector.load(model)
    inspector.addRequirement(mat.id, model: model)
    XCTAssertTrue(inspector.save(model))
    focus.loadNow()
    XCTAssertEqual(focus.conditionSections.map(\.title), ["Equipment"])
    XCTAssertEqual(focus.visibleConditions.map(\.id), [mat.id])

    focus.toggleCondition(home)
    XCTAssertEqual(focus.conditionSections.map(\.title), ["Location", "Equipment"], "one that is on stays")
    XCTAssertTrue(focus.conditionSections[0].isExclusive)
  }

  /// What a place provides holds with it, "from Home", and a task needing
  /// it is offered; switching one off is an override that a new place ends.
  func testWhatASettingProvidesHoldsUntilSwitchedOffForNow() throws {
    let home = try XCTUnwrap(model.createCondition(named: "Flat", isLocation: true))
    let office = try XCTUnwrap(model.createCondition(named: "Office", isLocation: true))
    let floor = try XCTUnwrap(model.createCondition(named: "Floor space", category: nil))
    let quiet = try XCTUnwrap(model.createCondition(named: "Quiet", category: nil))
    try model.store.setConditionProvides(id: home.id, provides: [floor.id, quiet.id])
    let stretch = try add("Stretch")
    let inspector = InspectorModel(taskID: stretch.id, draftsURL: FileManager.default.temporaryDirectory
      .appending(path: "drafts-\(UUID().uuidString).json"))
    inspector.load(model)
    inspector.addRequirement(floor.id, model: model)
    XCTAssertTrue(inspector.save(model))
    focus.loadNow()
    XCTAssertFalse(focus.ladder.contains { $0.id == stretch.id }, "no floor space yet")
    XCTAssertTrue(focus.visibleConditions.contains { $0.id == home.id }, "what provides it is offered")

    focus.toggleCondition(home)
    focus.loadNow()
    XCTAssertEqual(focus.conditionIDs, [home.id])
    XCTAssertTrue(focus.heldIDs.isSuperset(of: [home.id, floor.id, quiet.id]))
    XCTAssertEqual(focus.holdingNote(floor.id), "from Flat")
    XCTAssertTrue(focus.ladder.contains { $0.id == stretch.id }, "offered without saying Floor space")

    focus.toggleCondition(quiet)
    XCTAssertEqual(focus.offIDs, [quiet.id])
    XCTAssertFalse(focus.heldIDs.contains(quiet.id))
    XCTAssertEqual(focus.holdingNote(quiet.id), "off for now")
    XCTAssertEqual(try model.store.focusContext(in: model.workspace.id)?.offIDs, [quiet.id])

    focus.toggleCondition(office)
    XCTAssertEqual(focus.conditionIDs, [office.id])
    XCTAssertTrue(focus.offIDs.isEmpty, "a new place ends the last one's overrides")
  }

  func testAnExpiredContextIsSetAsideAndOfferedBack() throws {
    let office = try XCTUnwrap(model.createCondition(named: "Office", isLocation: true))
    focus.loadNow()
    focus.toggleCondition(office)
    let now = Date.now
    focus.setContextExpires(true, now: now)
    XCTAssertEqual(focus.context.endsAt, now.addingTimeInterval(3_600))
    focus.availableUntil = now.addingTimeInterval(600)
    XCTAssertEqual(focus.context.endsAt, now.addingTimeInterval(600), "the earlier of the two ends wins")

    focus.tick(now: now.addingTimeInterval(3_601))
    XCTAssertNil(focus.contextExpiresAt)
    XCTAssertTrue(focus.conditionIDs.isEmpty)
    XCTAssertEqual(focus.suggestedContextIDs, [office.id])
    focus.confirmSuggestedContext()
    XCTAssertEqual(focus.conditionIDs, [office.id])
    XCTAssertTrue(focus.suggestedContextIDs.isEmpty)
  }

  /// The context is the workspace's: what this screen says is saved there,
  /// for the Mac and the other phones through sync, and what another device
  /// says lands here on the next load.
  func testTheContextIsTheWorkspacesBothWays() throws {
    let office = try XCTUnwrap(model.createCondition(named: "Office", isLocation: true))
    let laptop = try XCTUnwrap(model.createCondition(named: "Laptop", category: "Equipment"))
    focus.loadNow()
    focus.toggleCondition(office)
    focus.mode = .finish
    let saved = try XCTUnwrap(model.store.focusContext(in: model.workspace.id))
    XCTAssertEqual(saved.conditionIDs, [office.id])
    XCTAssertEqual(saved.mode, .finish)
    XCTAssertNotNil(focus.conditionsSetAt)
    XCTAssertFalse(focus.isContextStale)

    // Said elsewhere — on the Mac, synced in, or by the agent.
    try model.store.saveFocusContext(SavedFocusContext(conditionIDs: [laptop.id]), in: model.workspace.id)
    focus.loadNow()
    XCTAssertEqual(focus.conditionIDs, [laptop.id])
    XCTAssertEqual(focus.mode, .progress)
    XCTAssertEqual(FocusModel(model: model).conditionIDs, [laptop.id], "a fresh screen reads it too")
  }

  /// Conditions kept in the phone's own settings before the context was the
  /// workspace's move into it once, unless the workspace already has one.
  func testThePhonesOwnContextMovesIntoTheWorkspaceOnce() throws {
    let office = try XCTUnwrap(model.createCondition(named: "Office", isLocation: true))
    let key = "focus-context-\(model.workspace.id)"
    defer { AppGroup.defaults.removeObject(forKey: key) }
    try model.store.saveFocusContext(SavedFocusContext(), in: model.workspace.id)
    AppGroup.defaults.set([office.id], forKey: key)
    XCTAssertTrue(FocusModel(model: model).conditionIDs.isEmpty, "the workspace's answer stands")
    XCTAssertNil(AppGroup.defaults.stringArray(forKey: key))

    let fresh = try WorkspaceModel.temporary()
    let place = try XCTUnwrap(fresh.createCondition(named: "Home", isLocation: true))
    let freshKey = "focus-context-\(fresh.workspace.id)"
    defer { AppGroup.defaults.removeObject(forKey: freshKey) }
    AppGroup.defaults.set([place.id], forKey: freshKey)
    XCTAssertEqual(FocusModel(model: fresh).conditionIDs, [place.id])
    XCTAssertEqual(try fresh.store.focusContext(in: fresh.workspace.id)?.conditionIDs, [place.id])
    XCTAssertNil(AppGroup.defaults.stringArray(forKey: freshKey))
  }

  func testAClockJumpRebasesTheRunningBlockToTheTimeActuallyWorked() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 3_600)
    let start = Date.now
    let uptime = ProcessInfo.processInfo.systemUptime
    focus.synchroniseClock(now: start, uptime: uptime)
    let before = try XCTUnwrap(focus.session).elapsedSeconds(now: start)
    // The wall clock leaps an hour while ten seconds pass.
    let later = start.addingTimeInterval(3_600)
    XCTAssertTrue(focus.synchroniseClock(now: later, uptime: uptime + 10))
    let elapsed = try XCTUnwrap(focus.session).elapsedSeconds(now: later)
    XCTAssertGreaterThanOrEqual(elapsed, before + 10)
    XCTAssertLessThan(elapsed, before + 30, "the jump is not counted as work")
    XCTAssertFalse(focus.synchroniseClock(now: later.addingTimeInterval(1), uptime: uptime + 11))
  }

  func testTheSharedPromptRecordsTheAwardForEverySurface() throws {
    let task = try add("Draft")
    focus.loadNow()
    focus.begin(task.id, plannedSeconds: 1_500)
    let session = try XCTUnwrap(focus.session)
    try model.store.rebaseFocusClock(id: session.id, elapsedSeconds: 300, now: .now)
    focus.loadNow()
    focus.requestCompletion(completeTask: true)
    XCTAssertNotNil(model.pendingBlock)
    XCTAssertEqual(focus.pendingCompletion, model.pendingBlock)
    model.confirmBlockCompletion(multiplier: 2)
    XCTAssertEqual(focus.lastAward?.multiplier, 2)
    focus.dismissAward()
    XCTAssertNil(model.lastBlockResult)
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
