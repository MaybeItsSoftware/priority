import Foundation
import Observation

@MainActor
@Observable final class FocusSessionManager {
  struct ActiveSession {
    let taskId: Int
    let durationSeconds: Int
    let baselineElapsed: TimeInterval
  }

  enum Phase: Equatable {
    case running
    case focusCompleted
    case breakRunning(endsAt: Date)
    case breakCompleted
  }

  static let minDurationMinutes = 1
  static let maxDurationMinutes = 240
  static let defaultDurationMinutes = 25

  static let minBreakDurationMinutes = 1
  static let maxBreakDurationMinutes = 60
  static let defaultBreakDurationMinutes = 5

  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus
  @ObservationIgnored private var breakTickerTask: Task<Void, Never>?

  /// Task ID for which the focus-start prompt is showing.
  var promptTaskId: Int?

  /// Active focus session (set during `.running` and `.focusCompleted`; cleared
  /// during break phases since the session itself has ended).
  var session: ActiveSession?

  /// Current phase. `nil` means no session is in progress.
  var phase: Phase?

  /// User-configurable focus duration in minutes. Persisted.
  var durationMinutes: Int {
    didSet {
      let clamped = min(Self.maxDurationMinutes, max(Self.minDurationMinutes, durationMinutes))
      if clamped != durationMinutes {
        durationMinutes = clamped
        return
      }
      preferencesStore.set(durationMinutes, for: .focusDurationMinutes)
    }
  }

  /// User-configurable break duration in minutes. Persisted.
  var breakDurationMinutes: Int {
    didSet {
      let clamped = min(
        Self.maxBreakDurationMinutes, max(Self.minBreakDurationMinutes, breakDurationMinutes)
      )
      if clamped != breakDurationMinutes {
        breakDurationMinutes = clamped
        return
      }
      preferencesStore.set(breakDurationMinutes, for: .focusBreakDurationMinutes)
    }
  }

  /// Last task that was focused on — used so "start another session" after a
  /// break can re-arm the same task. Cleared when the session ends fully.
  @ObservationIgnored private(set) var lastFocusedTaskId: Int?

  /// Invoked when a phase transition deserves the user's attention
  /// (focus complete, break complete). Wired up by `AppDelegate` to open
  /// the popover and play a sound.
  @ObservationIgnored var onAlert: (() -> Void)?

  /// Invoked when the focus block ends and the work timer should stop.
  /// Wired up by `AppCoordinator` so we don't directly depend on `TimerManager`.
  @ObservationIgnored var onFocusBlockEnded: (() -> Void)?

  /// Invoked with `(taskId, seconds)` when a focus block runs to completion, so
  /// the daily log can record it. Kept separate from `onFocusBlockEnded`, which
  /// is about stopping the timer — a cancelled session stops the timer but is
  /// not a session you did, and must not land in the log.
  @ObservationIgnored var onFocusSessionCompleted: ((Int, Int) -> Void)?

  init(
    preferencesStore: PreferencesStore,
    cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()
  ) {
    self.preferencesStore = preferencesStore
    self.cacheInvalidationBus = cacheInvalidationBus
    let storedDuration = preferencesStore.int(
      .focusDurationMinutes, default: Self.defaultDurationMinutes
    )
    self.durationMinutes = min(
      Self.maxDurationMinutes, max(Self.minDurationMinutes, storedDuration)
    )
    let storedBreak = preferencesStore.int(
      .focusBreakDurationMinutes, default: Self.defaultBreakDurationMinutes
    )
    self.breakDurationMinutes = min(
      Self.maxBreakDurationMinutes, max(Self.minBreakDurationMinutes, storedBreak)
    )
  }

  // MARK: - Prompt

  func presentPrompt(forTaskId taskId: Int) {
    cancelBreakTicker()
    session = nil
    phase = nil
    promptTaskId = taskId
    cacheInvalidationBus.invalidate()
  }

  func dismissPrompt() {
    promptTaskId = nil
    cacheInvalidationBus.invalidate()
  }

  // MARK: - Session lifecycle

  func startSession(baselineElapsed: TimeInterval) {
    guard let taskId = promptTaskId else { return }
    cancelBreakTicker()
    session = ActiveSession(
      taskId: taskId,
      durationSeconds: durationMinutes * 60,
      baselineElapsed: baselineElapsed
    )
    phase = .running
    lastFocusedTaskId = taskId
    promptTaskId = nil
    cacheInvalidationBus.invalidate()
  }

