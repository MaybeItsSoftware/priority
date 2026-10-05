import Foundation
import Observation
import TaktCore
import TaktWorkspace

enum ReviewSection: String, CaseIterable, Identifiable {
  case timeline, done, progress
  var id: String { rawValue }
  var title: String {
    switch self {
    case .timeline: "Timeline"
    case .done: "Done"
    case .progress: "Progress"
    }
  }
}

/// One day of focus, laid out on an hour ruler, with a per-task breakdown.
/// Pure, so the chart, the summary and the breakdown describe one instant.
struct TimelineDay: Equatable, Sendable {
  struct TaskSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let seconds: Int
    let blocks: Int
    /// Index into the identity palette, stable between ruler and breakdown.
    let hue: Int
  }

  var date: Date
  var layout: FocusDayTimeline.Layout
  var totalSeconds: Int
  var points: Double
  var summaries: [TaskSummary]
  /// Block id → task key, for colouring a block by its task.
  var taskKeys: [String: String]
  var awards: [String: FocusAward]

  /// A logged block as the timeline needs it.
  struct Input: Sendable, Equatable {
    let id: String
    /// The task the block belongs to, kept across renames and deletion.
    let taskKey: String
    let title: String
    let seconds: Int
    let recordedAt: Date

    init(id: String, taskKey: String, title: String, seconds: Int, recordedAt: Date) {
      self.id = id; self.taskKey = taskKey; self.title = title; self.seconds = seconds; self.recordedAt = recordedAt
    }

    init(_ block: FocusWorkBlock) {
      self.init(
        id: block.id, taskKey: block.originalTaskId ?? block.taskId ?? block.taskTitle, title: block.taskTitle,
        seconds: block.seconds, recordedAt: block.recordedAt)
    }
  }

  static func build(
    day: Date, blocks: [Input], awards: [FocusAward], live: (id: String, taskID: String, title: String, seconds: Int)?,
    now: Date = .now, calendar: Calendar = .current
  ) -> TimelineDay {
    let logged = blocks.filter { $0.seconds > 0 }
    var assembled = logged.map {
      FocusDayTimeline.Block(id: $0.id, title: $0.title, seconds: $0.seconds, endedAt: $0.recordedAt)
    }
    var keys: [String: String] = [:]
    for block in logged { keys[block.id] = block.taskKey }
    if let live, live.seconds > 0, calendar.isDate(day, inSameDayAs: now) {
      assembled.append(FocusDayTimeline.Block(id: live.id, title: live.title, seconds: live.seconds, endedAt: now, isLive: true))
      keys[live.id] = live.taskID
    }
    let awardsByID = Dictionary(awards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let grouped = Dictionary(grouping: assembled) { (block: FocusDayTimeline.Block) -> String in
      keys[block.id] ?? block.title
    }
    var summaries: [TaskSummary] = []
    for (key, values) in grouped {
      let seconds = values.reduce(0) { $0 + $1.seconds }
      summaries.append(TaskSummary(
        id: key, title: values.last?.title ?? "Deleted task", seconds: seconds, blocks: values.count, hue: 0))
    }
    summaries.sort { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    summaries = summaries.enumerated().map { index, summary in
      TaskSummary(id: summary.id, title: summary.title, seconds: summary.seconds, blocks: summary.blocks, hue: index)
    }
    let points = logged.compactMap { awardsByID[$0.id]?.points }.reduce(0, +)
    return TimelineDay(
      date: day,
      layout: FocusDayTimeline.layout(blocks: assembled, day: day, calendar: calendar),
      totalSeconds: assembled.reduce(0) { $0 + $1.seconds },
      points: points,
      summaries: summaries,
      taskKeys: keys,
      awards: awardsByID)
  }

  func hue(forBlock id: String) -> Int {
    let key = taskKeys[id] ?? id
    return summaries.first { $0.id == key }?.hue ?? 0
  }
}

/// A day of the progress chart: tasks finished, tasks added, minutes focused.
struct ProgressDay: Identifiable, Equatable, Sendable {
  let day: Date
  let completed: Int
  let added: Int
  let focusMinutes: Int
  var id: Date { day }
}

struct ProgressSummary: Equatable, Sendable {
  var days: [ProgressDay] = []
  var totalCompleted = 0
  var totalAdded = 0
  var focusMinutes = 0
  var bestDay: ProgressDay?

  static func build(
    period: TaskProgressPeriod, completions: [Date], creations: [Date], blocks: [(seconds: Int, recordedAt: Date)],
    now: Date = .now, calendar: Calendar = .current
  ) -> ProgressSummary {
    let series = TaskProgressSeries.build(
      period: period, completions: completions, creations: creations, now: now, calendar: calendar)
    let minutes = blocks.reduce(into: [Date: Int]()) { result, block in
      result[calendar.startOfDay(for: block.recordedAt), default: 0] += block.seconds
    }
    let days = series.days.map {
      ProgressDay(day: $0.dayStart, completed: $0.completed, added: $0.added, focusMinutes: minutes[$0.dayStart, default: 0] / 60)
    }
    return ProgressSummary(
      days: days, totalCompleted: series.totalCompleted, totalAdded: series.totalAdded,
      focusMinutes: days.reduce(0) { $0 + $1.focusMinutes },
      bestDay: days.filter { $0.completed > 0 }.max { $0.completed < $1.completed })
  }
}

/// A finished task as the done rail draws it.
struct DoneItem: Identifiable, Equatable, Sendable {
  let task: WorkspaceTask
  let listName: String
  var id: String { task.id }
}

struct DoneGroup: Identifiable, Equatable, Sendable {
  let day: Date
  let kind: CompletedWorkDayKind
  let items: [DoneItem]
  var id: Date { day }

  var title: String {
    switch kind {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .thisWeek: day.formatted(.dateTime.weekday(.wide))
    case .earlier: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
  }
}

/// Review: what the day's focus looked like, what got done, and the trend.
@MainActor
@Observable
final class ReviewModel {
  nonisolated static let doneWindowDays = 35
  static let periodKey = "reviewProgressPeriod"

  let model: WorkspaceModel
  var section: ReviewSection = .timeline
  var timelineDate = Date.now
  var period: TaskProgressPeriod {
    didSet { UserDefaults.standard.set(period.rawValue, forKey: Self.periodKey) }
  }
  private(set) var timeline: TimelineDay?
  private(set) var doneGroups: [DoneGroup] = []
  private(set) var progress = ProgressSummary()

  init(model: WorkspaceModel) {
    self.model = model
    period = TaskProgressPeriod(rawValue: UserDefaults.standard.string(forKey: Self.periodKey) ?? "") ?? .week
  }

  var showsToday: Bool { Calendar.current.isDateInToday(timelineDate) }

  /// Never past today: the future holds no logged work.
  func moveDay(by days: Int) {
    guard let date = Calendar.current.date(byAdding: .day, value: days, to: timelineDate) else { return }
    timelineDate = min(date, .now)
  }

  // MARK: - Loading (off the main actor)

  func loadTimeline(now: Date = .now) async {
    let store = model.store
    let day = timelineDate
    let result = await Task.detached(priority: .userInitiated) { () -> TimelineDay? in
      Self.readTimeline(store: store, day: day, now: now)
    }.value
    if let result, result != timeline { timeline = result }
  }

  nonisolated static func readTimeline(store: WorkspaceStore, day: Date, now: Date) -> TimelineDay? {
    guard let interval = Calendar.current.dateInterval(of: .day, for: day),
      let blocks = try? store.focusWorkBlocks(in: interval) else { return nil }
    let awards = (try? store.focusAwards(onDayOf: day)) ?? []
    var live: (id: String, taskID: String, title: String, seconds: Int)?
    if let session = try? store.activeFocusSession(), let taskID = session.activeTaskId,
      let task = try? store.task(id: taskID) {
      live = (session.activeBlockId ?? "live/\(session.id)", taskID, task.title, session.elapsedSeconds(now: now))
    }
    return TimelineDay.build(day: day, blocks: blocks.map(TimelineDay.Input.init), awards: awards, live: live, now: now)
  }

  func loadDone(now: Date = .now) async {
    let store = model.store
    let names = Dictionary(
      (model.structure.lists + model.structure.archivedLists).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let groups = await Task.detached(priority: .userInitiated) {
      Self.readDone(store: store, listNames: names, now: now)
    }.value
    if groups != doneGroups { doneGroups = groups }
  }

  nonisolated static func readDone(store: WorkspaceStore, listNames: [String: String], now: Date) -> [DoneGroup] {
    let since = Calendar.current.date(byAdding: .day, value: -doneWindowDays, to: now) ?? .distantPast
    let tasks = (try? store.completedTasks(since: since)) ?? []
    return CompletedWorkDigest.group(tasks, completedAt: { $0.completedAt ?? .distantPast }, now: now).map { group in
      DoneGroup(
        day: group.dayStart, kind: group.kind,
        items: group.items.map { DoneItem(task: $0, listName: listNames[$0.listId] ?? "") })
    }
  }

  func loadProgress(now: Date = .now) async {
    let store = model.store
    let period = period
    let summary = await Task.detached(priority: .userInitiated) {
      Self.readProgress(store: store, period: period, now: now)
    }.value
    if summary != progress { progress = summary }
  }

  nonisolated static func readProgress(store: WorkspaceStore, period: TaskProgressPeriod, now: Date) -> ProgressSummary {
    let interval = TaskProgressSeries.interval(for: period, now: now)
    return ProgressSummary.build(
      period: period,
      completions: (try? store.taskCompletions(in: interval)) ?? [],
      creations: (try? store.taskCreations(in: interval)) ?? [],
      blocks: ((try? store.focusWorkBlocks(in: interval)) ?? []).map { (seconds: $0.seconds, recordedAt: $0.recordedAt) },
      now: now)
  }

  // MARK: - Done actions

  func reopen(_ taskID: String) {
    model.perform { try $0.setStatus(.open, for: taskID) }
  }

  /// Opens the task's list in the outline with completed tasks showing and
  /// its branch unfolded, and selects it.
  func reveal(_ task: WorkspaceTask, isPad: Bool) {
    let scope = ListScope.list(task.listId)
    UserDefaults.standard.set(false, forKey: "outlineHidesCompleted")
    let foldKey = "outlineFolds.\(scope.storageKey)"
    var folds = Set(UserDefaults.standard.stringArray(forKey: foldKey) ?? [])
    var parent = task.parentTaskId
    while let id = parent, let ancestor = model.task(id) {
      folds.remove(id)
      parent = ancestor.parentTaskId
    }
    UserDefaults.standard.set(Array(folds).sorted(), forKey: foldKey)
    model.navigation.viewMode = .outline
    model.navigation.open(scope, isPad: isPad)
    model.navigation.selectedTaskID = task.id
  }
}
