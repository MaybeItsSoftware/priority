import Foundation
import TaktWorkspace
import XCTest

/// Starting a task on a later day while it has a deadline: when the Mac asks,
/// and what each answer saves.
final class TaskStartLaterTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var initial: TaskEditorSnapshot!

  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  /// Midday on Wednesday 21 October 2026, UTC.
  private let now = Date(timeIntervalSince1970: 1_792_584_000)
  private let hour: TimeInterval = 3_600
  private var day: TimeInterval { 24 * hour }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("StartLater-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    let task = try store.createTask(listId: try XCTUnwrap(store.inbox(in: workspace.id)).id, title: "Write it")
    initial = try store.taskEditorSnapshot(for: task.id)
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  /// A draft of a task saved with `dueAt`, `dueDate` and `start`, moved to start at `to`.
  private func draft(dueAt: Date? = nil, dueDate: String? = nil, start: Date? = nil, to: Date?) -> TaskEditorDraft {
    var saved = initial!
    saved.dueAt = dueAt
    saved.planning = TaskPlanning(startAt: start, dueDate: dueDate)
    var draft = TaskEditorDraft(snapshot: saved)
    draft.values.startAt = to
    return draft
  }

  func testItAsksOnlyWhenTheStartMovesToALaterDayAndThereIsADeadline() {
    let tomorrow = now + day
    XCTAssertNotNil(TaskStartLater.check(draft(dueAt: now + 3 * day, to: tomorrow), now: now, calendar: calendar))
    // No deadline: nothing to ask; the core takes it out of Today on its own.
    XCTAssertNil(TaskStartLater.check(draft(to: tomorrow), now: now, calendar: calendar))
    // Later today is still today.
    XCTAssertNil(TaskStartLater.check(draft(dueAt: now + 3 * day, to: now + hour), now: now, calendar: calendar))
    // Cleared, or moved within the day it already started on.
    XCTAssertNil(TaskStartLater.check(draft(dueAt: now + 3 * day, start: tomorrow, to: nil), now: now, calendar: calendar))
    XCTAssertNil(TaskStartLater.check(
      draft(dueAt: now + 3 * day, start: tomorrow, to: tomorrow + hour), now: now, calendar: calendar))
    // The deadline changed in the same edit: that was the answer already.
    var both = draft(dueAt: now + 3 * day, to: tomorrow)
    both.values.dueAt = now + 4 * day
    XCTAssertNil(TaskStartLater.check(both, now: now, calendar: calendar))
  }

  /// Later the same day, past the deadline: the core would refuse it, so it asks.
  func testAStartMovedPastTheDeadlineOnTheSameDayAsks() throws {
    let tomorrow = now + day
    let past = draft(dueAt: tomorrow + 3 * hour, start: tomorrow, to: tomorrow + 6 * hour)
    let asked = try XCTUnwrap(TaskStartLater.check(past, now: now, calendar: calendar))
    XCTAssertEqual(asked.choices, [.move, .clear, .cancel])
    XCTAssertNil(TaskStartLater.check(
      draft(dueAt: tomorrow + 3 * hour, start: tomorrow, to: tomorrow + hour), now: now, calendar: calendar))
  }

  func testADeadlineAfterTheNewStartCanBeKept() throws {
    let asked = try XCTUnwrap(TaskStartLater.check(
      draft(dueAt: now + 3 * day, start: now, to: now + day), now: now, calendar: calendar))
    XCTAssertEqual(asked.choices, [.keep, .move, .clear, .cancel])
    var values = draft(dueAt: now + 3 * day, start: now, to: now + day).values
    XCTAssertTrue(asked.apply(.keep, to: &values))
    XCTAssertEqual(values.dueAt, now + 3 * day)
    // Moved by exactly as long as the start moved.
    XCTAssertFalse(asked.apply(.move, to: &values))
    XCTAssertEqual(values.dueAt, now + 4 * day)
    XCTAssertFalse(asked.apply(.clear, to: &values))
    XCTAssertNil(values.dueAt)
    XCTAssertNil(values.dueDate)
  }

  /// Overdue, or due before the new start: keeping it would be refused, so
  /// it isn't offered, and moving it lands it no earlier than the start's day.
  func testADeadlineBeforeTheNewStartIsMovedOrDropped() throws {
    let overdue = draft(dueAt: now - 4 * hour, to: now + day + 9 * hour)
    let asked = try XCTUnwrap(TaskStartLater.check(overdue, now: now, calendar: calendar))
    XCTAssertEqual(asked.choices, [.move, .clear, .cancel])
    var values = overdue.values
    asked.apply(.move, to: &values)
    // Tomorrow at 08:00 is before the 21:00 start, so it is due that day.
    XCTAssertNil(values.dueAt)
    XCTAssertEqual(values.dueDate, "2026-10-22")
  }

  func testADueDayMovesByWholeDays() throws {
    let moved = draft(dueDate: "2026-10-23", start: now, to: now + 2 * day)
    let asked = try XCTUnwrap(TaskStartLater.check(moved, now: now, calendar: calendar))
    XCTAssertTrue(asked.canKeep)
    var values = moved.values
    asked.apply(.move, to: &values)
    XCTAssertEqual(values.dueDate, "2026-10-25")
    // The words are the locale's; the day is the 23rd, a Friday, with no time.
    let kept = try XCTUnwrap(asked.dueText(for: .keep, calendar: calendar))
    XCTAssertTrue(kept.contains("23") && kept.contains("Fri") && !kept.contains(":"), kept)
  }

  /// "Keep the due date" saved: the deadline stays though it was set with
  /// the task, which would otherwise have followed the start.
  func testKeepingTheDueDateSavesItWhereItWas() throws {
    let start = Date.now.addingTimeInterval(day)
    let due = Date.now.addingTimeInterval(5 * day)
    let made = try store.saveTaskEditor({
      var draft = TaskEditorDraft(snapshot: initial)
      draft.values.dueAt = due
      draft.values.startAt = start
      return draft
    }())
    var later = TaskEditorDraft(snapshot: made)
    later.values.startAt = start.addingTimeInterval(day)
    let kept = try store.saveTaskEditor(later, keepingDue: true)
    XCTAssertEqual(kept.dueAt?.timeIntervalSince1970 ?? 0, due.timeIntervalSince1970, accuracy: 0.001)
  }
}