  /// Begin another focus session on the last focused task (if it still exists).
  /// `baselineElapsed` is the task's *current* elapsed time so the new session
  /// measures from now.
  func startAnotherSession(baselineElapsed: TimeInterval) {
    guard let taskId = lastFocusedTaskId else { return }
    cancelBreakTicker()
    session = ActiveSession(
      taskId: taskId,
      durationSeconds: durationMinutes * 60,
      baselineElapsed: baselineElapsed
    )
    phase = .running
    promptTaskId = nil
    cacheInvalidationBus.invalidate()
  }

  func cancelSession() {
    cancelBreakTicker()
    session = nil
    phase = nil
    promptTaskId = nil
    lastFocusedTaskId = nil
    cacheInvalidationBus.invalidate()
  }

  /// Called by `TimerManager.onTick` while the focus phase is active. Crosses
  /// the threshold into `.focusCompleted` exactly once.
  func handleTaskElapsed(_ elapsed: TimeInterval, forTaskId taskId: Int) {
    guard phase == .running, let session, session.taskId == taskId else { return }
    let elapsedInSession = elapsed - session.baselineElapsed
    if elapsedInSession >= TimeInterval(session.durationSeconds) {
      transitionToFocusCompleted()
    }
  }

  private func transitionToFocusCompleted() {
    phase = .focusCompleted
    if let session {
      onFocusSessionCompleted?(session.taskId, session.durationSeconds)
    }
    onFocusBlockEnded?()
    onAlert?()
    cacheInvalidationBus.invalidate()
  }

  // MARK: - Break lifecycle

  func startBreak() {
    guard phase == .focusCompleted else { return }
    let endsAt = Date().addingTimeInterval(TimeInterval(breakDurationMinutes * 60))
    phase = .breakRunning(endsAt: endsAt)
    session = nil
    startBreakTicker(endsAt: endsAt)
    cacheInvalidationBus.invalidate()
  }

  /// Cancel an active break and return to "ready for another session" state.
  func skipBreak() {
    cancelBreakTicker()
    phase = .breakCompleted
    cacheInvalidationBus.invalidate()
  }

  /// Remaining seconds in the current break phase, or 0 if not on a break.
  func breakRemainingSeconds(now: Date = Date()) -> TimeInterval {
    if case .breakRunning(let endsAt) = phase {
      return max(0, endsAt.timeIntervalSince(now))
    }
    return 0
  }

  private func startBreakTicker(endsAt: Date) {
    cancelBreakTicker()
    breakTickerTask = Task { [weak self] in
      while !Task.isCancelled {
        let remaining = endsAt.timeIntervalSinceNow
        if remaining <= 0 {
          await MainActor.run { self?.completeBreak() }
          return
        }
        let sleepFor = min(remaining, 1.0)
        let nanos = UInt64(max(sleepFor, 0.05) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
      }
    }
  }

  private func cancelBreakTicker() {
    breakTickerTask?.cancel()
    breakTickerTask = nil
  }

  private func completeBreak() {
    cancelBreakTicker()
    guard case .breakRunning = phase else { return }
    phase = .breakCompleted
    onAlert?()
    cacheInvalidationBus.invalidate()
  }

  // MARK: - Misc

  func adjustDuration(by delta: Int) {
    durationMinutes += delta
  }

  func adjustBreakDuration(by delta: Int) {
    breakDurationMinutes += delta
  }

  /// True while any non-idle phase is active (running, completed, or on break).
  var isActive: Bool { phase != nil }

  /// Drop prompt/session if their task no longer exists or has been completed.
  func clampForTasks<S: Sequence>(_ tasks: S) where S.Element == CheckvistTask {
    let openIds = Set(tasks.lazy.filter { $0.status == 0 }.map { $0.id })
    if let promptId = promptTaskId, !openIds.contains(promptId) {
      promptTaskId = nil
    }
    if let sessionId = session?.taskId, !openIds.contains(sessionId) {
      session = nil
      // If the focused task disappeared, end the session entirely.
      if phase == .running || phase == .focusCompleted {
        cancelSession()
      }
    }
    if let lastId = lastFocusedTaskId, !openIds.contains(lastId) {
      lastFocusedTaskId = nil
    }
  }
}
