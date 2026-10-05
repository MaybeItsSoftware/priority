import XCTest

@testable import TaktCore

/// `KanbanFilter` decides which column a card lands in and where it sits in
/// that column. It lived on `KanbanManager`, reading everything through a weak
/// data source back to the coordinator, so none of it could be reached from a
/// test — in the one view whose entire purpose is that placement.
final class KanbanFilterTests: XCTestCase {

  private func bucket(_ map: [Int: RootDueBucket]) -> (FixtureTask) -> RootDueBucket {
    { map[$0.id] ?? .noDueDate }
  }

  private func inputs(
    tags: [Int: [String]] = [:],
    buckets: [Int: RootDueBucket] = [:],
    eisenhower: [Int: (urgency: Double, importance: Double)] = [:],
    priorities: [Int: Int] = [:],
    childCounts: [Int: Int] = [:]
  ) -> KanbanFilter.MembershipInputs<FixtureTask> {
    KanbanFilter.MembershipInputs(
      tagsByTaskId: tags,
      dueBucket: bucket(buckets),
      eisenhowerByTaskId: eisenhower,
      priorityRankByTaskId: priorities,
      childCountByTaskId: childCounts
    )
  }

  private func day(offset: Int) -> Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
  }

  // MARK: - Tag matching

  func testABareConditionNameMatchesTheHashtagForm() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(
      KanbanFilter.hasTag(task, tag: "waiting", tagsByTaskId: [1: ["#waiting"]]))
  }

  func testASigilledConditionMatchesOnlyThatForm() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(KanbanFilter.hasTag(task, tag: "@waiting", tagsByTaskId: [1: ["@waiting"]]))
    XCTAssertFalse(
      KanbanFilter.hasTag(task, tag: "@waiting", tagsByTaskId: [1: ["#waiting"]]),
      "an explicit mention must not be satisfied by a hashtag")
  }

  func testTagMatchingIsCaseInsensitive() {
    XCTAssertTrue(
      KanbanFilter.hasTag(FixtureTask(id: 1), tag: "Waiting", tagsByTaskId: [1: ["#waiting"]]))
  }

  func testATaskWithNoTagsMatchesNoTagCondition() {
    XCTAssertFalse(KanbanFilter.hasTag(FixtureTask(id: 1), tag: "waiting", tagsByTaskId: [:]))
  }

  // MARK: - Conditions

  func testADueBucketConditionMatchesThatBucket() {
    let task = FixtureTask(id: 1)
    XCTAssertTrue(
      KanbanFilter.matches(
        task, condition: .dueBucket(RootDueBucket.today.rawValue),
        inputs: inputs(tags: [:], buckets: [1: .today])))
    XCTAssertFalse(
      KanbanFilter.matches(
        task, condition: .dueBucket(RootDueBucket.today.rawValue),
        inputs: inputs(tags: [:], buckets: [1: .future])))
  }

  func testAnUnrecognisedDueBucketRawValueMatchesNothing() {
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .dueBucket(999),
        inputs: inputs(tags: [:], buckets: [1: .today])))
  }

  /// The catch-all deliberately claims nothing here. It is the caller's job to
  /// use it as "whatever no earlier column took" — if it matched eagerly, the
  /// first catch-all column would swallow the entire board.
  func testTheCatchAllConditionClaimsNothingOnItsOwn() {
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .catchAll,
        inputs: inputs(tags: [1: ["#anything"]], buckets: [1: .today])))
  }

  func testAColumnMatchesWhenAnyOneOfItsConditionsDoes() {
    let column = KanbanColumn(
      name: "Today",
      conditions: [
        .dueBucket(RootDueBucket.overdue.rawValue),
        .dueBucket(RootDueBucket.today.rawValue),
      ])

    XCTAssertTrue(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column,
        inputs: inputs(tags: [:], buckets: [1: .today])))
    XCTAssertFalse(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column,
        inputs: inputs(tags: [:], buckets: [1: .tomorrow])))
  }

  func testExcludingTheCatchAllSkipsOnlyThatCondition() {
    let column = KanbanColumn(
      name: "Mixed", conditions: [.catchAll, .tag("waiting")])

    XCTAssertTrue(
      KanbanFilter.matchesColumn(
        FixtureTask(id: 1), column: column, includeCatchAll: false,
        inputs: inputs(tags: [1: ["#waiting"]], buckets: [:])),
      "the tag condition still applies")
  }

  // MARK: - The conditions a board of goals actually needs

  /// The join between the two views: a board defined by quadrant is fed by the
  /// matrix, which is the pairing that makes placing tasks worth the effort.
  func testAQuadrantConditionMatchesOnlyThatQuadrant() {
    let task = FixtureTask(id: 1)
    let doNow = KanbanColumnCondition.matrixQuadrant(MatrixQuadrant.doNow.rawValue)
    XCTAssertTrue(
      KanbanFilter.matches(
        task, condition: doNow, inputs: inputs(eisenhower: [1: (urgency: 5, importance: 5)])))
    XCTAssertFalse(
      KanbanFilter.matches(
        task, condition: doNow, inputs: inputs(eisenhower: [1: (urgency: -5, importance: 5)])))
  }

  /// `(0, 0)` is the unset sentinel, so a task sitting on it belongs to no
  /// quadrant column — otherwise every unplaced task would pile into Eliminate.
  func testAnUnplacedTaskMatchesNoQuadrant() {
    for quadrant in MatrixQuadrant.allCases {
      XCTAssertFalse(
        KanbanFilter.matches(
          FixtureTask(id: 1),
          condition: .matrixQuadrant(quadrant.rawValue),
          inputs: inputs(eisenhower: [1: (urgency: 0, importance: 0)])),
        "unplaced must not land in \(quadrant.title)")
      XCTAssertFalse(
        KanbanFilter.matches(
          FixtureTask(id: 1),
          condition: .matrixQuadrant(quadrant.rawValue),
          inputs: inputs()))
    }
  }

  func testTheMatrixInboxClaimsExactlyWhatTheQuadrantsDoNot() {
    XCTAssertTrue(
      KanbanFilter.matches(FixtureTask(id: 1), condition: .unplacedOnMatrix, inputs: inputs()))
    XCTAssertTrue(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .unplacedOnMatrix,
        inputs: inputs(eisenhower: [1: (urgency: 0, importance: 0)])))
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .unplacedOnMatrix,
        inputs: inputs(eisenhower: [1: (urgency: 3, importance: 1)])))
  }

  /// Rank 1 is the top, so "at least P3" is a rank *no greater than* three —
  /// the comparison reads backwards from how it is spelled.
  func testPriorityAtLeastClaimsTheBetterRanks() {
    let condition = KanbanColumnCondition.priorityAtLeast(3)
    XCTAssertTrue(
      KanbanFilter.matches(FixtureTask(id: 1), condition: condition, inputs: inputs(priorities: [1: 1])))
    XCTAssertTrue(
      KanbanFilter.matches(FixtureTask(id: 1), condition: condition, inputs: inputs(priorities: [1: 3])))
    XCTAssertFalse(
      KanbanFilter.matches(FixtureTask(id: 1), condition: condition, inputs: inputs(priorities: [1: 4])))
    XCTAssertFalse(
      KanbanFilter.matches(FixtureTask(id: 1), condition: condition, inputs: inputs()),
      "an unranked task has no priority to be at least")
  }

  /// The board draws a card per matching task at every depth, so a six-level
  /// tree puts a goal and its whole subtree on the board as peers.
  func testLeafOnlyExcludesTasksWithSubtasks() {
    XCTAssertTrue(
      KanbanFilter.matches(FixtureTask(id: 1), condition: .leafOnly, inputs: inputs()))
    XCTAssertTrue(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .leafOnly, inputs: inputs(childCounts: [1: 0])))
    XCTAssertFalse(
      KanbanFilter.matches(
        FixtureTask(id: 1), condition: .leafOnly, inputs: inputs(childCounts: [1: 4])))
  }

  // MARK: - Writability

  /// A drop has to be able to *do* something. A quadrant column writes a
  /// coordinate; the three descriptive conditions have no value the board could
  /// infer, so a column of only those accepts no drops.
  func testOnlyConditionsTheBoardCanWriteAreWritable() {
    XCTAssertTrue(KanbanColumnCondition.matrixQuadrant(MatrixQuadrant.doNow.rawValue).isWritable)
    XCTAssertTrue(KanbanColumnCondition.tag("waiting").isWritable)
    XCTAssertFalse(KanbanColumnCondition.priorityAtLeast(3).isWritable)
    XCTAssertFalse(KanbanColumnCondition.leafOnly.isWritable)
    XCTAssertFalse(KanbanColumnCondition.unplacedOnMatrix.isWritable)
  }

  /// Old saved boards must survive the enum growing four cases.
  func testTheStoredFormRoundTripsForEveryCondition() throws {
    let all: [KanbanColumnCondition] = [
      .tag("waiting"), .dueBucket(RootDueBucket.today.rawValue), .catchAll,
      .matrixQuadrant(MatrixQuadrant.schedule.rawValue), .priorityAtLeast(2),
      .leafOnly, .unplacedOnMatrix,
    ]
    let data = try JSONEncoder().encode(all)
    XCTAssertEqual(try JSONDecoder().decode([KanbanColumnCondition].self, from: data), all)
  }

  // MARK: - Column assignment

  func testATaskLandsInTheFirstColumnThatClaimsIt() {
    let columns = [
      KanbanColumn(name: "Today", conditions: [.dueBucket(RootDueBucket.today.rawValue)]),
      KanbanColumn(name: "Waiting", conditions: [.tag("waiting")]),
    ]

    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: columns,
      inputs: inputs(tags: [1: ["#waiting"]], buckets: [1: .today]))

    XCTAssertEqual(
      assigned?.name, "Today",
      "column order is the tie-break when a task matches more than one")
  }

  func testATaskMatchingNoColumnIsUnassigned() {
    let columns = [KanbanColumn(name: "Waiting", conditions: [.tag("waiting")])]

    XCTAssertNil(
      KanbanFilter.column(
        for: FixtureTask(id: 1), in: columns,
        inputs: inputs(tags: [:], buckets: [1: .today])))
  }

  func testTheShippedDefaultColumnsPlaceATodayTaskInToday() {
    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: KanbanColumn.defaults,
      inputs: inputs(tags: [:], buckets: [1: .today]))

    XCTAssertEqual(assigned?.name, "Today")
  }

  func testTheShippedDefaultColumnsPlaceAWaitingTaskInWaitingOn() {
    let assigned = KanbanFilter.column(
      for: FixtureTask(id: 1), in: KanbanColumn.defaults,
      inputs: inputs(tags: [1: ["#waiting"]], buckets: [1: .noDueDate]))

    XCTAssertEqual(assigned?.name, "Waiting On")
  }

  // MARK: - Subtree

  func testSubtreeTasksExcludesTheRootItself() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, parentId: 1),
      FixtureTask(id: 3, parentId: 2),
      FixtureTask(id: 4),
    ]
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

    let subtree = KanbanFilter.subtreeTasks(in: tasks, rootId: 1, taskById: byId)

    XCTAssertEqual(subtree.map(\.id), [2, 3])
  }

  // MARK: - Ordering

  func testPositionOrderPutsUnpositionedTasksLast() {
    let tasks = [
      FixtureTask(id: 1, content: "no position"),
      FixtureTask(id: 2, content: "second", position: 2),
      FixtureTask(id: 3, content: "first", position: 1),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .position, inputs: .init())

    XCTAssertEqual(
      sorted.map(\.id), [3, 2, 1],
      "the board treats a missing position as last, unlike the list comparator")
  }

  func testDueAscendingOrdersByDateAndKeepsUndatedLast() {
    let tasks = [
      FixtureTask(id: 1, content: "undated", position: 1),
      FixtureTask(id: 2, content: "later", dueDate: day(offset: 5), position: 2),
      FixtureTask(id: 3, content: "sooner", dueDate: day(offset: 1), position: 3),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .dueAscending, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [3, 2, 1])
  }

  /// "Latest first" reverses the dates. It must not promote undated tasks —
  /// they have no date to be latest.
  func testDueDescendingReversesTheDatesButKeepsUndatedLast() {
    let tasks = [
      FixtureTask(id: 1, content: "undated", position: 1),
      FixtureTask(id: 2, content: "later", dueDate: day(offset: 5), position: 2),
      FixtureTask(id: 3, content: "sooner", dueDate: day(offset: 1), position: 3),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .dueDescending, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [2, 3, 1])
  }

  func testPriorityOrderPutsAbsoluteRanksAheadOfScopedOnes() {
    let tasks = [
      FixtureTask(id: 1, content: "scoped", position: 1),
      FixtureTask(id: 2, content: "absolute", position: 2),
      FixtureTask(id: 3, content: "unranked", position: 3),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityAscending,
      inputs: .init(absolutePriorityRank: [2: 1], priorityRank: [1: 1]))

    XCTAssertEqual(sorted.map(\.id), [2, 1, 3])
  }

  func testEquallyRankedTasksFallBackToPosition() {
    let tasks = [
      FixtureTask(id: 1, content: "b", position: 2),
      FixtureTask(id: 2, content: "a", position: 1),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityAscending,
      inputs: .init(priorityRank: [1: 1, 2: 1]))

    XCTAssertEqual(sorted.map(\.id), [2, 1])
  }

  func testPriorityThenDueUsesDueOnlyAfterPriorityTies() {
    let tasks = [
      FixtureTask(id: 1, content: "ranked but later", dueDate: day(offset: 9), position: 1),
      FixtureTask(id: 2, content: "unranked and sooner", dueDate: day(offset: 1), position: 2),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityThenDueAscending,
      inputs: .init(priorityRank: [1: 1]))

    XCTAssertEqual(sorted.map(\.id), [1, 2], "priority wins before the date is consulted")
  }

  /// The last tie-break before position: with equal rank and equal date, a
  /// task carrying a tag is the more actionable one.
  func testPriorityThenDueBreaksRemainingTiesWithTagPresence() {
    let sameDate = day(offset: 2)
    let tasks = [
      FixtureTask(id: 1, content: "untagged", dueDate: sameDate, position: 1),
      FixtureTask(id: 2, content: "tagged", dueDate: sameDate, position: 2),
    ]

    let sorted = KanbanFilter.sorted(
      tasks, sortOrder: .priorityThenDueAscending,
      inputs: .init(tagsByTaskId: [2: ["#waiting"]]))

    XCTAssertEqual(sorted.map(\.id), [2, 1])
  }

  func testAlphabeticalIgnoresCaseAndFallsBackToPosition() {
    let tasks = [
      FixtureTask(id: 1, content: "banana", position: 2),
      FixtureTask(id: 2, content: "Apple", position: 3),
      FixtureTask(id: 3, content: "apple", position: 1),
    ]

    let sorted = KanbanFilter.sorted(tasks, sortOrder: .alphabetical, inputs: .init())

    XCTAssertEqual(sorted.map(\.id), [3, 2, 1])
  }

  func testEverySortOrderIsTotalAndLosesNothing() {
    let tasks = (1...6).map {
      FixtureTask(
        id: $0, content: "task \($0)",
        dueDate: $0.isMultiple(of: 2) ? day(offset: $0) : nil,
        position: $0.isMultiple(of: 3) ? nil : $0)
    }
    let inputs = KanbanFilter.SortInputs(
      absolutePriorityRank: [2: 1], priorityRank: [4: 1, 5: 2],
      tagsByTaskId: [3: ["#x"]])

    for order in KanbanSortOrder.allCases {
      let sorted = KanbanFilter.sorted(tasks, sortOrder: order, inputs: inputs)
      XCTAssertEqual(
        sorted.map(\.id).sorted(), tasks.map(\.id).sorted(),
        "\(order.rawValue) dropped or duplicated a card")
    }
  }
}

