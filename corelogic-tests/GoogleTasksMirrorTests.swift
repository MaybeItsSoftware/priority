import Foundation
import PriorityCore
import XCTest

final class GoogleTasksMirrorTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }()

  // MARK: - Lists

  func testAListWithNoGoogleCopyIsCreated() {
    let plan = plan(localLists: [list("work", "Work")], localTasks: [])

    XCTAssertEqual(plan.operations, [.createList(localListID: "work", title: "Work")])
  }

  func testRenamingLocallyRenamesTheGoogleList() {
    let plan = plan(
      localLists: [list("work", "Client work")],
      localTasks: [],
      remoteLists: [.init(id: "g-work", title: "Work")],
      ledger: .init(tasks: [:], lists: ["work": "g-work"]))

    XCTAssertEqual(plan.operations, [.renameList(remoteListID: "g-work", title: "Client work")])
  }

  func testArchivingAListLocallyDeletesTheGoogleList() {
    let plan = plan(
      localLists: [],
      localTasks: [],
      remoteLists: [.init(id: "g-work", title: "Work")],
      ledger: .init(tasks: [:], lists: ["work": "g-work"]))

    XCTAssertEqual(plan.operations, [.deleteList(remoteListID: "g-work", localListID: "work")])
  }

  /// The mirror owns the lists it made. A Google Tasks list that Priority has
  /// never heard of is somebody else's, and is left alone entirely.
  func testAnUnmappedGoogleListIsNeverTouched() {
    let plan = plan(
      localLists: [],
      localTasks: [],
      remoteLists: [.init(id: "g-personal", title: "Shopping")],
      remoteTasks: [.init(id: "g-1", listID: "g-personal", title: "Milk")])

    XCTAssertTrue(plan.isEmpty)
  }

  // MARK: - Pushing local state out

  func testANewLocalTaskIsCreatedRemotely() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      ledger: .init(tasks: [:], lists: ["work": "g-work"]))

    XCTAssertEqual(
      plan.operations,
      [
        .createTask(
          localID: "t1", remoteListID: "g-work",
          payload: .init(title: "Write the brief", notes: "", due: nil, isCompleted: false))
      ])
  }

  func testATaskCompletedBeforeItWasEverMirroredIsNotPushed() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Done already", isCompleted: true)],
      remoteLists: [.init(id: "g-work", title: "Work")],
      ledger: .init(tasks: [:], lists: ["work": "g-work"]))

    XCTAssertTrue(plan.isEmpty)
  }

  func testCompletingLocallyPushesTheCompletion() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief", isCompleted: true)],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "Write the brief")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(
      plan.operations,
      [
        .updateTask(
          localID: "t1", remoteID: "g-1", remoteListID: "g-work",
          payload: .init(title: "Write the brief", notes: "", due: nil, isCompleted: true))
      ])
    XCTAssertTrue(plan.conflicts.isEmpty)
  }

  func testDeletingLocallyDeletesTheGoogleCopy() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "Write the brief")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(
      plan.operations, [.deleteTask(remoteID: "g-1", remoteListID: "g-work", localID: "t1")])
  }

  func testAnUnchangedTaskProducesNothing() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "Write the brief")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertTrue(plan.isEmpty)
  }

  // MARK: - Authority

  /// The rule stated plainly: a title edited in Google loses, and the loss is
  /// written down.
  func testARemoteTitleEditIsRevertedAndLogged() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "write brief (phone edit)")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(
      plan.operations,
      [
        .updateTask(
          localID: "t1", remoteID: "g-1", remoteListID: "g-work",
          payload: .init(title: "Write the brief", notes: "", due: nil, isCompleted: false))
      ])
    XCTAssertEqual(plan.conflicts.count, 1)
    XCTAssertEqual(plan.conflicts.first?.field, .title)
    XCTAssertEqual(plan.conflicts.first?.remoteValue, "write brief (phone edit)")
    XCTAssertEqual(plan.conflicts.first?.localValue, "Write the brief")
  }

  /// Completion is the exception to authority: it is the same answer arriving
  /// by another route, so it is honoured rather than reverted.
  func testTickingOffInGoogleCompletesTheLocalTask() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-1", listID: "g-work", title: "Write the brief", isCompleted: true)
      ],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(plan.operations, [.completeLocalTask(localID: "t1")])
    XCTAssertTrue(plan.conflicts.isEmpty)
  }

  /// Notes typed on a phone where Priority had none are an addition, and
  /// additions are kept rather than argued with.
  func testNotesAddedInGoogleAreMergedBackIn() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-1", listID: "g-work", title: "Write the brief", notes: "Ask about the budget")
      ],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(
      plan.operations, [.mergeNotesIntoLocalTask(localID: "t1", notes: "Ask about the budget")])
    XCTAssertTrue(plan.conflicts.isEmpty)
  }

  func testNotesAppendedInGoogleAreMergedBackIn() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Brief", notes: "Due Friday")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-1", listID: "g-work", title: "Brief", notes: "Due Friday\nAsk about budget")
      ],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Brief", notes: "Due Friday"))

    XCTAssertEqual(
      plan.operations,
      [.mergeNotesIntoLocalTask(localID: "t1", notes: "Due Friday\nAsk about budget")])
  }

  /// Rewriting is not adding: if the remote note no longer contains what
  /// Priority wrote, something was thrown away, and Priority's copy wins.
  func testRewrittenNotesAreAConflictRatherThanAMerge() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Brief", notes: "Due Friday")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "Brief", notes: "whenever")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Brief", notes: "Due Friday"))

    XCTAssertEqual(plan.conflicts.map(\.field), [.notes])
    XCTAssertEqual(
      plan.operations,
      [
        .updateTask(
          localID: "t1", remoteID: "g-1", remoteListID: "g-work",
          payload: .init(title: "Brief", notes: "Due Friday", due: nil, isCompleted: false))
      ])
  }

  /// Both sides moved: Priority still wins, and the remote note is recorded
  /// rather than merged, because merging would need someone to decide an order.
  func testNotesAddedOnBothSidesResolveToLocalAndAreLogged() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Brief", notes: "Local addition")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-1", listID: "g-work", title: "Brief", notes: "Remote addition")],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Brief"))

    XCTAssertEqual(plan.conflicts.map(\.field), [.notes])
    XCTAssertEqual(plan.conflicts.first?.localValue, "Local addition")
  }

  func testDeletingInGoogleBringsTheTaskBackAndLogsIt() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief")],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-1", listID: "g-work", title: "Write the brief", isDeleted: true)
      ],
      ledger: ledger(localID: "t1", remoteID: "g-1", title: "Write the brief"))

    XCTAssertEqual(
      plan.operations,
      [
        .createTask(
          localID: "t1", remoteListID: "g-work",
          payload: .init(title: "Write the brief", notes: "", due: nil, isCompleted: false))
      ])
    XCTAssertEqual(plan.conflicts.map(\.field), [.existence])
  }

  /// A task deleted in Google that Priority had already completed is left
  /// dead: it agrees with Priority, so there is nothing to put back.
  func testACompletedTaskDeletedInGoogleStaysDeleted() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [task("t1", list: "work", title: "Write the brief", isCompleted: true)],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-1", listID: "g-work", title: "Write the brief", isDeleted: true)
      ],
      ledger: ledger(
        localID: "t1", remoteID: "g-1", title: "Write the brief", completed: true))

    XCTAssertTrue(plan.isEmpty)
  }

  func testATaskTypedIntoGoogleIsAdoptedIntoTheMirroredList() {
    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: [],
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [.init(id: "g-9", listID: "g-work", title: "Called from the train")],
      ledger: .init(tasks: [:], lists: ["work": "g-work"]))

    XCTAssertEqual(
      plan.operations,
      [
        .adoptRemoteTask(
          remoteID: "g-9", remoteListID: "g-work", localListID: "work",
          payload: .init(
            title: "Called from the train", notes: "", due: nil, isCompleted: false))
      ])
  }

  // MARK: - Shape

  /// Google Tasks nests one level. A grandchild is mirrored flat rather than
  /// pushed into a nesting Google would refuse.
  func testSubtasksNestOnceAndGrandchildrenFlatten() {
    let tasks = [
      task("parent", list: "work", title: "Goal"),
      task("child", list: "work", parent: "parent", title: "Step"),
      task("grandchild", list: "work", parent: "child", title: "Detail"),
    ]
    var entries = ledger(localID: "parent", remoteID: "g-parent", title: "Goal")
    entries.tasks["child"] = .init(
      remoteID: "g-child", remoteListID: "g-work", pushedTitle: "Step", pushedNotes: "",
      pushedDue: nil, pushedCompleted: false)

    let plan = plan(
      localLists: [list("work", "Work")],
      localTasks: tasks,
      remoteLists: [.init(id: "g-work", title: "Work")],
      remoteTasks: [
        .init(id: "g-parent", listID: "g-work", title: "Goal"),
        .init(id: "g-child", listID: "g-work", parentID: "g-parent", title: "Step"),
      ],
      ledger: entries)

    guard case .createTask(_, _, let payload)? = plan.operations.first else {
      return XCTFail("Expected the grandchild to be created")
    }
    XCTAssertNil(payload.parentRemoteID, "A grandchild has no room to nest in Google Tasks")
  }

  func testDueDatesAreSentAsTheLocalDayAtMidnightUTC() {
    var london = Calendar(identifier: .gregorian)
    london.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
    let lateEvening = DateComponents(
      calendar: london, timeZone: london.timeZone, year: 2026, month: 6, day: 12, hour: 23,
      minute: 30
    ).date!

    XCTAssertEqual(
      GoogleTasksMirror.formatDueDate(lateEvening, calendar: london), "2026-06-12T00:00:00.000Z")
  }

  // MARK: - Helpers

  private func plan(
    localLists: [GoogleTasksMirror.LocalList],
    localTasks: [GoogleTasksMirror.LocalTask],
    remoteLists: [GoogleTasksMirror.RemoteList] = [],
    remoteTasks: [GoogleTasksMirror.RemoteTask] = [],
    ledger: GoogleTasksMirror.Ledger = .empty
  ) -> GoogleTasksMirror.Plan {
    GoogleTasksMirror.plan(
      localLists: localLists, localTasks: localTasks, remoteLists: remoteLists,
      remoteTasks: remoteTasks, ledger: ledger, calendar: calendar)
  }

  private func list(_ id: String, _ name: String) -> GoogleTasksMirror.LocalList {
    .init(id: id, name: name)
  }

  private func task(
    _ id: String, list: String, parent: String? = nil, title: String, notes: String = "",
    due: Date? = nil, isCompleted: Bool = false
  ) -> GoogleTasksMirror.LocalTask {
    .init(
      id: id, listID: list, parentID: parent, title: title, notes: notes, due: due,
      isCompleted: isCompleted)
  }

  private func ledger(
    localID: String, remoteID: String, title: String, notes: String = "", due: String? = nil,
    completed: Bool = false
  ) -> GoogleTasksMirror.Ledger {
    .init(
      tasks: [
        localID: .init(
          remoteID: remoteID, remoteListID: "g-work", pushedTitle: title, pushedNotes: notes,
          pushedDue: due, pushedCompleted: completed)
      ],
      lists: ["work": "g-work"])
  }
}

