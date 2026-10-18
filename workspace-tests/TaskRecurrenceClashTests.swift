import Foundation
import TaktWorkspace
import XCTest

final class TaskRecurrenceClashTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var inboxID: String!
  private let calendar = Calendar.current

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClashTests-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    let workspaceID = try store.bootstrapIfNeeded().id
    inboxID = try XCTUnwrap(store.inbox(in: workspaceID)).id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func day(_ offset: Int, hour: Int = 9) -> Date {
    let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
  }

  /// A task due tomorrow at nine that repeats daily, freshly opened.
  private func dailyTask() throws -> TaskEditorDraft {
    let task = try store.createTask(listId: inboxID, title: "Water the plants")
    var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
    draft.values.dueAt = day(1)
    draft.values.recurrenceRule = "daily"
    _ = try store.saveTaskEditor(draft)
    return TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
  }

  func testMovingOntoTheNextTurnIsAClashAndAnEarlierTimeIsNot() throws {
    var draft = try dailyTask()
    draft.values.dueAt = day(1, hour: 15)
    XCTAssertNil(try store.recurrenceClash(for: draft))

    draft.values.dueAt = day(2)
    let clash = try XCTUnwrap(try store.recurrenceClash(for: draft))
    XCTAssertEqual(clash.taskId, draft.baseline.taskId)
    XCTAssertTrue(calendar.isDate(clash.nextTurn, inSameDayAs: day(2)))
    XCTAssertEqual(clash.movedTo, day(2))
    XCTAssertTrue(clash.landsOnTurn(calendar: calendar))
  }

  func testATaskThatDoesNotRepeatNeverClashes() throws {
    let task = try store.createTask(listId: inboxID, title: "Once")
    var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
    draft.values.dueAt = day(1)
    _ = try store.saveTaskEditor(draft)
    draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
    draft.values.dueAt = day(9)
    XCTAssertNil(try store.recurrenceClash(for: draft))
  }

  func testKeepBothAddsAOneOffCopyOnTheMovedDayAsItsOwnStep() throws {
    var draft = try dailyTask()
    draft.values.dueAt = day(3)
    _ = try store.saveTaskEditor(draft)
    let copyID = try store.addOccurrenceCopy(draft)

    let copy = try store.taskEditorSnapshot(for: copyID)
    XCTAssertEqual(copy.title, "Water the plants")
    XCTAssertEqual(copy.dueAt, day(3))
    XCTAssertEqual(copy.values.recurrenceRule, "")
    XCTAssertEqual(try store.taskEditorSnapshot(for: draft.baseline.taskId).dueAt, day(3))
    XCTAssertEqual(try store.undo(), "Keep Both")
    XCTAssertNil(try store.task(id: copyID))
  }

  func testTheWordingNamesBothDaysAndWhetherItLandsOnOrPastTheTurn() {
    let clash = TaskRecurrenceClash(taskId: "t", rule: "daily", nextTurn: day(2), movedTo: day(2, hour: 15))
    let label: (Date) -> String = { self.calendar.isDate($0, inSameDayAs: self.day(2)) ? "Tue" : "Thu" }
    XCTAssertEqual(clash.title(task: "Water", day: label), "Water comes round again on Tue")
    XCTAssertEqual(clash.message(day: label, calendar: calendar), "Moving it to Tue lands on that turn.")
    let past = TaskRecurrenceClash(taskId: "t", rule: "daily", nextTurn: day(2), movedTo: day(4))
    XCTAssertEqual(past.message(day: label, calendar: calendar), "Moving it to Thu goes past that turn.")
  }

  func testOnlyStackAndKeepBothSaveAndOnlyKeepBothCopies() {
    XCTAssertEqual(RecurrenceClashChoice.allCases, [.stack, .keepBoth, .cancel])
    XCTAssertEqual(RecurrenceClashChoice.allCases.map(\.title), ["Stack on that day", "Keep both", "Cancel"])
    XCTAssertEqual(RecurrenceClashChoice.allCases.map(\.saves), [true, true, false])
    XCTAssertEqual(RecurrenceClashChoice.allCases.map(\.addsCopy), [false, true, false])
  }
}
