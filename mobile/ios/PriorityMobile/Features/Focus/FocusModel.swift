import Foundation
import Observation
import PriorityCore
import PriorityWorkspace

/// When a deferred task comes back. The Mac's `WorkspaceDeferral`.
enum FocusDeferral: String, CaseIterable, Identifiable {
  case anHour, thisAfternoon, tomorrow, nextWeek

  var id: String { rawValue }

  var title: String {
    switch self {
    case .anHour: "In an hour"
    case .thisAfternoon: "This afternoon"
    case .tomorrow: "Tomorrow morning"
    case .nextWeek: "Next week"
    }
  }

  func date(from now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .anHour:
      return now.addingTimeInterval(3_600)
    case .thisAfternoon:
      let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
      return afternoon > now ? afternoon : now.addingTimeInterval(3_600)
    case .tomorrow:
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    case .nextWeek:
      let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week) ?? week
    }
  }
}

/// Everything the focus screen draws, read in one go off the main actor.
struct FocusSnapshot: Sendable {
  var ladder: [ScoredNextUp] = []
  var blocked: [BlockedFocusTask] = []
  var conditions: [TaskCondition] = []
  var hasManualOrder = false
  var session: FocusSession?
  var activeTask: WorkspaceTask?
  var queue: [FocusQueueTask] = []
  var points: FocusPointsSummary = .zero
  var dailyTaskIDs: Set<String> = []
  var nextEvaluationAt: Date?

  static func load(store: WorkspaceStore, workspaceID: String, context: FocusContext, now: Date = .now) throws -> FocusSnapshot {
    let session = try store.activeFocusSession()
    let next = try store.nextUpSnapshot(workspaceId: workspaceID, context: context, runningID: session?.activeTaskId, now: now)
    var snapshot = FocusSnapshot()
    // The running task is the block, not a rung to choose again.
    snapshot.ladder = next.ranking.ranked.filter { $0.id != session?.activeTaskId }
    snapshot.blocked = next.ranking.blocked
    snapshot.conditions = next.conditions
    snapshot.hasManualOrder = next.hasManualFocusOrder
    snapshot.nextEvaluationAt = next.ranking.nextEvaluationAt
    snapshot.session = session
    if let session {
      snapshot.activeTask = try session.activeTaskId.flatMap { try store.task(id: $0) }
      snapshot.queue = try store.focusQueue(for: session.id)
    }
    snapshot.points = try store.focusPointsSummary(now: now)
    snapshot.dailyTaskIDs = Set(try store.dailies(on: now).filter { !$0.isDoneToday }.map(\.task.id))
    return snapshot
  }
}

/// A start the ranking would not have chosen, held for the user to confirm.
struct FocusStartOverride: Identifiable, Equatable {
  let taskID: String
  let plannedSeconds: Int
  let explanation: String
  var id: String { taskID }
}

/// The focus screen's state: the context you are in, the ladder ranked for
/// it, the task staged, and the running block. The Mac's
/// `WorkspaceViewModel+Focus/+Dailies/+Conditions`, for one screen.
@MainActor
@Observable
final class FocusModel {
  let model: WorkspaceModel
  private(set) var snapshot = FocusSnapshot()
  private(set) var isLoaded = false

  // MARK: Context

  var conditionIDs: Set<String> {
    didSet {
      guard conditionIDs != oldValue else { return }
      AppGroup.defaults.set(Array(conditionIDs).sorted(), forKey: contextKey)
      contextVersion &+= 1
    }
  }
  /// The end of the time you have, or nil for no limit.
  var availableUntil: Date? { didSet { if availableUntil != oldValue { contextVersion &+= 1 } } }
  /// When the conditions you said were true stop being trusted — "at the
  /// office until 5". Past it, the context is set aside and the last one is
  /// offered back rather than assumed. The Mac's `contextExpiresAt`.
  var contextExpiresAt: Date? { didSet { if contextExpiresAt != oldValue { contextVersion &+= 1 } } }
  /// The conditions an expired context held, offered back with "Use again".
  var suggestedContextIDs: Set<String> = []
  var mode: FocusTimeMode = .progress { didSet { if mode != oldValue { contextVersion &+= 1 } } }
  /// Moves when the context does, so the ladder is ranked again.
  private(set) var contextVersion = 0

  /// The context the ranking sees. The time you have runs to whichever
  /// comes first, your stated end or the context's expiry: a context that
  /// lapses mid-block should not be trusted past it.
  var context: FocusContext {
    let ends = [availableUntil, contextExpiresAt].compactMap { $0 }.min()
    return FocusContext(conditionIDs: conditionIDs, endsAt: ends, mode: mode)
  }

  // MARK: Ladder

