import Foundation
import TaktCore
import TaktWorkspace
import XCTest

final class WorkspaceFocusNotificationTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var list: TaskList!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktNotificationTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    list = try XCTUnwrap(store.inbox(in: workspace.id))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  // MARK: - Notification Content and Formatting

  func testBlockFinishedNotificationCarriesTaskTitleAndPromptsReview() {
    let notification = FocusNotification(
      kind: .blockFinished(taskTitle: "Implement parser"),
      playSound: true
    )
    XCTAssertEqual(notification.id, "focus-block-finished")
    XCTAssertEqual(notification.title, "Focus block finished")
    XCTAssertEqual(notification.subtitle, "Implement parser")
    XCTAssertEqual(notification.body, "Take a break or review the block.")
    XCTAssertTrue(notification.playSound)
  }

  func testBlockFinishedNotificationWithoutTaskTitle() {
    let notification = FocusNotification(
      kind: .blockFinished(taskTitle: nil),
      playSound: false
    )
    XCTAssertEqual(notification.id, "focus-block-finished")
    XCTAssertEqual(notification.title, "Focus block finished")
    XCTAssertNil(notification.subtitle)
    XCTAssertEqual(notification.body, "Take a break or review the block.")
    XCTAssertFalse(notification.playSound)
  }

  func testBreakFinishedNotificationInvitesResume() {
    let notification = FocusNotification(
      kind: .breakFinished(taskTitle: "Refactor database"),
      playSound: true
    )
    XCTAssertEqual(notification.id, "focus-break-finished")
    XCTAssertEqual(notification.title, "Break ended")
    XCTAssertEqual(notification.subtitle, "Refactor database")
    XCTAssertEqual(notification.body, "Ready to resume focus or pick your next task.")
    XCTAssertTrue(notification.playSound)
  }

  func testBreakFinishedNotificationWithoutTaskTitle() {
    let notification = FocusNotification(
      kind: .breakFinished(taskTitle: nil),
      playSound: false
    )
    XCTAssertEqual(notification.id, "focus-break-finished")
    XCTAssertEqual(notification.title, "Break ended")
    XCTAssertNil(notification.subtitle)
    XCTAssertEqual(notification.body, "Ready to resume focus or pick your next task.")
    XCTAssertFalse(notification.playSound)
  }

  // MARK: - Policy Timing & Preferences

  func testPolicyDeterminesWhenBlockIsFinished() {
    XCTAssertFalse(FocusNotificationPolicy.isBlockFinished(elapsedSeconds: 1499, workDurationSeconds: 1500))
    XCTAssertTrue(FocusNotificationPolicy.isBlockFinished(elapsedSeconds: 1500, workDurationSeconds: 1500))
    XCTAssertTrue(FocusNotificationPolicy.isBlockFinished(elapsedSeconds: 1520, workDurationSeconds: 1500))
  }

  func testPolicyDeterminesWhenBreakIsFinished() {
    let base = Date.now
    let futureBreakEnd = base.addingTimeInterval(300)
    let pastBreakEnd = base.addingTimeInterval(-10)

    XCTAssertFalse(FocusNotificationPolicy.isBreakFinished(breakEndsAt: nil, now: base))
    XCTAssertFalse(FocusNotificationPolicy.isBreakFinished(breakEndsAt: futureBreakEnd, now: base))
    XCTAssertTrue(FocusNotificationPolicy.isBreakFinished(breakEndsAt: pastBreakEnd, now: base))
    XCTAssertTrue(FocusNotificationPolicy.isBreakFinished(breakEndsAt: base, now: base))
  }

  func testDisabledPreferenceSuppressesNotifications() {
    XCTAssertNil(
      FocusNotificationPolicy.blockFinishedNotification(
        taskTitle: "Test",
        enabled: false,
        playSound: true
      )
    )
    XCTAssertNotNil(
      FocusNotificationPolicy.blockFinishedNotification(
        taskTitle: "Test",
        enabled: true,
        playSound: true
      )
    )
    XCTAssertNil(
      FocusNotificationPolicy.breakFinishedNotification(
        taskTitle: "Test",
        enabled: false,
        playSound: true
      )
    )
    XCTAssertNotNil(
      FocusNotificationPolicy.breakFinishedNotification(
        taskTitle: "Test",
        enabled: true,
        playSound: true
      )
    )
  }

  func testSoundPreferenceSetsPlaySound() {
    let withSound = FocusNotificationPolicy.blockFinishedNotification(
      taskTitle: "Task",
      enabled: true,
      playSound: true
    )
    XCTAssertEqual(withSound?.playSound, true)

    let withoutSound = FocusNotificationPolicy.blockFinishedNotification(
      taskTitle: "Task",
      enabled: true,
      playSound: false
    )
    XCTAssertEqual(withoutSound?.playSound, false)
  }

  // MARK: - Integration with Focus Session in Store

  func testBreakTransitionInStoreProvidesBreakEndsAtForNotification() throws {
    let task = try store.createTask(listId: list.id, title: "Deep Work")
    let session = try store.startFocusSession(taskId: task.id, plannedSeconds: 1500, context: FocusContext())
    XCTAssertEqual(session.phase, .running)

    let now = Date.now
    let breakCompletion = try store.takeFocusBreak(
      sessionId: session.id,
      elapsedSeconds: 1500,
      qualityMultiplier: 1.0,
      now: now
    )

    let breakSession = breakCompletion.session
    XCTAssertEqual(breakSession.phase, .onBreak)
    let breakEndsAt = try XCTUnwrap(breakSession.breakEndsAt)
    XCTAssertGreaterThan(breakEndsAt, now)

    // While on break and before expiry:
    XCTAssertFalse(FocusNotificationPolicy.isBreakFinished(breakEndsAt: breakEndsAt, now: now))

    // When time passes breakEndsAt:
    let later = breakEndsAt.addingTimeInterval(1)
    XCTAssertTrue(FocusNotificationPolicy.isBreakFinished(breakEndsAt: breakEndsAt, now: later))

    let notification = try XCTUnwrap(
      FocusNotificationPolicy.breakFinishedNotification(
        taskTitle: task.title,
        enabled: true,
        playSound: true
      )
    )
    XCTAssertEqual(notification.title, "Break ended")
    XCTAssertEqual(notification.subtitle, "Deep Work")
  }
}
