import XCTest

@testable import TaktCore

/// `TaskVisibilityEngine` is the single function that answers "what rows does
/// the popover show, in what order" for every combination of root view, scope
/// filter, search and drill-down level. It had no coverage at all until it
/// moved into `TaktCore`.
///
/// The context is wired with the real `TaskFilterEngine` implementations rather
/// than stubs, so these exercise the composition the app actually runs.
final class TaskVisibilityEngineTests: XCTestCase {

  // MARK: - Context builder

  private func makeContext(
    tasks: [FixtureTask],
    currentParentId: Int = 0,
    rootTaskView: RootTaskView = .all,
    isSearchFilterActive: Bool = false,
    searchText: String = "",
    hideFuture: Bool = false,
    showChildrenInMenus: Bool = true,
    selectedRootDueBucket: RootDueBucket? = nil,
    selectedRootTag: String = "",
    priorityRankById: [Int: Int] = [:],
    absolutePriorityRankById: [Int: Int] = [:],
    shouldShowRootScopeSection: Bool? = nil
  ) -> TaskVisibilityEngine.Context<FixtureTask> {
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let tagsByTaskId = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)
    let bucketById = TaskFilterEngine.computeRootDueBuckets(tasks: tasks)

    func hasTag(_ task: FixtureTask, _ tag: String) -> Bool {
      (tagsByTaskId[task.id] ?? []).contains(tag.lowercased())
    }

    // Mirrors `TaskListViewModel.taskMatchesActiveRootScope`: what "matching"
    // means depends on which root tab is showing.
    func matchesActiveRootScope(_ task: FixtureTask) -> Bool {
      switch rootTaskView {
      case .due:
        if let selectedRootDueBucket {
          return bucketById[task.id] == selectedRootDueBucket
        }
        return bucketById[task.id] != .noDueDate
      case .tags:
        if selectedRootTag.isEmpty { return !(tagsByTaskId[task.id] ?? []).isEmpty }
        return hasTag(task, selectedRootTag)
      case .priority:
        return priorityRankById[task.id] != nil || absolutePriorityRankById[task.id] != nil
      case .all, .kanban, .eisenhower, .daily:
        return true
      }
    }

