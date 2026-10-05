import Foundation
import TaktCore
import TaktWorkspace

/// A finished block waiting to be told how it went. The seconds are captured
/// the instant Done is pressed: the clock stops when the work stops, not when
/// the judgement arrives.
///
/// One type for every surface that can end a block — the Focus screen, a
/// running day card, the timer running out — so they share one prompt and one
/// write.
struct PendingBlockCompletion: Identifiable, Equatable {
  let sessionID: String
  let taskID: String
  let title: String
  let seconds: Int
  let completeTask: Bool
  let blockID: String?
  let wasPaused: Bool
  /// The context the block ran in, which the queue hands the next task off
  /// against.
  var context = FocusContext()

  var id: String { "\(sessionID)/\(taskID)/\(completeTask)" }
}

/// What the last scored block earned, for the surfaces that show it.
struct BlockCompletionResult: Equatable {
  let award: FocusAward?
  let outcome: WorkspaceStore.FocusCompletionOutcome
}

/// Ending a block, wherever it is ended from. The Mac's
/// `WorkspaceViewModel.requestFocusCompletion` / `confirmFocusCompletion` /
/// `cancelFocusCompletion`, held on the model so the question is asked once,
/// by `BlockQualityPrompt` at the root, whichever screen raised it.
@MainActor
extension WorkspaceModel {
  /// Stops the clock and asks how the block went. A running block is paused
  /// while the question is open; cancelling resumes it.
  func requestBlockCompletion(
    session: FocusSession, title: String, completeTask: Bool, context: FocusContext = FocusContext(), now: Date = .now
  ) {
    guard pendingBlock == nil, let taskID = session.activeTaskId else { return }
    pendingBlock = PendingBlockCompletion(
      sessionID: session.id, taskID: taskID, title: title, seconds: session.elapsedSeconds(now: now),
      completeTask: completeTask, blockID: session.activeBlockId, wasPaused: session.pausedAt != nil,
      context: context)
    if session.pausedAt == nil {
      perform { try $0.pauseFocusSession(id: session.id, now: now) }
    }
  }

  /// Credits the time the block took and scores it by `multiplier` — nil
  /// logs the minutes without a score.
  @discardableResult
  func confirmBlockCompletion(multiplier: Double?) -> BlockCompletionResult? {
    guard let pending = pendingBlock else { return nil }
    pendingBlock = nil
    let multiplier = multiplier.map(FocusPoints.clamped(multiplier:))
    var completion: WorkspaceStore.FocusCompletion?
    perform { store in
      completion = try store.completeActiveFocusTask(
        sessionId: pending.sessionID, elapsedSeconds: pending.seconds, qualityMultiplier: multiplier,
        completeTask: pending.completeTask, expectedBlockId: pending.blockID, context: pending.context)
    }
    guard let completion else { return nil }
    let result = BlockCompletionResult(award: completion.award, outcome: completion.outcome)
    lastBlockResult = result
    switch completion.outcome {
    case .taskCompleted:
      noteCompletion()
    case .contributionLogged(let seconds):
      noteCompletion()
      showToast("Logged \(Format.duration(seconds)) to the daily")
    case .progressLogged(let seconds):
      if seconds > 0 { showToast("Logged \(Format.duration(seconds))") }
    }
    return result
  }

  /// Drops the question and resumes a block that was running when asked.
  func cancelBlockCompletion() {
    guard let pending = pendingBlock else { return }
    pendingBlock = nil
    if !pending.wasPaused {
      perform { try $0.resumeFocusSession(id: pending.sessionID) }
    }
  }
}