  private(set) var stagedTaskID: String?
  var estimateMinutes: Double = 25
  var startOverride: FocusStartOverride?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var expiryPromptedBlockID: String?
  @ObservationIgnored private var lastCheckpointAt = Date.distantPast
  /// When the ranking next changes on its own — a start time arriving, a
  /// window closing — so the ladder is ranked again then without a write.
  @ObservationIgnored private(set) var nextEvaluationAt: Date?
  /// The wall clock and uptime at the last tick: a gap between how far each
  /// moved is the device clock being changed under a running block.
  @ObservationIgnored private var lastClockAt = Date.now
  @ObservationIgnored private var lastUptime = ProcessInfo.processInfo.systemUptime
  @ObservationIgnored private var lastTimeZone = TimeZone.current.identifier

  private var contextKey: String { "focus-context-\(model.workspace.id)" }

  init(model: WorkspaceModel) {
    self.model = model
    conditionIDs = Set(AppGroup.defaults.stringArray(forKey: "focus-context-\(model.workspace.id)") ?? [])
  }

  var lastAward: FocusAward? { model.lastBlockResult?.award }
  var lastOutcome: WorkspaceStore.FocusCompletionOutcome? { model.lastBlockResult?.outcome }
  var pendingCompletion: PendingBlockCompletion? { model.pendingBlock }

  var ladder: [ScoredNextUp] { snapshot.ladder }
  var session: FocusSession? { snapshot.session }
  var activeTask: WorkspaceTask? { snapshot.activeTask }
  var isRunning: Bool { snapshot.session?.activeTaskId != nil }

  var stagedRung: ScoredNextUp? {
    guard let stagedTaskID else { return nil }
    return ladder.first { $0.id == stagedTaskID }
  }

  /// The title of the staged task, whether or not it is on the ladder — a
  /// task asked for from a context menu may be one the ranking ruled out.
  var stagedTitle: String? {
    guard let stagedTaskID else { return nil }
    return stagedRung?.candidate.title ?? model.task(stagedTaskID)?.title
  }

  // MARK: - Loading

  /// Ranks off the main actor and lands the result if nothing newer was asked.
  func load() async {
    generation &+= 1
    let mine = generation
    let store = model.store
    let workspaceID = model.workspace.id
    let context = context
    let result = await Task.detached(priority: .userInitiated) {
      try? FocusSnapshot.load(store: store, workspaceID: workspaceID, context: context)
    }.value
    guard mine == generation, let result else { return }
    apply(result)
  }

  /// Ranks on the spot. Tests, and callers that read the ladder next line.
  func loadNow() {
    generation &+= 1
    if let result = try? FocusSnapshot.load(store: model.store, workspaceID: model.workspace.id, context: context) {
      apply(result)
    }
  }

  private func apply(_ result: FocusSnapshot) {
    snapshot = result
    nextEvaluationAt = result.nextEvaluationAt
    isLoaded = true
    if let stagedTaskID, result.session?.activeTaskId == stagedTaskID { self.stagedTaskID = nil }
  }

  // MARK: - Context

  func toggleCondition(_ condition: TaskCondition) {
    suggestedContextIDs = []
    if conditionIDs.contains(condition.id) {
      conditionIDs.remove(condition.id)
    } else {
      var next = conditionIDs
      // One place at a time: choosing a location replaces the last one.
      if condition.isLocation { next.subtract(snapshot.conditions.filter(\.isLocation).map(\.id)) }
      next.insert(condition.id)
      conditionIDs = next
    }
  }

  func setAvailable(minutes: Int?, now: Date = .now) {
    availableUntil = minutes.map { now.addingTimeInterval(Double($0 * 60)) }
  }

  /// Turns the context's expiry on (an hour from now) or off.
  func setContextExpires(_ expires: Bool, now: Date = .now) {
    contextExpiresAt = expires ? now.addingTimeInterval(3_600) : nil
  }

  /// The context has lapsed: its conditions are set aside, and offered back
  /// with "Use again" rather than assumed still true. The Mac does the same
  /// in `monitorFocus`.
  func expireContextIfDue(now: Date = .now) {
    guard let expires = contextExpiresAt, expires <= now else { return }
    if !conditionIDs.isEmpty { suggestedContextIDs = conditionIDs }
    contextExpiresAt = nil
    conditionIDs = []
    model.showToast("Your context expired")
  }

  /// Puts back the conditions an expired context held.
  func confirmSuggestedContext() {
    conditionIDs = suggestedContextIDs
    suggestedContextIDs = []
  }

  func dismissSuggestedContext() {
    suggestedContextIDs = []
  }

  func createCondition(named name: String, isLocation: Bool) {
    model.createCondition(named: name, isLocation: isLocation)
  }

  var visibleConditions: [TaskCondition] {
    snapshot.conditions.filter { !$0.isArchived || conditionIDs.contains($0.id) }
  }