/// A board's first impression. Four columns keyed on due dates and tags show
/// nothing at all to someone who has set neither, which reads as broken rather
/// than empty.
final class KanbanDefaultBoardTests: XCTestCase {

  private func inputs() -> KanbanFilter.MembershipInputs<FixtureTask> {
    KanbanFilter.MembershipInputs(dueBucket: { _ in .noDueDate })
  }

  func testATaskWithNoDueDateAndNoTagsStillLandsSomewhere() {
    let columns = KanbanColumn.defaults
    let task = FixtureTask(id: 1, content: "learn drums", position: 1)
    let assigned = columns.first { column in
      KanbanFilter.matchesColumn(task, column: column, inputs: inputs())
    }
    XCTAssertNil(assigned, "no specific condition should claim it")
    XCTAssertEqual(
      columns.last?.conditions, [.catchAll],
      "so the last column must be the catch-all that does")
  }

  /// Order is the whole contract: a catch-all anywhere but last swallows the
  /// board, since every task matches it.
  func testTheCatchAllIsLastAndIsTheOnlyOne() {
    let catchAllIndices = KanbanColumn.defaults.indices.filter { index in
      KanbanColumn.defaults[index].conditions.contains(.catchAll)
    }
    XCTAssertEqual(catchAllIndices, [KanbanColumn.defaults.count - 1])
  }
}
