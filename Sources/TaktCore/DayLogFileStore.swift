import Foundation
import TaktRustCore

/// Append-only JSONL storage for `DayLogEvent`.
///
/// One event per line, ISO-8601 timestamps, no rewriting. That shape is chosen
/// for durability and legibility over compactness: a crash mid-write costs the
/// tail line and nothing else, and the file stays greppable with `tail` and
/// `grep`. This is a personal history — being able to read it without the app
/// matters more than saving bytes.
///
/// Reads tolerate a damaged line rather than failing the whole load, for the
/// same reason: losing one event to a torn write is a nuisance, losing a year
/// of history to it is not survivable.
///
/// Reading and writing are the Rust core's (`core/src/day_log.rs`), which the
/// CLI calls too, so there is one reading of the format. Something that keeps
/// the log open uses `DayLogHistory`, which holds it in the core.
public final class DayLogFileStore {
  public enum StoreError: LocalizedError {
    case writeFailed(underlying: Error)

    public var errorDescription: String? {
      switch self {
      case .writeFailed(let underlying):
        return "Could not write to the daily log: \(underlying.localizedDescription)"
      }
    }
  }

  public let fileURL: URL

  public init(directoryURL: URL, fileName: String = "daylog.jsonl") {
    self.fileURL = directoryURL.appendingPathComponent(fileName)
  }

  /// Appends one event, as the core writes it: under the `flock` the app and
  /// the `--mcp-server` process both take, since two unsynchronised appends
  /// can splice a line and lose both events; and after closing a torn final
  /// line, so this event is not glued onto the fragment and dropped with it.
  public func append(_ event: DayLogEvent) throws {
    do {
      try dayLogAppend(path: fileURL.path, event: event.core)
    } catch {
      throw StoreError.writeFailed(underlying: error)
    }
  }

  /// Every event in the file, in append order. A missing file is an empty log,
  /// not an error — that is the state on first launch, and it is the state the
  /// "collecting since" empty state is built for. Each line is decoded on its
  /// own, so a bad byte costs that line and nothing else.
  public func loadAll() -> [DayLogEvent] {
    dayLogLoad(path: fileURL.path).map(DayLogEvent.init(core:))
  }
}
