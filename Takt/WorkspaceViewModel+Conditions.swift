import AppKit
import Foundation
import TaktCore
import TaktWorkspace

struct FocusStartOverride: Identifiable {
  let task: WorkspaceTask
  let plannedSeconds: Int
  let explanation: String
  var id: String { task.id }
}

@MainActor
extension WorkspaceViewModel {
  var effectiveFocusContext: FocusContext {
    let end = [availableUntil, contextExpiresAt].compactMap { $0 }.min()
    return FocusContext(conditionIDs: focusContext.conditionIDs, endsAt: end, mode: focusContext.mode)
  }

  private var focusContextKey: String? { workspace.map { "focus-context-\($0.id)" } }

  /// Puts back the conditions that held when the app last quit, as the phones
  /// do. The ranking has to have run once first, so the conditions are known
  /// and one deleted since is not carried forward.
  func restoreFocusContext() {
    guard let key = focusContextKey else { return }
    let restored = FocusContextSelection.restoring(
      UserDefaults.standard.stringArray(forKey: key) ?? [], known: Set(focusConditions.map(\.id)))
    guard restored != focusContext.conditionIDs else { return }
    focusContext.conditionIDs = restored
    reloadNextUpNow()
  }

  func toggleFocusCondition(_ condition: TaskCondition) {
    focusContext.conditionIDs = FocusContextSelection.toggling(
      condition.id, isLocation: condition.isLocation, in: focusContext.conditionIDs,
      locationIDs: Set(focusConditions.filter(\.isLocation).map(\.id)))
    suggestedContextIDs = []
    focusContextChanged()
  }

  /// Nothing available beyond the laptop.
  func clearFocusConditions() {
    guard !focusContext.conditionIDs.isEmpty else { return }
    focusContext.conditionIDs = []
    suggestedContextIDs = []
    focusContextChanged()
  }

  func confirmSuggestedContext() {
    focusContext.conditionIDs = suggestedContextIDs
    suggestedContextIDs = []
    focusContextChanged()
  }

  /// Every change to the context goes through here: it is saved, so the next
  /// launch starts where this one left off, and the ladder is ranked again.
  func focusContextChanged() {
    allowsQueueResume = true
    saveCurrentContext()
    reloadNextUp()
  }

  private func saveCurrentContext() {
    guard let key = focusContextKey else { return }
    UserDefaults.standard.set(Array(focusContext.conditionIDs).sorted(), forKey: key)
  }

  /// What "Available now" offers, under category headings: only the
  /// conditions an open task requires, plus any that is on so it can be
  /// turned off. Empty when no open task needs a condition. The rule is the
  /// Rust core's, so the phones offer the same.
  var availableConditionSections: [TaskConditionSection] {
    TaskConditionSection.available(focusConditions, required: requiredConditionIDs, active: focusContext.conditionIDs)
  }

  /// The conditions you can say are true right now, in the order the tab
  /// shows them.
  var selectableFocusConditions: [TaskCondition] {
    availableConditionSections.flatMap(\.conditions)
  }

  /// Every condition under its heading, for managing them.
  var conditionSections: [TaskConditionSection] { TaskConditionSection.sections(focusConditions) }

  /// The categories a condition can be filed under: Location, then every
  /// other one in use.
  var conditionCategories: [String] { TaskConditionSection.categories(focusConditions) }

  /// The active conditions' names, or nil with none on.
  var focusContextSummary: String? {
    FocusContextSelection.summary(focusContext.conditionIDs, names: focusConditions.map { ($0.id, $0.name) })
  }

  /// - Returns: the new condition, or nil if it could not be made (the
  ///   error is in `errorMessage`).
  @discardableResult
  func createCondition(name: String, category: String?) -> TaskCondition? {
    guard let store, let workspace else { return nil }
    var created: TaskCondition?
    perform {
      created = try store.createCondition(workspaceId: workspace.id, name: name, category: category)
      reloadNextUpNow()
    }
    return created
  }

  func saveCondition(_ condition: TaskCondition, name: String, isArchived: Bool) {
    guard let store else { return }
    perform {
      try store.saveCondition(id: condition.id, name: name, isLocation: condition.isLocation, isArchived: isArchived)
      reloadNextUp(); taskEditor.refresh(store: store)
    }
  }

  /// Files a condition under a category, or none. Location makes it a place.
  func setConditionCategory(_ condition: TaskCondition, category: String?) {
    guard let store, TaskConditionSection.normalizedCategory(category) != condition.category else { return }
    perform {
      try store.setConditionCategory(id: condition.id, category: category)
      reloadNextUp(); taskEditor.refresh(store: store)
    }
  }

  /// The category finder, for a condition (saved as soon as one is chosen)
  /// or for the new-condition row.
  func presentConditionCategoryFinder(for condition: TaskCondition?) {
    presentOverlay(.conditionCategory(WorkspaceConditionCategoryRequest(conditionID: condition?.id)))
  }

  func applyPlanningToDescendants(of task: WorkspaceTask) {
    perform { try store?.applyPlanningToDescendants(of: task.id); reloadNextUp(); if let store { taskEditor.refresh(store: store) } }
  }

  func focusExplanation(_ scored: ScoredNextUp) -> String {
    guard scored.reason == .condition else { return scored.explanation }
    let requirements = scored.candidate.requirementGroups.map { group in
      group.filter { focusContext.conditionIDs.contains($0) }
        .map { id in focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }.joined(separator: " or ")
    }.joined(separator: " + ")
    return requirements + (contextExpiresAt.map { " available until \($0.formatted(date: .omitted, time: .shortened))" } ?? " available now")
  }