  func unavailableDescription(_ reason: TaskUnavailableReason) -> String {
    switch reason {
    case .startsLater(let date): "Starts \(date.formatted(date: .abbreviated, time: .shortened))"
    case .missingConditions(let groups): "Needs " + groups.map { group in
      group.map { id in snapshot.conditions.first(where: { $0.id == id })?.name ?? "Missing condition" }
        .joined(separator: " or ")
    }.joined(separator: " and ")
    case .insufficientTime(let seconds): "Needs at least \(Int(ceil(Double(seconds) / 60))) minutes"
    case .needsEstimate: "Needs a remaining estimate to check it fits"
    case .expiredWindow: "Your available time has run out"
    case .dailyNotScheduled: "This daily isn't scheduled today"
    case .dailyAlreadyMet: "Today's daily commitment is already met"
    }
  }

  /// The ranking's reason, with the conditions named when that is the reason.
  func explanation(for rung: ScoredNextUp) -> String {
    guard rung.reason == .condition else { return rung.explanation }
    let names = rung.candidate.requirementGroups.map { group in
      group.filter { conditionIDs.contains($0) }
        .map { id in snapshot.conditions.first(where: { $0.id == id })?.name ?? "Missing condition" }
        .joined(separator: " or ")
    }.joined(separator: " + ")
    return names + " available now"
  }

  // MARK: - The ladder

  /// Commits to a task: it becomes the thing about to be done, and the
  /// estimate is seeded from what it knows about itself.
  func stage(_ taskID: String) {
    stagedTaskID = taskID
    let seconds = ladder.first { $0.id == taskID }.map {
      TaskAvailabilityPolicy.suggestedSeconds(for: $0.candidate, context: context, now: .now)
    } ?? model.task(taskID)?.estimateSeconds ?? 1_500
    estimateMinutes = max(1, (Double(seconds) / 60).rounded())
  }

  func unstage() { stagedTaskID = nil }

  /// Begins the staged task. A start the context rules out is held as an
  /// override for the user to confirm, as on the Mac.
  func beginStaged(override: Bool = false) {
    guard let taskID = stagedTaskID else { return }
    begin(taskID, plannedSeconds: Int((max(1, estimateMinutes) * 60).rounded()), override: override)
  }

  func begin(_ taskID: String, plannedSeconds: Int, override: Bool = false) {
    let now = Date.now
    let context = context
    let candidate = (try? model.store.nextUpCandidates(now: now))?.first { $0.id == taskID }
    var explanations = candidate.map {
      TaskAvailabilityPolicy.reasons(for: $0, context: context, now: now).map(unavailableDescription)
    } ?? ["This task isn't currently available for focus."]
    if let end = context.endsAt, Double(plannedSeconds) > end.timeIntervalSince(now) {
      explanations.append("The block is longer than the time you have.")
    }
    if let candidate, plannedSeconds < max(60, candidate.minimumBlockSeconds ?? 60)
      || (candidate.requiresSingleSitting && plannedSeconds < (candidate.remainingSeconds ?? Int.max)) {
      explanations.append("The block is shorter than this task needs.")
    }
    if !override, !explanations.isEmpty {
      startOverride = FocusStartOverride(
        taskID: taskID, plannedSeconds: plannedSeconds, explanation: explanations.joined(separator: "\n"))
      return
    }
    startOverride = nil
    let started = model.perform { store in
      _ = try store.startFocusSession(
        taskId: taskID, plannedSeconds: plannedSeconds, context: context, overrideAvailability: override)
    }
    if started {
      stagedTaskID = nil
      model.lastBlockResult = nil
      loadNow()
    }
  }

  func confirmOverride() {
    guard let pending = startOverride else { return }
    begin(pending.taskID, plannedSeconds: pending.plannedSeconds, override: true)
  }

  /// Ticks a task off without a session: a daily logs today's contribution,
  /// anything else is completed.
  func completeWithoutSession(_ taskID: String) {
    let isDaily = snapshot.dailyTaskIDs.contains(taskID)
    let done = model.perform { store in
      if isDaily, let daily = try store.daily(forTaskId: taskID) {
        _ = try store.logContribution(dailyId: daily.id)
      } else {
        try store.setStatus(.completed, for: taskID)
      }
    }
    if done {
      model.noteCompletion()
      if stagedTaskID == taskID { stagedTaskID = nil }
    }
  }

  func deferTask(_ taskID: String, _ deferral: FocusDeferral, now: Date = .now) {
    model.perform { try $0.scheduleTask(id: taskID, startAt: deferral.date(from: now)) }
    if stagedTaskID == taskID { stagedTaskID = nil }
    model.showToast("Deferred to \(deferral.title.lowercased())")
  }

