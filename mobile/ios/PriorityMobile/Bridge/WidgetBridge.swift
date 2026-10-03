import ActivityKit
import Foundation
import OSLog
import PriorityWorkspace
import WidgetKit

/// Keeps the widgets and the focus Live Activity in step with the workspace.
///
/// Hangs off `WorkspaceModel.changeObservers`, so it hears every local write
/// and every external one the model notices. Changes are coalesced: a burst of
/// writes (a drag, a seed) produces one read, one file write and one timeline
/// reload.
@MainActor
final class WidgetBridge {
  static let shared = WidgetBridge()

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "WidgetBridge")
  private var pending: Task<Void, Never>?
  private var lastSnapshot: WidgetSnapshot?
  private var lastReload = Date.distantPast
  private let liveActivity = FocusLiveActivityController()

  /// How long a burst of changes is allowed to settle before reading.
  static let debounce: Duration = .milliseconds(400)
  /// WidgetKit budgets reloads; never ask more often than this.
  static let minimumReloadInterval: TimeInterval = 5

  func install(on model: WorkspaceModel) {
    lastSnapshot = WidgetSnapshot.load()
    model.changeObservers.append { [weak self] model in self?.schedule(model) }
    schedule(model)
  }

  func schedule(_ model: WorkspaceModel) {
    pending?.cancel()
    let store = model.store
    let workspaceID = model.workspace.id
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .utility) {
        (
          try? WidgetSnapshotBuilder.make(store: store, workspaceID: workspaceID),
          try? WidgetSnapshotBuilder.focusState(store: store)
        )
      }.value
      guard !Task.isCancelled, let self else { return }
      if let snapshot = result.0 { self.publish(snapshot) }
      await self.liveActivity.sync(result.1 ?? nil)
    }
  }

  private func publish(_ snapshot: WidgetSnapshot) {
    if let lastSnapshot, lastSnapshot.hasSameContent(as: snapshot) { return }
    do {
      try snapshot.write()
      lastSnapshot = snapshot
    } catch {
      logger.error("Widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    let now = Date()
    let wait = Self.minimumReloadInterval - now.timeIntervalSince(lastReload)
    if wait <= 0 {
      lastReload = now
      WidgetCenter.shared.reloadAllTimelines()
    } else {
      // Fold this into one later reload rather than dropping it.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(wait))
        guard let self, Date().timeIntervalSince(self.lastReload) >= Self.minimumReloadInterval else { return }
        self.lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
      }
    }
  }
}

/// Starts, updates and ends the one focus Live Activity.
///
/// Every call is safe when Live Activities are switched off or unsupported:
/// requesting fails quietly, and there is then nothing to update or end.
@MainActor
final class FocusLiveActivityController {
  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "LiveActivity")
  private var lastState: FocusActivityAttributes.ContentState?

  func sync(_ running: (sessionID: String, state: FocusActivityAttributes.ContentState)?) async {
    let activities = Activity<FocusActivityAttributes>.activities
    guard let running else {
      lastState = nil
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      return
    }
    // One activity per session: a stale one from an earlier block goes.
    for activity in activities where activity.attributes.sessionID != running.sessionID {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    if let current = activities.first(where: { $0.attributes.sessionID == running.sessionID }) {
      guard Self.differs(lastState ?? current.content.state, running.state) else { return }
      lastState = running.state
      await current.update(ActivityContent(state: running.state, staleDate: nil))
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      _ = try Activity.request(
        attributes: FocusActivityAttributes(sessionID: running.sessionID),
        content: ActivityContent(state: running.state, staleDate: nil), pushType: nil)
      lastState = running.state
    } catch {
      logger.notice("Live Activity not started: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Whether an update is worth sending. The timer runs on the device, so a
  /// state that only moved because time passed is not a change; a pause, a
  /// resume, a new task or a clock that was rebased is.
  nonisolated static func differs(_ old: FocusActivityAttributes.ContentState, _ new: FocusActivityAttributes.ContentState) -> Bool {
    if old.taskID != new.taskID || old.taskTitle != new.taskTitle || old.isPaused != new.isPaused
      || old.plannedSeconds != new.plannedSeconds
    {
      return true
    }
    if new.isPaused { return abs(old.elapsedSeconds - new.elapsedSeconds) > 1 }
    return abs(old.timerStart.timeIntervalSince(new.timerStart)) > 2
  }
}
