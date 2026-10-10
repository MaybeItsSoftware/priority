import XCTest

@testable import TaktCore

/// A minimal `VisibilityTask`. The engines only read six properties, so a
/// fixture can supply them directly — no Checkvist model, no date parsing, no
/// decoding. That is the whole reason `VisibilityTask` exists.
struct FixtureTask: VisibilityTask {
  let id: Int
  var content: String = ""
  var due: String?
  var dueDate: Date?
  var position: Int?
  var parentId: Int?
}

/// `TaskFilterEngine` buckets Checkvist tasks by due date and relates them in
/// the outline, for the daily log's plan and the Checkvist sync path.
final class TaskFilterEngineTests: XCTestCase {
  private let calendar = Calendar.current

  private func day(offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
  }

  // MARK: - Due bucket classification

  func testAnEmptyOrMissingDueIsNoDueDate() {
    XCTAssertEqual(TaskFilterEngine.classifyDueBucket(task: FixtureTask(id: 1)), .noDueDate)
    XCTAssertEqual(
      TaskFilterEngine.classifyDueBucket(task: FixtureTask(id: 1, due: "   ")), .noDueDate)
  }

  /// Checkvist accepts these as literal text rather than resolving them to a
  /// date, so they have to be recognised before any calendar maths.
  func testKeywordDuesAreRecognisedWithoutADate() {
    let cases: [(String, RootDueBucket)] = [
      ("asap", .asap),
      ("ASAP", .asap),
      ("today", .today),
      ("tomorrow", .tomorrow),
      ("tmr", .tomorrow),
      ("next week", .nextSevenDays),
      ("next 7 days", .nextSevenDays),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(
        TaskFilterEngine.classifyDueBucket(task: FixtureTask(id: 1, due: text)),
        expected,
        "\(text) should bucket as \(expected)")
    }
  }

  func testADueStringThatNeverResolvedToADateFallsBackToFuture() {
    XCTAssertEqual(
      TaskFilterEngine.classifyDueBucket(task: FixtureTask(id: 1, due: "sometime")),
      .future)
  }

  func testDatedTasksBucketByHowFarAwayTheyAre() {
    func bucket(daysOut: Int) -> RootDueBucket {
      TaskFilterEngine.classifyDueBucket(
        task: FixtureTask(id: 1, due: "2026-01-01", dueDate: day(offset: daysOut)))
    }
    XCTAssertEqual(bucket(daysOut: -1), .overdue)
    XCTAssertEqual(bucket(daysOut: 0), .today)
    XCTAssertEqual(bucket(daysOut: 1), .tomorrow)
    XCTAssertEqual(bucket(daysOut: 3), .nextSevenDays)
    XCTAssertEqual(bucket(daysOut: 7), .nextSevenDays)
    XCTAssertEqual(bucket(daysOut: 30), .future)
  }

  /// The boundary the "next 7 days" filter is named for. `classifyDueBucket`
  /// adds 8 days to today's start, so day 7 is inside and day 8 is not.
  func testTheNextSevenDaysBoundaryIsInclusiveOfDaySeven() {
    func bucket(daysOut: Int) -> RootDueBucket {
      TaskFilterEngine.classifyDueBucket(
        task: FixtureTask(id: 1, due: "x", dueDate: day(offset: daysOut)))
    }
    XCTAssertEqual(bucket(daysOut: 7), .nextSevenDays)
    XCTAssertEqual(bucket(daysOut: 8), .future)
  }

  // MARK: - Ancestry

  func testDescendantWalksTheParentChain() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, parentId: 1),
      FixtureTask(id: 3, parentId: 2),
      FixtureTask(id: 4),
    ]
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    XCTAssertTrue(TaskFilterEngine.isDescendant(tasks[2], of: 1, taskById: byId), "grandchild")
    XCTAssertTrue(TaskFilterEngine.isDescendant(tasks[1], of: 1, taskById: byId), "direct child")
    XCTAssertFalse(TaskFilterEngine.isDescendant(tasks[3], of: 1, taskById: byId), "unrelated")
    XCTAssertFalse(TaskFilterEngine.isDescendant(tasks[0], of: 1, taskById: byId), "not its own")
  }

  func testEverythingIsADescendantOfTheRoot() {
    XCTAssertTrue(
      TaskFilterEngine.isDescendant(FixtureTask(id: 9, parentId: 4), of: 0, taskById: [:]))
  }

  /// A parent cycle should never reach the client, but a corrupt list or a
  /// half-applied reparent can produce one — and this walk runs on the main
  /// actor, so looping here freezes the app rather than answering wrongly.
  func testACycleInTheParentChainTerminates() {
    let tasks = [
      FixtureTask(id: 1, parentId: 2),
      FixtureTask(id: 2, parentId: 1),
    ]
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    XCTAssertFalse(TaskFilterEngine.isDescendant(tasks[0], of: 99, taskById: byId))
  }

  // MARK: - Subtree spans

  /// What the sync path removes and restores as one block: a task and the
  /// run of its descendants straight after it.
  func testASubtreeBlockCoversTheTaskAndTheRunOfItsDescendants() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, parentId: 1),
      FixtureTask(id: 3, parentId: 2),
      FixtureTask(id: 4),
      FixtureTask(id: 5, parentId: 4),
    ]
    XCTAssertEqual(TaskFilterEngine.subtreeBlockRange(for: 1, in: tasks), 0..<3)
    XCTAssertEqual(TaskFilterEngine.subtreeBlockRange(for: 2, in: tasks), 1..<3)
    XCTAssertEqual(TaskFilterEngine.subtreeBlockRange(for: 3, in: tasks), 2..<3)
    XCTAssertEqual(TaskFilterEngine.subtreeBlockRange(for: 4, in: tasks), 3..<5)
  }

  func testASubtreeBlockForATaskThatIsNotThereIsNil() {
    XCTAssertNil(TaskFilterEngine.subtreeBlockRange(for: 9, in: [FixtureTask(id: 1)]))
  }

  // MARK: - The Checkvist cursor

  func testTheCursorLevelAtTheRootIsTheTopLevelTasksInListOrder() {
    let tasks = [
      FixtureTask(id: 3),
      FixtureTask(id: 1, parentId: 3),
      FixtureTask(id: 2),
    ]
    XCTAssertEqual(TaskFilterEngine.cursorLevel(tasks, parentId: 0).map(\.id), [3, 2])
  }

  func testTheCursorLevelUnderATaskIsItsChildren() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, parentId: 1),
      FixtureTask(id: 3, parentId: 2),
      FixtureTask(id: 4, parentId: 1),
    ]
    XCTAssertEqual(TaskFilterEngine.cursorLevel(tasks, parentId: 1).map(\.id), [2, 4])
  }

  func testTheCursorTaskFollowsTheIndexAndClampsIntoRange() {
    let level = [FixtureTask(id: 1), FixtureTask(id: 2), FixtureTask(id: 3)]
    XCTAssertEqual(TaskFilterEngine.cursorTask(in: level, index: 1)?.id, 2)
    XCTAssertEqual(TaskFilterEngine.cursorTask(in: level, index: 7)?.id, 3)
    XCTAssertEqual(TaskFilterEngine.cursorTask(in: level, index: -2)?.id, 1)
  }

  func testAnEmptyLevelHasNoCursorTask() {
    XCTAssertNil(TaskFilterEngine.cursorTask(in: [FixtureTask](), index: 0))
  }
}