  func suggestedFocusSeconds(for id: String) -> Int {
    guard let task = focusLadder.first(where: { $0.id == id })?.candidate else { return 1500 }
    return TaskAvailabilityPolicy.suggestedSeconds(for: task, context: effectiveFocusContext, now: .now)
  }

  func unavailableDescription(_ reason: TaskUnavailableReason) -> String {
    switch reason {
    case .startsLater(let date): "Starts \(date.formatted(date: .abbreviated, time: .shortened))"
    case .missingConditions(let groups): "Needs " + groups.map { group in
      group.map { id in focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }.joined(separator: " or ")
    }.joined(separator: " and ")
    case .insufficientTime(let seconds): "Needs at least \(Int(ceil(Double(seconds) / 60))) minutes"
    case .needsEstimate: "Needs a positive remaining estimate to check finish fit"
    case .expiredWindow: "Available time window has ended"
    case .dailyNotScheduled: "Daily is not scheduled for today"
    case .dailyAlreadyMet: "Today’s daily commitment is already met"
    }
  }

  func pauseFocus() {
    synchroniseFocusClock(now: .now)
    guard let session = activeFocusSession else { return }
    perform(mirrors: false) { try store?.pauseFocusSession(id: session.id); reloadFocus() }
  }

  func toggleFocusPause() {
    synchroniseFocusClock(now: .now)
    guard let session = activeFocusSession else { return }
    perform(mirrors: false) {
      if session.pausedAt == nil { try store?.pauseFocusSession(id: session.id) } else { try store?.resumeFocusSession(id: session.id) }
      reloadFocus()
    }
  }

  @discardableResult
  func synchroniseFocusClock(now: Date) -> Bool {
    let uptime = ProcessInfo.processInfo.systemUptime
    let wallDelta = now.timeIntervalSince(lastFocusClockAt)
    let uptimeDelta = uptime - lastFocusUptime
    let clockChanged = abs(wallDelta - uptimeDelta) > 3
    if let session = activeFocusSession, session.pausedAt == nil,
      let elapsed = FocusClockPolicy.adjustedElapsed(previousElapsed: session.elapsedSeconds(now: lastFocusClockAt),
                                                     wallDelta: wallDelta, uptimeDelta: uptimeDelta) {
      perform(mirrors: false) { try store?.rebaseFocusClock(id: session.id, elapsedSeconds: elapsed, now: now); reloadFocus() }
    }
    lastFocusClockAt = now; lastFocusUptime = uptime
    return clockChanged
  }

  /// Starts the focus clock's housekeeping for the life of the model.
  ///
  /// This used to be the window's `.task`, with the sleep and activation
  /// notifications received by the same view. Starting a block closes the
  /// window on purpose, which cancelled the task the moment it was most
  /// needed: no 30-second checkpoint, so the block's time was lost at the next
  /// quit; no clock-jump rebase after a sleep; no context expiry; and the
  /// "planned length reached" prompt never came.
  func startFocusMonitor() {
    guard focusMonitorTask == nil, store != nil else { return }
    // Weak across the sleep, so the loop does not hold the model alive.
    focusMonitorTask = Task { @MainActor [weak self] in
      while !Task.isCancelled, self != nil {
        self?.tickFocusMonitor(now: .now)
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    focusMonitorObservers.append(workspaceCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.pauseFocus() }
    })
    focusMonitorObservers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadNextUp() }
    })
  }

  /// One pass of the focus clock's housekeeping: context expiry, the
  /// clock-jump rebase, the re-ranking the ladder asked for, the 30-second
  /// checkpoint, and the prompt when a block reaches its planned length.
  func tickFocusMonitor(now: Date) {
    if let expiry = contextExpiresAt, expiry <= now {
      // Set aside rather than forgotten: offered back with "Use again", as
      // on the phones.
      if !focusContext.conditionIDs.isEmpty { suggestedContextIDs = focusContext.conditionIDs }
      focusContext.conditionIDs = []; contextExpiresAt = nil; saveCurrentContext(); reloadNextUp()
    }
    let clockJump = synchroniseFocusClock(now: now)
    let zoneChanged = lastFocusTimeZone != TimeZone.current.identifier
    if clockJump || zoneChanged || (nextFocusEvaluationAt.map { $0 <= now } ?? false) { reloadNextUp() }
    lastFocusTimeZone = TimeZone.current.identifier
    guard let session = activeFocusSession, session.pausedAt == nil, session.activeTaskId != nil else { return }
    if now.timeIntervalSince(lastFocusCheckpointAt) >= 30 {
      perform(mirrors: false) { try store?.checkpointFocusSession(id: session.id, now: now); reloadFocus() }
      lastFocusCheckpointAt = now
    }
    if session.elapsedSeconds(now: now) >= session.workDurationSeconds,
      focusExpiryPromptedBlockID != session.activeBlockId {
      focusExpiryPromptedBlockID = session.activeBlockId
      // Asked where the block is being watched: the panel, once the window
      // has been put away, which is where a running block lives.
      let surface: FocusCompletionSurface = hasOrdinaryWindow?() == true ? .window : .panel
      requestFocusCompletion(now: now, completeTask: false, from: surface)
    }
  }
}