/// Reading Google's due day back out again.
///
/// Its own test case because the round trip is where a day quietly becomes the
/// day before: Google's string is a day dressed as midnight UTC, and treating
/// it as a real instant walks a task backwards once per sync west of
/// Greenwich.
final class GoogleTasksMirrorDueDateTests: XCTestCase {
  func testADueDayRoundTripsInATimeZoneWestOfGreenwich() {
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt

    let parsed = GoogleTasksMirror.parseDueDate("2026-06-12T00:00:00.000Z", calendar: newYork)

    XCTAssertNotNil(parsed)
    XCTAssertEqual(
      GoogleTasksMirror.formatDueDate(parsed!, calendar: newYork), "2026-06-12T00:00:00.000Z")
  }

  func testADueDayRoundTripsInATimeZoneEastOfGreenwich() {
    var sydney = Calendar(identifier: .gregorian)
    sydney.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt

    let parsed = GoogleTasksMirror.parseDueDate("2026-06-12T00:00:00.000Z", calendar: sydney)

    XCTAssertNotNil(parsed)
    XCTAssertEqual(
      GoogleTasksMirror.formatDueDate(parsed!, calendar: sydney), "2026-06-12T00:00:00.000Z")
  }

  func testAnUnparseableDueDateIsNil() {
    XCTAssertNil(GoogleTasksMirror.parseDueDate("whenever"))
  }
}
