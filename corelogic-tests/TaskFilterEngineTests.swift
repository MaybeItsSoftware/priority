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

/// `TaskFilterEngine` classifies, sorts and relates tasks; it is the layer
/// under every list the user sees. It had no coverage at all until it moved
/// into `TaktCore`.
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

  func testComputeRootDueBucketsKeysByTaskId() {
    let tasks = [
      FixtureTask(id: 1, due: "asap"),
      FixtureTask(id: 2),
    ]
    XCTAssertEqual(
      TaskFilterEngine.computeRootDueBuckets(tasks: tasks),
      [1: .asap, 2: .noDueDate])
  }

  // MARK: - Tag extraction

  func testTagsAreExtractedLowercasedAndTasksWithoutTagsAreOmitted() {
    let tasks = [
      FixtureTask(id: 1, content: "Email @Work about #Budget"),
      FixtureTask(id: 2, content: "no tags here"),
      FixtureTask(id: 3, content: "hyphens and_underscores @two-part_tag"),
    ]

    let result = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)

    XCTAssertEqual(result[1], ["@work", "#budget"])
    XCTAssertNil(result[2], "a task with no tags is absent, not present-and-empty")
    XCTAssertEqual(result[3], ["@two-part_tag"])
  }

  func testAnEmailAddressIsTreatedAsATagBecauseTheRegexIsDeliberatelySimple() {
    // Documents current behaviour rather than endorsing it: "@example" is
    // indexed as a tag. Worth knowing before anyone changes the pattern.
    let result = TaskFilterEngine.extractTagsByTaskId(
      tasks: [FixtureTask(id: 1, content: "mail someone@example.com")])
    XCTAssertEqual(result[1], ["@example"])
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

  /// A parent cycle should never reach the client, but a corrupt cache or a
  /// half-applied reparent can produce one — and this walk runs on the main
  /// actor during every cache rebuild, so looping here freezes the app rather
  /// than showing wrong rows.
  func testACycleInTheParentChainTerminates() {
    let tasks = [
      FixtureTask(id: 1, parentId: 2),
      FixtureTask(id: 2, parentId: 1),
    ]
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    XCTAssertFalse(TaskFilterEngine.isDescendant(tasks[0], of: 99, taskById: byId))
  }

  // MARK: - Comparators

  func testPositionOrdersBeforeContent() {
    let first = FixtureTask(id: 1, content: "zebra", position: 1)
    let second = FixtureTask(id: 2, content: "apple", position: 2)
    XCTAssertTrue(TaskFilterEngine.compareByPositionThenContent(first, second))
  }

  func testEqualPositionsFallBackToCaseInsensitiveContent() {
    let apple = FixtureTask(id: 1, content: "apple", position: 1)
    let banana = FixtureTask(id: 2, content: "Banana", position: 1)
    XCTAssertTrue(TaskFilterEngine.compareByPositionThenContent(apple, banana))
    XCTAssertFalse(TaskFilterEngine.compareByPositionThenContent(banana, apple))
  }

  func testAbsolutePriorityOutranksScopedPriority() {
    let absolute = FixtureTask(id: 1, position: 99)
    let scoped = FixtureTask(id: 2, position: 1)

    XCTAssertTrue(
      TaskFilterEngine.compareByPriorityThenPosition(
        absolute, scoped, priorityRankById: [2: 1], absolutePriorityRankById: [1: 1]))
  }

  func testARankedTaskOutranksAnUnrankedOneRegardlessOfPosition() {
    let ranked = FixtureTask(id: 1, position: 99)
    let unranked = FixtureTask(id: 2, position: 1)

    XCTAssertTrue(
      TaskFilterEngine.compareByPriorityThenPosition(
        ranked, unranked, priorityRankById: [1: 3], absolutePriorityRankById: [:]))
    XCTAssertFalse(
      TaskFilterEngine.compareByPriorityThenPosition(
        unranked, ranked, priorityRankById: [1: 3], absolutePriorityRankById: [:]))
  }

  func testTwoUnrankedTasksFallBackToPosition() {
    let first = FixtureTask(id: 1, position: 1)
    let second = FixtureTask(id: 2, position: 2)
    XCTAssertTrue(
      TaskFilterEngine.compareByPriorityThenPosition(
        first, second, priorityRankById: [:], absolutePriorityRankById: [:]))
  }

  func testDueBucketOrderBeatsDateWhichBeatsPosition() {
    let overdue = FixtureTask(id: 1, due: "x", dueDate: day(offset: -1), position: 99)
    let today = FixtureTask(id: 2, due: "x", dueDate: day(offset: 0), position: 1)
    let buckets: [Int: RootDueBucket] = [1: .overdue, 2: .today]

    XCTAssertTrue(
      TaskFilterEngine.compareByRootDueBucket(overdue, today, rootDueBucketById: buckets))

    let earlier = FixtureTask(id: 3, due: "x", dueDate: day(offset: 2), position: 99)
    let later = FixtureTask(id: 4, due: "x", dueDate: day(offset: 4), position: 1)
    XCTAssertTrue(
      TaskFilterEngine.compareByRootDueBucket(
        earlier, later, rootDueBucketById: [3: .nextSevenDays, 4: .nextSevenDays]),
      "same bucket falls through to the actual date")
  }

  func testAnUncachedBucketIsClassifiedOnDemand() {
    let asap = FixtureTask(id: 1, due: "asap", position: 99)
    let none = FixtureTask(id: 2, position: 1)

    XCTAssertTrue(
      TaskFilterEngine.compareByRootDueBucket(asap, none, rootDueBucketById: [:]),
      "an empty cache must not flatten the ordering")
  }
}
