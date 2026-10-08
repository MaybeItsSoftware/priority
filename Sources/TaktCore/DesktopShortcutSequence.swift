import Foundation

/// Checkvist-style two-letter commands: a key that could begin one is held
/// briefly, within one surface, to see whether the second letter follows.
///
/// A held key is never lost. It used to be: the first letter of every
/// sequence was swallowed and nothing replayed it, so `x` (complete), `l`
/// (open subtasks) and `h` (leave them) — each then the first letter of `xx`,
/// `ll` or `hc` — did nothing at all, while the reference sheet went on listing
/// them. Now a held key that does not become a sequence runs on its own: at
/// once when the next key turns out not to complete it, or when the hold
/// times out with no next key. The second half is a timer the caller owns,
/// which is why `expire(heldAt:)` exists and this type stays a value.
///
/// Which sequences exist is the caller's to say, per surface, from the
/// catalogue. That is what lets a key resolve immediately on a surface where
/// no sequence begins with it — `l` on the focus ladder waits for nothing.
public struct DesktopShortcutSequence {
  public enum Result: Equatable {
    /// Not part of a sequence: dispatch the key as it is.
    case pass
    /// Held, waiting for a second letter. The caller should arrange to call
    /// `expire(heldAt:)` after `timeout`.
    case pending
    /// Two keys made a sequence.
    case command(String)
    /// The held key was not the start of a sequence with this one: run the
    /// held key on its own, then dispatch this key as it is.
    case flush(String)
    /// As `flush`, except this key could itself begin a sequence, so it is now
    /// the one held.
    case flushAndHold(String)
  }

  /// Long enough to type two letters deliberately, short enough that a held
  /// single key does not feel ignored.
  public static let timeout: TimeInterval = 1.2

  public private(set) var prefix = ""
  private var heldAt: TimeInterval = 0

  public init() {}

  /// Drops a held key without running it. For when the keyboard moves
  /// somewhere else — a new region, a text field — and the key no longer
  /// means what it meant when it was pressed.
  public mutating func reset() { prefix = "" }

  /// Releases the held key, if any, for the caller to run on its own.
  public mutating func flush() -> String? {
    guard !prefix.isEmpty else { return nil }
    defer { reset() }
    return prefix
  }

  /// The timer's half of `flush()`. Only releases the hold that started at
  /// `time`: a timer armed for an earlier hold, since flushed by a key and
  /// replaced by a new one, must not cut the new one short.
  public mutating func expire(heldAt time: TimeInterval) -> String? {
    guard !prefix.isEmpty, heldAt == time else { return nil }
    return flush()
  }

  /// - Parameters:
  ///   - key: a single unmodified key, as the catalogue spells it.
  ///   - sequences: the two-letter keys live on the current surface.
  public mutating func advance(
    _ key: String,
    at time: TimeInterval,
    sequences: Set<String>
  ) -> Result {
    let key = key.lowercased()
    var held: String?
    if !prefix.isEmpty {
      let candidate = prefix + key
      if time - heldAt <= Self.timeout, sequences.contains(candidate) {
        reset()
        return .command(candidate)
      }
      held = flush()
    }
    if key.count == 1, sequences.contains(where: { $0.hasPrefix(key) }) {
      prefix = key
      heldAt = time
      return held.map(Result.flushAndHold) ?? .pending
    }
    return held.map(Result.flush) ?? .pass
  }
}