  /// Moves a rung by hand. Only the task that moved is pinned; its
  /// neighbours stay with the ranking, so a nudge stays a nudge.
  func moveRung(_ taskID: String, by offset: Int) {
    guard let index = ladder.firstIndex(where: { $0.id == taskID }) else { return }
    let target = index + offset
    guard ladder.indices.contains(target) else { return }
    model.perform { try $0.pinTask(id: taskID, atIndex: target) }
  }

  func moveRungs(from source: IndexSet, to destination: Int) {
    guard let index = source.first, ladder.indices.contains(index) else { return }
    let target = destination > index ? destination - 1 : destination
    guard target != index else { return }
    model.perform { try $0.pinTask(id: ladder[index].id, atIndex: target) }
  }

  /// Gives the ladder back to the ranking.
  func resetOrder() {
    model.perform { try $0.clearFocusOrder() }
  }

  /// Stages a task someone asked for elsewhere — a context menu, a day card.
  func takeRequest() {
    guard let taskID = model.focusRequestTaskID else { return }
    model.focusRequestTaskID = nil
    guard !isRunning else {
      model.showToast("Finish the running block first")
      return
    }
    stage(taskID)
  }

  // MARK: - The running block

  func togglePause(now: Date = .now) {
    guard let session else { return }
    model.perform { store in
      if session.pausedAt == nil {
        try store.pauseFocusSession(id: session.id, now: now)
      } else {
        try store.resumeFocusSession(id: session.id, now: now)
      }
    }
    loadNow()
  }

  /// Stops the clock and asks how the block went, through the one prompt
  /// the root presents. `completeTask` false is "log and keep": the time is
  /// credited and the task stays open.
  func requestCompletion(completeTask: Bool = true, now: Date = .now) {
    guard let session, let task = activeTask else { return }
    model.requestBlockCompletion(
      session: session, title: task.title, completeTask: completeTask, context: context, now: now)
    loadNow()
  }

  /// Ends the session, logging the running block's time without a score.
  func finish(now: Date = .now) {
    guard let session else { return }
    let context = context
    model.perform { store in
      if session.activeTaskId != nil {
        _ = try store.completeActiveFocusTask(
          sessionId: session.id, elapsedSeconds: session.elapsedSeconds(now: now), completeTask: false,
          expectedBlockId: session.activeBlockId, context: context)
      }
      try store.finishFocusSession(id: session.id, now: now)
    }
    model.pendingBlock = nil
    loadNow()
  }

  /// Called each second while the screen is up. Lapses an expired context,
  /// rebases a running block's clock after the device clock jumps, ranks
  /// again when the ranking's next boundary passes or the time zone changes,
  /// checkpoints the clock every thirty seconds so a crash keeps the time,
  /// and asks how it went once the planned block is up. The Mac's
  /// `monitorFocus`.
  func tick(now: Date = .now, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    expireContextIfDue(now: now)
    let jumped = synchroniseClock(now: now, uptime: uptime)
    let zone = TimeZone.current.identifier
    let zoneChanged = zone != lastTimeZone
    lastTimeZone = zone
    if jumped || zoneChanged || (nextEvaluationAt.map { $0 <= now } ?? false) {
      nextEvaluationAt = nil
      contextVersion &+= 1
    }
    guard let session, session.pausedAt == nil, session.activeTaskId != nil else { return }
    if now.timeIntervalSince(lastCheckpointAt) >= 30 {
      lastCheckpointAt = now
      try? model.store.checkpointFocusSession(id: session.id, now: now)
    }
    if session.elapsedSeconds(now: now) >= session.workDurationSeconds,
      expiryPromptedBlockID != session.activeBlockId, pendingCompletion == nil {
      expiryPromptedBlockID = session.activeBlockId
      requestCompletion(completeTask: false, now: now)
    }
  }

  /// Notices the wall clock moving by more than the time that passed — the
  /// user changing the clock, a manual time-zone fix — and rebases the
  /// running block so it counts the time actually worked rather than the
  /// jump. Returns whether the clock jumped.
  @discardableResult
  func synchroniseClock(now: Date, uptime: TimeInterval) -> Bool {
    let wallDelta = now.timeIntervalSince(lastClockAt)
    let uptimeDelta = uptime - lastUptime
    let jumped = abs(wallDelta - uptimeDelta) > 3
    if let session, session.pausedAt == nil, session.activeTaskId != nil,
      let elapsed = FocusClockPolicy.adjustedElapsed(
        previousElapsed: session.elapsedSeconds(now: lastClockAt), wallDelta: wallDelta, uptimeDelta: uptimeDelta) {
      model.perform { try $0.rebaseFocusClock(id: session.id, elapsedSeconds: elapsed, now: now) }
      loadNow()
    }
    lastClockAt = now
    lastUptime = uptime
    return jumped
  }

  func dismissAward() {
    model.lastBlockResult = nil
  }
}
