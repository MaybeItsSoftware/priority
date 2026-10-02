import Foundation
import Observation
import PriorityCore
import PriorityWorkspace

/// One card in the day. A value, so the list redraws only cards that changed.
struct DayCard: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let listName: String?
  let listColorHex: String?
  /// Why the task is in the day; nil for the fallback ranking, where nothing
  /// chose it.
  let reason: DayPlanReason?
  let estimateSeconds: Int?
  /// Time logged against the task across every block, before any running one.
  let loggedSeconds: Int
  let dueAt: Date?
  let isList: Bool
  /// A daily expected today: ticking logs a contribution rather than
  /// completing the task.
  let dailyID: String?
  let isDailyDoneToday: Bool
  let isRunning: Bool

  var isPlanned: Bool { reason == .planned }

  /// What a card says under its title. The reason beats the deadline:
  /// "overdue" is the thing worth reading. `.planned` goes unsaid, because
  /// every card in the day is in it.
  var detail: String? {
    switch reason {
    case .overdue, .dueToday, .startsToday: return reason?.label
    case .running, .planned, nil:
      return dueAt.map { "Due \(Format.due($0).lowercased())" }
    }
  }

  var menuContext: TaskMenuContext {
    TaskMenuContext(
      taskID: id, title: title, status: .open, isList: isList, isPromoted: false, isPlanned: isPlanned,
      allowsStructure: false)
  }
}

/// A daily expected today, for the dailies strip under the day.
struct DayDaily: Identifiable, Equatable, Sendable {
  let id: String
  let taskID: String
  let title: String
  let isDone: Bool
  let secondsToday: Int
  let targetSeconds: Int?
}

/// Everything the Today screen draws, read in one go off the main actor.
struct DaySnapshot: Equatable, Sendable {
  var cards: [DayCard] = []
  var dailies: [DayDaily] = []
  var session: FocusSession?
  /// Tasks still queued behind the running one — what Skip moves on to.
  var queuedTaskIDs: [String] = []
  var workProgress: WorkProgress = .empty
  /// Seconds in finished blocks today.
  var loggedToday = 0
  /// Whether the day came from the plan rather than the fallback ranking.
  var isPlanned = false

  static let empty = DaySnapshot()

  var runningCard: DayCard? { cards.first { $0.isRunning } }
  var plannedIDs: [String] { cards.filter(\.isPlanned).map(\.id) }
  var hasQueuedSuccessor: Bool {
    queuedTaskIDs.contains { $0 != session?.activeTaskId }
  }

  /// The day's finish-by figure, the running block's time included.
  func forecast(now: Date) -> DayForecast {
    let runningID = session?.phase == .running ? session?.activeTaskId : nil
    let entries = cards.map { card -> DayForecast.Entry in
      var logged = card.loggedSeconds
      if card.id == runningID, let session { logged += session.elapsedSeconds(now: now) }
      return DayForecast.Entry(estimateSeconds: card.estimateSeconds, loggedSeconds: logged)
    }
    return DayForecast(entries: entries, now: now)
  }

  /// Reads the day the way the Mac's `nextUpSnapshot` → `rebuildDayItems`
  /// does: the plan resolved to tasks, or the head of the ranking when
  /// nothing was planned. Pure over the store; safe off the main actor.
  static func load(
    store: WorkspaceStore, workspaceID: String, lists: [TaskList], now: Date = .now
  ) throws -> DaySnapshot {
    var day = DaySnapshot()
    let session = try store.activeFocusSession()
    day.session = session
    if let session {
      day.queuedTaskIDs = try store.focusQueue(for: session.id)
        .filter { $0.item.state == .queued }.map(\.task.id)
    }
    let snapshot = try store.nextUpSnapshot(
      workspaceId: workspaceID, context: FocusContext(), runningID: session?.activeTaskId, now: now)
    day.workProgress = snapshot.workProgress
    if let today = Calendar.current.dateInterval(of: .day, for: now) {
      day.loggedToday = try store.focusWorkBlocks(in: today).reduce(0) { $0 + $1.seconds }
    }
    let dailies = try store.dailies(on: now)
    let dailyByTask = Dictionary(dailies.map { ($0.task.id, $0) }, uniquingKeysWith: { first, _ in first })
    day.dailies = dailies.map {
      DayDaily(
        id: $0.daily.id, taskID: $0.task.id, title: $0.task.title, isDone: $0.isDoneToday,
        secondsToday: $0.secondsLoggedToday, targetSeconds: $0.daily.targetSeconds)
    }

    let entries: [(String, DayPlanReason?)]
    if snapshot.todayPlan.isEmpty {
      entries = snapshot.ranking.ranked.prefix(WorkspaceNextUpSnapshot.fallbackDayLength).map { ($0.candidate.id, nil) }
    } else {
      day.isPlanned = true
      entries = snapshot.todayPlan.map { ($0.id, $0.reason) }
    }
    let listsByID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    day.cards = entries.compactMap { id, reason in
      guard seen.insert(id).inserted, let task = snapshot.dayTasks[id] else { return nil }
      let daily = dailyByTask[id]
      let list = listsByID[task.listId]
      return DayCard(
        id: id, title: task.title, listName: list?.name, listColorHex: list?.colorHex, reason: reason,
        estimateSeconds: task.estimateSeconds, loggedSeconds: snapshot.loggedSeconds[id] ?? 0,
        dueAt: task.dueAt, isList: task.isList, dailyID: daily?.daily.id,
        isDailyDoneToday: daily?.isDoneToday ?? false,
        isRunning: id == session?.activeTaskId && session?.phase == .running)
    }
    return day
  }
}

