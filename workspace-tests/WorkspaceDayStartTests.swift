import Foundation
import TestSQLite
import TaktCore
@testable import TaktWorkspace
import XCTest

/// Starting each day with the same conditions, through the store the apps
/// use, and a start typed with `^` in the add field. The rules — the hour,
/// once a day, what a reset clears — are the core's, tested there; this
/// holds the Swift side to them.
final class WorkspaceDayStartTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var workspace: Workspace!
  private var inbox: TaskList!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("DayStart-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    workspace = try store.bootstrapIfNeeded()
    inbox = try XCTUnwrap(store.inbox(in: workspace.id))
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  /// `hour` o'clock on the wall, `days` from today, in this machine's zone.
  private func at(_ hour: Int, minute: Int = 0, days: Int = 0) -> Date {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let day = calendar.date(byAdding: .day, value: days, to: today)!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  func testTheDayStartsAtHomeOnceItChanges() throws {
    let conditions = try store.conditions(in: workspace.id)
    let home = try XCTUnwrap(conditions.first { $0.name == "Home" })
    let campus = try XCTUnwrap(conditions.first { $0.name == "Campus" })
    XCTAssertEqual(try store.dayStart(), DayStart())

    try store.setDayStart(DayStart(resets: true, hour: 4, conditionIDs: [home.id]), now: at(20, days: -1))
    let evening = at(21, days: -1)
    try store.saveFocusContext(
      SavedFocusContext(conditionIDs: [campus.id], availableUntil: evening.addingTimeInterval(3600)),
      in: workspace.id, now: evening)
    let saved = try store.dayStart()
    XCTAssertFalse(saved.isDue(at: at(23, days: -1)), "switched on that evening, which counts as started")
    XCTAssertFalse(try store.applyDayStart(in: workspace.id, now: at(3, minute: 59)))

    XCTAssertTrue(saved.isDue(at: at(4)))
    XCTAssertTrue(try store.applyDayStart(in: workspace.id, now: at(4)))
    let reset = try XCTUnwrap(store.focusContext(in: workspace.id))
    XCTAssertEqual(reset.conditionIDs, [home.id])
    XCTAssertNil(reset.availableUntil)
    XCTAssertEqual(try store.dayStart().lastResetDay, try store.dayStart().dayKey(at: at(4)))
    XCTAssertFalse(try store.dayStart().isDue(at: at(12)))
    XCTAssertFalse(try store.applyDayStart(in: workspace.id, now: at(12)))
  }

  func testAnOlderHourIsAdoptedOnlyWhenTheAccountHasNone() throws {
    XCTAssertTrue(try store.adoptDayStartHour(6))
    XCTAssertFalse(try store.adoptDayStartHour(9))
    XCTAssertEqual(try store.dayStart().hour, 6)
  }

  func testACaretFilesTheStartAndATooLateStartIsRefused() throws {
    let task = try store.createTask(capturing: "Write essay ^tomorrow @2w", listId: inbox.id)
    XCTAssertEqual(task.title, "Write essay")
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
    XCTAssertEqual(try store.startAt(for: task.id), tomorrow)
    XCTAssertNotNil(task.dueAt)
    XCTAssertThrowsError(try store.createTask(capturing: "Write essay ^2w @tomorrow", listId: inbox.id))
  }
}
