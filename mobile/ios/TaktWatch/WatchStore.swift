import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's half: the last snapshot the iPhone sent, and the way taps get
/// back to it.
///
/// A tap shows its result straight away — the row crossed out, the clock
/// started — and is sent to the phone, which does the real work and answers
/// with the day as it then stands. While the phone is out of reach the tap is
/// queued with `transferUserInfo`, which the system delivers when it can; the
/// screen keeps the tap's result meanwhile, and says how many are waiting.
@MainActor
@Observable
final class WatchStore: NSObject {
  static let shared = WatchStore()

  private(set) var snapshot: WatchSnapshot
  private(set) var isReachable = false
  /// Taps queued for the phone and not yet delivered.
  private(set) var queuedCount = 0
  /// Rows just ticked off: drawn crossed out for a moment, then gone.
  private(set) var finishing: Set<String> = []
  /// Whether anything has ever come from the phone.
  var hasSnapshot: Bool { snapshot.generatedAt != .distantPast }

  /// Rows ticked off here that the phone may not have heard about yet, kept
  /// out of any snapshot made before it did.
  @ObservationIgnored private var ticked: [String: Date] = [:]
  /// When the last tap changed what the screen shows. A snapshot the phone
  /// made before that does not know about the tap, and would undo it on
  /// screen, so it is set aside.
  @ObservationIgnored private var lastLocalChange = Date.distantPast
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "WatchStore")

  /// How long a ticked row stays crossed out before it goes.
  static let finishingDelay: Duration = .milliseconds(900)

  override init() {
    snapshot = WatchStorage.load() ?? .empty
    super.init()
  }

  private var connection: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

  func activate() {
    guard let session = connection else { return }
    session.delegate = self
    session.activate()
  }

  // MARK: - What the screen reads

  var openTasks: [WatchSnapshot.Task] { snapshot.openTasks }
  var session: WatchSnapshot.Session? { snapshot.session }

  // MARK: - Taps

  /// Ticks a row off: a daily logs today, anything else is completed; the
  /// running task's block ends with it.
  func tickOff(_ task: WatchSnapshot.Task) {
    guard !finishing.contains(task.id) else { return }
    WKInterfaceDevice.current().play(.success)
    finishing.insert(task.id)
    ticked[task.id] = .now
    send(WatchAction(kind: task.isDaily ? .logDaily : .complete, taskId: task.id))
    Task { @MainActor in
      try? await Task.sleep(for: Self.finishingDelay)
      self.finishing.remove(task.id)
      self.change { snapshot in
        snapshot.tasks.removeAll { $0.id == task.id }
        if snapshot.session?.taskId == task.id { snapshot.session = nil }
      }
    }
  }

  func start(_ task: WatchSnapshot.Task, now: Date = .now) {
    WKInterfaceDevice.current().play(.start)
    send(WatchAction(kind: .start, taskId: task.id))
    // With a block already running the phone queues the task behind it, so
    // there is nothing to show yet.
    guard snapshot.session == nil else { return }
    change { snapshot in
      snapshot.session = WatchSnapshot.Session(
        taskId: task.id, title: task.title, phase: .running, startedAt: now, accumulatedSeconds: 0,
        plannedSeconds: task.estimateSeconds ?? 25 * 60)
      snapshot.tasks = snapshot.tasks.map { row in
        WatchSnapshot.Task(
          id: row.id, title: row.title, detail: row.detail, isDaily: row.isDaily, dailyDone: row.dailyDone,
          isRunning: row.id == task.id, estimateSeconds: row.estimateSeconds)
      }
      if let index = snapshot.tasks.firstIndex(where: { $0.id == task.id }) {
        snapshot.tasks.insert(snapshot.tasks.remove(at: index), at: 0)
      }
    }
  }

  func togglePause(now: Date = .now) {
    guard let session = snapshot.session else { return }
    WKInterfaceDevice.current().play(.click)
    send(WatchAction(kind: session.isPaused ? .resume : .pause, taskId: session.taskId))
    change { $0.session = session.isPaused ? session.resumed(at: now) : session.paused(at: now) }
  }

  /// Done: the running task is completed and its block ends.
  func done() {
    guard let session = snapshot.session else { return }
    WKInterfaceDevice.current().play(.success)
    ticked[session.taskId] = .now
    send(WatchAction(kind: .done, taskId: session.taskId))
    change { snapshot in
      snapshot.session = nil
      snapshot.tasks.removeAll { $0.id == session.taskId }
    }
  }

  /// Stop: the block's time is logged and the task stays on the day.
  func stop() {
    guard let session = snapshot.session else { return }
    WKInterfaceDevice.current().play(.stop)
    send(WatchAction(kind: .stop, taskId: session.taskId))
    change { snapshot in
      snapshot.session = nil
      snapshot.tasks = snapshot.tasks.map { row in
        WatchSnapshot.Task(
          id: row.id, title: row.title, detail: row.detail, isDaily: row.isDaily, dailyDone: row.dailyDone,
          isRunning: false, estimateSeconds: row.estimateSeconds)
      }
    }
  }

  /// Asks the phone for the day as it stands, when it can be reached.
  func refresh() {
    guard let session = connection, session.activationState == .activated, session.isReachable else { return }
    send(WatchAction(kind: .refresh))
  }

  // MARK: - Plumbing

  /// Changes what the screen shows ahead of the phone's answer.
  private func change(_ edit: (inout WatchSnapshot) -> Void) {
    var next = snapshot
    edit(&next)
    lastLocalChange = .now
    land(next)
  }

  private func send(_ action: WatchAction) {
    guard let session = connection, session.activationState == .activated else {
      logger.notice("Watch session not active; \(action.kind.rawValue, privacy: .public) dropped")
      return
    }
    let message = action.message
    guard session.isReachable else {
      queue(message, on: session)
      return
    }
    session.sendMessage(
      message,
      replyHandler: { reply in
        Task { @MainActor in self.receive(reply) }
      },
      errorHandler: { _ in
        // Out of reach after all: queued, and applied once on arrival — the
        // phone drops a second delivery of the same tap.
        Task { @MainActor in self.queue(message, on: session) }
      })
  }

  private func queue(_ message: [String: Any], on session: WCSession) {
    if WatchAction(message: message)?.kind == .refresh { return }
    session.transferUserInfo(message)
    queuedCount = session.outstandingUserInfoTransfers.count
  }

  /// A snapshot from the phone: an application context or a reply.
  private func receive(_ context: [String: Any]) {
    guard let incoming = WatchSnapshot(context: context) else { return }
    // Older than what is shown, or made before the last tap was shown and
    // so not knowing about it.
    if incoming.generatedAt < snapshot.generatedAt || incoming.generatedAt < lastLocalChange.addingTimeInterval(-1) {
      return
    }
    var next = incoming
    // A tick still on its way keeps its row off the screen until the phone
    // has seen it, or for a day at most.
    ticked = ticked.filter { $0.value > incoming.generatedAt && $0.value.timeIntervalSinceNow > -86_400 }
    next.tasks.removeAll { ticked[$0.id] != nil && !finishing.contains($0.id) }
    land(next)
  }

  private func land(_ next: WatchSnapshot) {
    let changed = next != snapshot
    snapshot = next
    guard changed else { return }
    do {
      try WatchStorage.save(next)
    } catch {
      logger.error("Watch snapshot not saved: \(error.localizedDescription, privacy: .public)")
    }
    WidgetCenter.shared.reloadTimelines(ofKind: WatchStorage.widgetKind)
  }

  private func updateReachability(_ session: WCSession) {
    isReachable = session.isReachable
    queuedCount = session.outstandingUserInfoTransfers.count
  }
}

// MARK: - WCSessionDelegate

extension WatchStore: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
  ) {
    let context = session.receivedApplicationContext
    Task { @MainActor in
      if let error { self.logger.error("Watch session: \(error.localizedDescription, privacy: .public)") }
      self.updateReachability(session)
      if !context.isEmpty { self.receive(context) }
      self.refresh()
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { @MainActor in self.receive(applicationContext) }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      self.updateReachability(session)
      self.refresh()
    }
  }

  nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
    Task { @MainActor in self.updateReachability(session) }
  }
}