/// A finished block waiting to be told how it went. The seconds are captured
/// the instant Done is pressed: the clock stops when the work stops, not when
/// the judgement arrives.
struct PendingBlockCompletion: Identifiable, Equatable {
  let sessionID: String
  let taskID: String
  let title: String
  let seconds: Int
  let completeTask: Bool
  let blockID: String?
  let wasPaused: Bool

  var id: String { "\(sessionID)/\(taskID)/\(completeTask)" }
}

/// The Today screen's state: the day as last read, and the block awaiting a
/// score.
@MainActor
@Observable
final class TodayModel {
  private(set) var day = DaySnapshot.empty
  private(set) var isLoaded = false
  var pendingCompletion: PendingBlockCompletion?
  @ObservationIgnored private var generation = 0

  /// Reads the day off the main actor and lands it if nothing newer was
  /// asked for meanwhile.
  func load(_ model: WorkspaceModel) async {
    generation &+= 1
    let mine = generation
    let store = model.store
    let workspaceID = model.workspace.id
    let lists = model.structure.lists + model.structure.archivedLists
    let result = await Task.detached(priority: .userInitiated) {
      try? DaySnapshot.load(store: store, workspaceID: workspaceID, lists: lists)
    }.value
    guard mine == generation, let result else { return }
    if day != result { day = result }
    isLoaded = true
  }

  // MARK: - Arranging

  /// Moves a planned card `offset` places through the planned part of the
  /// day, writing the whole planned order so it holds when scores change.
  func movePlanned(_ taskID: String, by offset: Int, model: WorkspaceModel) {
    guard let arranged = DayArrangement.moving(taskID, by: offset, in: day.plannedIDs) else {
      if day.cards.first(where: { $0.id == taskID })?.isPlanned == false {
        model.showToast("Only planned tasks can be arranged — plan it first")
      }
      return
    }
    arrange(arranged, model: model)
  }

  /// A drag in the list. Only planned cards move; the order of the rest is
  /// the dates'.
  func move(from source: IndexSet, to destination: Int, model: WorkspaceModel) {
    var cards = day.cards
    guard let index = source.first, cards.indices.contains(index), cards[index].isPlanned else { return }
    cards.move(fromOffsets: source, toOffset: destination)
    let arranged = cards.filter(\.isPlanned).map(\.id)
    guard arranged != day.plannedIDs else { return }
    arrange(arranged, model: model)
  }

  /// Writes the order and shows it straight away, rather than waiting for the
  /// next read.
  private func arrange(_ order: [String], model: WorkspaceModel) {
    var next = day
    let planned = Dictionary(uniqueKeysWithValues: day.cards.filter(\.isPlanned).map { ($0.id, $0) })
    var queue = order.makeIterator()
    next.cards = day.cards.map { card in
      guard card.isPlanned, let id = queue.next(), let replacement = planned[id] else { return card }
      return replacement
    }
    day = next
    model.perform { try $0.arrangeDay(orderedTaskIds: order) }
  }

  // MARK: - Ticking off

  /// A daily logs today's contribution and leaves the task open; anything
  /// else is completed. The distinction the daily model rests on.
  func tickOff(_ card: DayCard, model: WorkspaceModel) {
    if card.isRunning {
      requestCompletion(completeTask: true, model: model)
      return
    }
    if let dailyID = card.dailyID {
      guard !card.isDailyDoneToday else { return }
      if model.perform({ _ = try $0.logContribution(dailyId: dailyID) }) { model.noteCompletion() }
    } else {
      model.toggleComplete(card.id)
    }
  }

