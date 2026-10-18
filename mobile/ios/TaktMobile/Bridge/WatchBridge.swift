import Foundation
import OSLog
import TaktCore
import TaktWorkspace
import WatchConnectivity

/// The iPhone's half of the Apple Watch app.
///
/// Out: hangs off `WorkspaceModel.changeObservers`, as the widget bridge
/// does, so it hears every local write and every external one the model
/// notices; reads the day the way Today reads it and hands the watch the
/// result as its application context. Only a change in content is sent, or
/// a snapshot gone stale, so the watch can say how old what it shows is.
///
/// In: the watch's taps arrive as `WatchAction`s — a message while it can
/// reach the phone, a queued user-info transfer otherwise — and are applied
/// through the same model calls the iPhone's own Today and Focus make, so
/// each lands as an ordinary undoable step.
@MainActor
final class WatchBridge: NSObject {
  static let shared = WatchBridge()

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "WatchBridge")
  private weak var model: WorkspaceModel?
  private var pending: Task<Void, Never>?
  private var lastSent: WatchSnapshot?
  /// Actions already applied, so one delivered twice — a message whose reply
  /// was lost, then queued again — lands once.
  private var applied: [String] = []

  static let debounce: Duration = .milliseconds(300)
  /// Unchanged content is sent again after this long, so the watch's "updated
  /// … ago" reflects the phone having looked rather than the day changing.
  static let resendInterval: TimeInterval = 15 * 60

  private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

  func install(on model: WorkspaceModel) {
    guard let session else { return }
    self.model = model
    model.changeObservers.append { [weak self] _ in self?.schedule() }
    session.delegate = self
    session.activate()
  }

  // MARK: - Out

  func schedule() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled, let self, let snapshot = await self.read() else { return }
      self.publish(snapshot)
    }
  }

  /// The day as the watch shows it, read off the main actor.
  private func read() async -> WatchSnapshot? {
    guard let model else { return nil }
    let store = model.store
    let workspaceID = model.workspace.id
    let lists = model.structure.lists + model.structure.archivedLists
    return await Task.detached(priority: .utility) {
      try? WatchSnapshotBuilder.load(store: store, workspaceID: workspaceID, lists: lists)
    }.value
  }

  private func publish(_ snapshot: WatchSnapshot, force: Bool = false) {
    guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
    else { return }
    if !force, let lastSent, lastSent.hasSameContent(as: snapshot),
      snapshot.generatedAt.timeIntervalSince(lastSent.generatedAt) < Self.resendInterval
    {
      return
    }
    do {
      try session.updateApplicationContext(snapshot.context())
      lastSent = snapshot
    } catch {
      logger.error("Watch context not sent: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - In

  /// Applies what the watch asked for, then answers with the day as it now
  /// stands.
  func receive(_ message: [String: Any], model: WorkspaceModel? = nil, reply: (([String: Any]) -> Void)?) async {
    guard let action = WatchAction(message: message) else {
      logger.notice("Unreadable watch message dropped")
      reply?([:])
      return
    }
    if let model = model ?? self.model, !applied.contains(action.id) {
      applied.append(action.id)
      if applied.count > 200 { applied.removeFirst(applied.count - 200) }
      if action.isCurrent(at: .now) {
        await apply(action, model: model)
      } else {
        logger.notice("Stale watch action dropped: \(action.kind.rawValue, privacy: .public)")
      }
    }
    guard let snapshot = await read() else {
      reply?([:])
      return
    }
    reply?((try? snapshot.context()) ?? [:])
    publish(snapshot, force: action.kind == .refresh)
  }

  /// One watch action, through the calls the iPhone's own screens make.
  func apply(_ action: WatchAction, model: WorkspaceModel) async {
    let today = TodayModel()
    await today.load(model)
    let session = today.day.session
    switch action.kind {
    case .refresh:
      break
    case .complete:
      guard let taskID = action.taskId else { return }
      if session?.activeTaskId == taskID {
        completeRunning(today: today, model: model)
      } else if (try? model.store.daily(forTaskId: taskID)) != nil {
        // A daily is never completed from a tick: today is logged instead.
        logDaily(taskID, on: action.issuedAt, model: model)
      } else if model.task(taskID)?.status == .open {
        // Today's tick without the celebration, which nobody is looking at.
        model.toggleComplete(taskID)
      }
    case .logDaily:
      guard let taskID = action.taskId else { return }
      logDaily(taskID, on: action.issuedAt, model: model)
    case .start:
      guard let taskID = action.taskId, session?.activeTaskId != taskID else { return }
      if let card = today.day.cards.first(where: { $0.id == taskID }) {
        today.start(card, model: model)
      } else if model.task(taskID)?.status == .open {
        // A daily the day did not hold: started as Focus starts a rung.
        let planned = today.day.dailies.first { $0.taskID == taskID }?.targetSeconds
          ?? model.task(taskID)?.estimateSeconds ?? 25 * 60
        model.perform { store in
          _ = try store.startFocusSession(
            taskId: taskID, plannedSeconds: planned, context: FocusContext(), overrideAvailability: true)
        }
      }
    case .pause:
      guard session?.pausedAt == nil, model.pendingBlock == nil else { return }
      today.togglePause(model: model)
    case .resume:
      guard let session, session.pausedAt != nil else { return }
      if model.pendingBlock != nil {
        // The phone is asking how the block went; resuming is answering
        // "not finished yet", which is what Cancel on that prompt does.
        model.cancelBlockCompletion()
        if (try? model.store.activeFocusSession())?.pausedAt == nil { return }
      }
      today.togglePause(model: model)
    case .stop:
      today.endSession(model: model)
    case .done:
      completeRunning(today: today, model: model)
    }
  }

  /// Done on the running block: the task is completed and the block's time
  /// credited without a score, through the same prompt-and-confirm funnel
  /// every surface that ends a block uses. A question already up on the
  /// phone about this block is answered by it.
  private func completeRunning(today: TodayModel, model: WorkspaceModel, now: Date = .now) {
    guard let session = today.day.session, let taskID = session.activeTaskId else { return }
    let title = today.day.cards.first { $0.id == taskID }?.title ?? model.task(taskID)?.title ?? ""
    let asked = model.pendingBlock
    model.pendingBlock = PendingBlockCompletion(
      sessionID: asked?.sessionID ?? session.id, taskID: taskID, title: title,
      seconds: asked?.seconds ?? session.elapsedSeconds(now: now), completeTask: true,
      blockID: asked?.blockID ?? session.activeBlockId, wasPaused: asked?.wasPaused ?? (session.pausedAt != nil),
      context: asked?.context ?? FocusContext())
    model.confirmBlockCompletion(multiplier: nil)
  }

  /// A daily's tick, as Today's: logged against the day it was tapped, and
  /// only if that day is still owed.
  private func logDaily(_ taskID: String, on day: Date, model: WorkspaceModel) {
    guard let daily = try? model.store.daily(forTaskId: taskID) else { return }
    let owed = (try? model.store.dailies(on: day))?.first { $0.daily.id == daily.id }.map { !$0.isDoneToday } ?? true
    guard owed else { return }
    if model.perform({ _ = try $0.logContribution(dailyId: daily.id, now: day) }) { model.noteCompletion() }
  }
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
  ) {
    Task { @MainActor in
      if let error { self.logger.error("Watch session: \(error.localizedDescription, privacy: .public)") }
      self.schedule()
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  /// Switching watches: activate again for the new one.
  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in
      // A newly installed watch app has no context yet.
      self.lastSent = nil
      self.schedule()
    }
  }

  nonisolated func session(
    _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
  ) {
    Task { @MainActor in await self.receive(message, reply: replyHandler) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    Task { @MainActor in await self.receive(message, reply: nil) }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    Task { @MainActor in await self.receive(userInfo, reply: nil) }
  }
}