    return .init(
      tasks: tasks,
      currentLevelTasks: tasks.filter { ($0.parentId ?? 0) == currentParentId },
      currentParentId: currentParentId,
      isSearchFilterActive: isSearchFilterActive,
      searchText: searchText,
      hideFuture: hideFuture,
      shouldShowRootScopeSection: shouldShowRootScopeSection ?? !isSearchFilterActive,
      isRootLevel: currentParentId == 0,
      rootTaskView: rootTaskView,
      showChildrenInMenus: showChildrenInMenus,
      selectedRootDueBucket: selectedRootDueBucket,
      selectedRootTag: selectedRootTag,
      taskById: byId,
      isDescendant: { TaskFilterEngine.isDescendant($0, of: $1, taskById: byId) },
      taskMatchesActiveRootScope: matchesActiveRootScope,
      isAbsolutePrioritized: { absolutePriorityRankById[$0.id] != nil },
      compareByPriorityThenPosition: {
        TaskFilterEngine.compareByPriorityThenPosition(
          $0, $1,
          priorityRankById: priorityRankById,
          absolutePriorityRankById: absolutePriorityRankById)
      },
      compareByRootDueBucket: {
        TaskFilterEngine.compareByRootDueBucket($0, $1, rootDueBucketById: bucketById)
      },
      hasAnyTag: { !(tagsByTaskId[$0.id] ?? []).isEmpty },
      hasTag: { hasTag($0, $1) },
      rootDueBucket: { bucketById[$0.id] ?? .noDueDate }
    )
  }

  private func ids(_ result: TaskVisibilityEngine.Result<FixtureTask>) -> [Int] {
    result.tasks.map(\.id)
  }

  private func day(offset: Int) -> Date {
    let calendar = Calendar.current
    return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
  }

  // MARK: - Search

  func testSearchMatchesContentCaseInsensitivelyAndIgnoresTheRootView() {
    let tasks = [
      FixtureTask(id: 1, content: "Write the REPORT", position: 1),
      FixtureTask(id: 2, content: "Buy milk", position: 2),
      FixtureTask(id: 3, content: "report to Jane", position: 3),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(
        tasks: tasks, rootTaskView: .priority,
        isSearchFilterActive: true, searchText: "report"))

    XCTAssertEqual(ids(result), [1, 3])
  }

  /// Search is scoped to the subtree the user has drilled into, not the whole
  /// list — otherwise drilling in and searching would jump back out.
  func testSearchStaysInsideTheCurrentSubtree() {
    let tasks = [
      FixtureTask(id: 1, content: "report A", position: 1),
      FixtureTask(id: 2, content: "parent", position: 2),
      FixtureTask(id: 3, content: "report B", position: 1, parentId: 2),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(
        tasks: tasks, currentParentId: 2,
        isSearchFilterActive: true, searchText: "report"))

    XCTAssertEqual(ids(result), [3])
  }

  // MARK: - Root views that render their own surface

  func testKanbanEisenhowerAndDailyProduceNoRows() {
    let tasks = [FixtureTask(id: 1, content: "a", position: 1)]
    for view in [RootTaskView.kanban, .eisenhower, .daily] {
      let result = TaskVisibilityEngine.compute(
        in: makeContext(tasks: tasks, rootTaskView: view))
      XCTAssertTrue(
        result.tasks.isEmpty,
        "\(view.title) draws its own surface; stale rows here desync the selection index")
    }
  }

  // MARK: - All

  func testTheAllViewShowsOnlyTheCurrentLevelEvenWithChildrenInMenusOn() {
    let tasks = [
      FixtureTask(id: 1, content: "root a", position: 1),
      FixtureTask(id: 2, content: "root b", position: 2),
      FixtureTask(id: 3, content: "child", position: 1, parentId: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .all, showChildrenInMenus: true))

    XCTAssertEqual(ids(result), [1, 2], "All stays hierarchical — that is what it is for")
  }

  func testTheAllViewSortsPrioritisedTasksFirst() {
    let tasks = [
      FixtureTask(id: 1, content: "a", position: 1),
      FixtureTask(id: 2, content: "b", position: 2),
      FixtureTask(id: 3, content: "c", position: 3),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .all, priorityRankById: [3: 1]))

    XCTAssertEqual(ids(result), [3, 1, 2])
  }

  // MARK: - Due

  func testTheDueViewHidesUndatedTasksWhenNoBucketIsSelected() {
    let tasks = [
      FixtureTask(id: 1, content: "dated", due: "today", position: 1),
      FixtureTask(id: 2, content: "undated", position: 2),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due))

    XCTAssertEqual(ids(result), [1])
  }

  func testSelectingABucketNarrowsToThatBucket() {
    let tasks = [
      FixtureTask(id: 1, content: "today", due: "today", position: 1),
      FixtureTask(id: 2, content: "asap", due: "asap", position: 2),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due, selectedRootDueBucket: .asap))

    XCTAssertEqual(ids(result), [2])
  }

  func testTheDueViewOrdersByUrgencyNotByPosition() {
    let tasks = [
      FixtureTask(id: 1, content: "later", due: "x", dueDate: day(offset: 3), position: 1),
      FixtureTask(id: 2, content: "overdue", due: "x", dueDate: day(offset: -2), position: 2),
      FixtureTask(id: 3, content: "today", due: "x", dueDate: day(offset: 0), position: 3),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due))

    XCTAssertEqual(ids(result), [2, 3, 1])
  }

  func testTheDueViewCanReachDescendantsWhenChildrenInMenusIsOn() {
    let tasks = [
      FixtureTask(id: 1, content: "parent", position: 1),
      FixtureTask(id: 2, content: "child", due: "today", position: 1, parentId: 1),
    ]

    let shown = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due, showChildrenInMenus: true))
    XCTAssertEqual(ids(shown), [2])

    let hidden = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due, showChildrenInMenus: false))
    XCTAssertTrue(hidden.tasks.isEmpty, "off, the due list is siblings-only")
  }

  // MARK: - Tags

  func testTheTagsViewShowsEverythingTaggedUntilATagIsChosen() {
    let tasks = [
      FixtureTask(id: 1, content: "email @work", position: 1),
      FixtureTask(id: 2, content: "run #health", position: 2),
      FixtureTask(id: 3, content: "untagged", position: 3),
    ]

    let all = TaskVisibilityEngine.compute(in: makeContext(tasks: tasks, rootTaskView: .tags))
    XCTAssertEqual(ids(all), [1, 2])

    let narrowed = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .tags, selectedRootTag: "@work"))
    XCTAssertEqual(ids(narrowed), [1])
  }

  // MARK: - Priority

  func testThePriorityViewShowsOnlyRankedTasks() {
    let tasks = [
      FixtureTask(id: 1, content: "ranked", position: 1),
      FixtureTask(id: 2, content: "unranked", position: 2),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .priority, priorityRankById: [1: 1]))

    XCTAssertEqual(ids(result), [1])
  }

  /// Showing both a prioritised parent and its prioritised child at the root
  /// says the same thing twice; the user drills in to see the child.
  func testAPrioritisedDescendantIsFoldedIntoItsPrioritisedAncestor() {
    let tasks = [
      FixtureTask(id: 1, content: "parent", position: 1),
      FixtureTask(id: 2, content: "child", position: 1, parentId: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(
        tasks: tasks, rootTaskView: .priority, priorityRankById: [1: 1, 2: 2]))

    XCTAssertEqual(ids(result), [1])
  }

  /// Absolute priority is the "regardless of where it sits" rank, so it has to
  /// escape a merely scope-prioritised ancestor.
  func testAnAbsolutelyPrioritisedChildEscapesAScopedAncestor() {
    let tasks = [
      FixtureTask(id: 1, content: "parent", position: 1),
      FixtureTask(id: 2, content: "child", position: 1, parentId: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(
        tasks: tasks, rootTaskView: .priority,
        priorityRankById: [1: 1], absolutePriorityRankById: [2: 1]))

    XCTAssertEqual(ids(result).sorted(), [1, 2])
  }

  func testACycleInThePriorityAncestorWalkTerminates() {
    let tasks = [
      FixtureTask(id: 1, content: "a", position: 1, parentId: 2),
      FixtureTask(id: 2, content: "b", position: 2, parentId: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(
        tasks: tasks, rootTaskView: .priority, priorityRankById: [1: 1, 2: 2]))

    // Reaching this line at all is the point — the walk must terminate rather
    // than spin on the main actor. Each task sees the other as a prioritised
    // ancestor, so both fold away.
    XCTAssertTrue(result.tasks.isEmpty)
  }

  // MARK: - Hide future

  func testHideFutureKeepsOnlyWhatIsDueByTomorrow() {
    let tasks = [
      FixtureTask(id: 1, content: "today", due: "x", dueDate: day(offset: 0), position: 1),
      FixtureTask(id: 2, content: "next week", due: "x", dueDate: day(offset: 7), position: 2),
      FixtureTask(id: 3, content: "undated", position: 3),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .all, hideFuture: true))

    XCTAssertEqual(ids(result), [1], "undated tasks are future too, as far as this filter goes")
  }

  // MARK: - Drilled in

  func testDrillingIntoASubtreeShowsItsChildren() {
    let tasks = [
      FixtureTask(id: 1, content: "parent", position: 1),
      FixtureTask(id: 2, content: "child a", position: 1, parentId: 1),
      FixtureTask(id: 3, content: "child b", position: 2, parentId: 1),
      FixtureTask(id: 4, content: "elsewhere", position: 2),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, currentParentId: 1, rootTaskView: .all))

    XCTAssertEqual(ids(result), [2, 3])
  }

  func testASubLevelDueViewStillFiltersByTheActiveScope() {
    let tasks = [
      FixtureTask(id: 1, content: "parent", position: 1),
      FixtureTask(id: 2, content: "dated", due: "today", position: 1, parentId: 1),
      FixtureTask(id: 3, content: "undated", position: 2, parentId: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, currentParentId: 1, rootTaskView: .due))

    XCTAssertEqual(ids(result), [2])
  }

  func testWithoutTheRootScopeSectionTheListIsJustTheCurrentLevel() {
    let tasks = [
      FixtureTask(id: 1, content: "a", due: "today", position: 2),
      FixtureTask(id: 2, content: "b", position: 1),
    ]

    let result = TaskVisibilityEngine.compute(
      in: makeContext(tasks: tasks, rootTaskView: .due, shouldShowRootScopeSection: false))

    XCTAssertEqual(ids(result), [2, 1], "no filtering, ordered by position")
  }
}
