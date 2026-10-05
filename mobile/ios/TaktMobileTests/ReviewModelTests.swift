import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

@MainActor
final class ReviewModelTests: XCTestCase {
  private var model: WorkspaceModel!
  private var review: ReviewModel!
  private var listID: String!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    listID = try XCTUnwrap(model.inbox?.id)
    review = ReviewModel(model: model)
  }

  private func block(_ id: String, task: String, title: String, seconds: Int, at date: Date) -> TimelineDay.Input {
    TimelineDay.Input(id: id, taskKey: task, title: title, seconds: seconds, recordedAt: date)
  }

  func testTimelineGroupsBlocksByTaskAndOrdersByTime() {
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
    let at = { (hour: Int) in calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }
    let blocks = [
      block("b1", task: "t1", title: "Write", seconds: 1_800, at: at(10)),
      block("b2", task: "t2", title: "Read", seconds: 3_600, at: at(12)),
      block("b3", task: "t1", title: "Write", seconds: 2_400, at: at(15)),
    ]
    let timeline = TimelineDay.build(day: day, blocks: blocks, awards: [], live: nil, now: day, calendar: calendar)
    XCTAssertEqual(timeline.totalSeconds, 7_800)
    XCTAssertEqual(timeline.summaries.map(\.title), ["Write", "Read"])
    XCTAssertEqual(timeline.summaries.first?.blocks, 2)
    XCTAssertEqual(timeline.hue(forBlock: "b3"), timeline.hue(forBlock: "b1"))
    XCTAssertNotEqual(timeline.hue(forBlock: "b2"), timeline.hue(forBlock: "b1"))
    XCTAssertEqual(timeline.layout.placements.count, 3)
  }

  func testTimelineDrawsTheRunningBlockOnlyToday() {
    let now = Date.now
    let live = (id: "live", taskID: "t", title: "Running", seconds: 600)
    let today = TimelineDay.build(day: now, blocks: [], awards: [], live: live, now: now)
    XCTAssertEqual(today.totalSeconds, 600)
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    XCTAssertEqual(TimelineDay.build(day: yesterday, blocks: [], awards: [], live: live, now: now).totalSeconds, 0)
  }

  func testDoneGroupsCompletedTasksAndReopenRestoresThem() async throws {
    let task = try model.store.createTask(listId: listID, title: "Finished")
    try model.store.setStatus(.completed, for: task.id)
    await review.loadDone()
    XCTAssertEqual(review.doneGroups.first?.kind, .today)
    XCTAssertEqual(review.doneGroups.first?.items.map(\.task.title), ["Finished"])
    XCTAssertEqual(review.doneGroups.first?.items.first?.listName, "Inbox")

    review.reopen(task.id)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .open)
    await review.loadDone()
    XCTAssertTrue(review.doneGroups.isEmpty)
  }

  func testRevealOpensTheListUnfoldedWithCompletedShowing() throws {
    let parent = try model.store.createTask(listId: listID, title: "Parent")
    let child = try model.store.createTask(listId: listID, title: "Child", parentTaskId: parent.id)
    let foldKey = "outlineFolds.\(ListScope.list(listID).storageKey)"
    UserDefaults.standard.set([parent.id], forKey: foldKey)
    UserDefaults.standard.set(true, forKey: "outlineHidesCompleted")
    review.reveal(try XCTUnwrap(model.task(child.id)), isPad: false)
    XCTAssertEqual(model.navigation.listPath, [.list(listID)])
    XCTAssertEqual(model.navigation.selectedTaskID, child.id)
    XCTAssertEqual(model.navigation.viewMode, .outline)
    XCTAssertFalse(UserDefaults.standard.bool(forKey: "outlineHidesCompleted"))
    XCTAssertEqual(UserDefaults.standard.stringArray(forKey: foldKey), [])
  }

  func testProgressCountsFinishedAddedAndFocus() async throws {
    let task = try model.store.createTask(listId: listID, title: "One")
    _ = try model.store.createTask(listId: listID, title: "Two")
    try model.store.setStatus(.completed, for: task.id)
    review.period = .week
    await review.loadProgress()
    XCTAssertEqual(review.progress.days.count, 7)
    XCTAssertEqual(review.progress.totalCompleted, 1)
    XCTAssertEqual(review.progress.totalAdded, 2)
    XCTAssertEqual(review.progress.days.last?.completed, 1)
  }

  func testTimelineDayStepsNeverPassToday() {
    review.timelineDate = .now
    review.moveDay(by: 1)
    XCTAssertTrue(review.showsToday)
    review.moveDay(by: -1)
    XCTAssertFalse(review.showsToday)
  }
}