  func toggleDaily(_ daily: DayDaily, model: WorkspaceModel) {
    if daily.isDone {
      model.perform { try $0.clearContribution(dailyId: daily.id) }
    } else if model.perform({ _ = try $0.logContribution(dailyId: daily.id) }) {
      model.noteCompletion()
    }
  }

  /// Not today: pushes the task's start to tomorrow morning, and takes it
  /// off the day if it was planned.
  func deferToTomorrow(_ card: DayCard, model: WorkspaceModel) {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    let ok = model.perform { store in
      if card.isPlanned { try store.setPlannedForToday(false, taskIds: [card.id]) }
      try store.scheduleTask(id: card.id, startAt: morning)
    }
    if ok { model.showToast("Moved to tomorrow") }
  }

  // MARK: - The running block

  /// Play on a card. Unconditional, as on the Mac: pressing play is an answer
  /// to whether the task is available. With a block already running, the
  /// task joins its queue instead.
  func start(_ card: DayCard, model: WorkspaceModel) {
    if card.isRunning {
      requestCompletion(completeTask: true, model: model)
      return
    }
    if let session = day.session, session.phase == .running {
      if model.perform({ try $0.addToFocusQueue(sessionId: session.id, taskId: card.id) }) {
        model.showToast("Queued after the running task")
      }
      return
    }
    model.perform { store in
      let now = Date.now
      let candidate = try store.nextUpCandidates(now: now).first { $0.id == card.id }
      let planned = candidate.map {
        TaskAvailabilityPolicy.suggestedSeconds(for: $0, context: FocusContext(), now: now)
      } ?? card.estimateSeconds ?? 25 * 60
      _ = try store.startFocusSession(
        taskId: card.id, plannedSeconds: planned, context: FocusContext(), overrideAvailability: true, now: now)
    }
  }

  func togglePause(model: WorkspaceModel) {
    guard let session = day.session else { return }
    model.perform { store in
      if session.pausedAt == nil {
        try store.pauseFocusSession(id: session.id)
      } else {
        try store.resumeFocusSession(id: session.id)
      }
    }
  }

  /// Stops the clock and asks how the block went. Done closes the task;
  /// Log and Skip credit the time and leave it open — Skip because logging
  /// the block is what moves the queue on.
  func requestCompletion(completeTask: Bool, model: WorkspaceModel, now: Date = .now) {
    guard pendingCompletion == nil, let session = day.session, let taskID = session.activeTaskId,
      let card = day.cards.first(where: { $0.id == taskID }) ?? model.task(taskID).map({ task in
        DayCard(
          id: task.id, title: task.title, listName: nil, listColorHex: nil, reason: nil,
          estimateSeconds: task.estimateSeconds, loggedSeconds: 0, dueAt: task.dueAt, isList: task.isList,
          dailyID: nil, isDailyDoneToday: false, isRunning: true)
      })
    else { return }
    pendingCompletion = PendingBlockCompletion(
      sessionID: session.id, taskID: taskID, title: card.title, seconds: session.elapsedSeconds(now: now),
      completeTask: completeTask, blockID: session.activeBlockId, wasPaused: session.pausedAt != nil)
    if session.pausedAt == nil {
      model.perform { try $0.pauseFocusSession(id: session.id, now: now) }
    }
  }

  /// Credits the time the block took and scores it.
  func confirmCompletion(multiplier: Double?, model: WorkspaceModel) {
    guard let pending = pendingCompletion else { return }
    pendingCompletion = nil
    var outcome: WorkspaceStore.FocusCompletionOutcome?
    model.perform { store in
      outcome = try store.completeActiveFocusTask(
        sessionId: pending.sessionID, elapsedSeconds: pending.seconds, qualityMultiplier: multiplier,
        completeTask: pending.completeTask, expectedBlockId: pending.blockID, context: FocusContext()
      ).outcome
    }
    switch outcome {
    case .taskCompleted: model.noteCompletion()
    case .contributionLogged(let seconds): model.noteCompletion(); model.showToast("Logged \(Format.duration(seconds)) to the daily")
    case .progressLogged(let seconds): model.showToast("Logged \(Format.duration(seconds))")
    case nil: break
    }
  }

  /// Drops the question and resumes a block that was running.
  func cancelCompletion(model: WorkspaceModel) {
    guard let pending = pendingCompletion else { return }
    pendingCompletion = nil
    if !pending.wasPaused {
      model.perform { try $0.resumeFocusSession(id: pending.sessionID) }
    }
  }
}
