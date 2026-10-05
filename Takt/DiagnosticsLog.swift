import Foundation
import Observation

/// A bounded, in-memory record of what has gone wrong this session.
///
/// The app is otherwise honest but forgetful about failure: `errorMessage` is
/// overwritten by the next thing that fails and cleared by the next fetch that
/// starts, `statusMessage` erases itself after three seconds, and integration
/// errors go into a closure that retains nothing. Three seconds after an AFFiNE
/// sync fails, the only surviving evidence is in `os_log` — which is no use to
/// someone being asked what happened.
///
/// Not persisted. This answers "what has this run of the app been doing", and a
/// log restored from disk would mix a fault you are chasing now with one from a
/// fortnight ago.
@MainActor
@Observable final class DiagnosticsLog {

  /// Enough to cover a session's worth of trouble without letting a failure
  /// that repeats on a timer grow without bound.
  static let capacity = 200

  struct Entry: Identifiable, Sendable {
    let id: Int
    let date: Date
    let category: String
    let message: String
    let isFailure: Bool
  }

  private(set) var entries: [Entry] = []
  private var nextID = 0

  var failureCount: Int { entries.count { $0.isFailure } }

  /// - Note: consecutive identical messages are collapsed into the most recent
  ///   one, because a sync retrying every thirty seconds against a dead network
  ///   would otherwise push everything that explains it off the end.
  func record(category: String, message: String, isFailure: Bool, at date: Date = Date()) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if let last = entries.last, last.message == trimmed, last.category == category {
      entries[entries.count - 1] = Entry(
        id: last.id, date: date, category: category, message: trimmed, isFailure: isFailure)
      return
    }

    entries.append(
      Entry(id: nextID, date: date, category: category, message: trimmed, isFailure: isFailure))
    nextID += 1
    if entries.count > Self.capacity {
      entries.removeFirst(entries.count - Self.capacity)
    }
  }

  func clear() {
    entries.removeAll()
  }
}
