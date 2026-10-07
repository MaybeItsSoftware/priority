import Foundation

/// Whole-file JSON storage for the set of dailies.
///
/// Deliberately *not* the append-only JSONL shape `DayLogFileStore` uses, and
/// the difference is the point: the day log is history, which only ever grows
/// and must never be rewritten, whereas this is current configuration, which is
/// small, edited in place, and has no past worth preserving. Renaming a daily
/// should change its name, not append a rename event that every reader then has
/// to replay.
///
/// Written atomically, so a crash mid-save leaves the previous list intact
/// rather than a half-written one.
public final class DailyDefinitionsStore {
  public enum StoreError: LocalizedError {
    case writeFailed(underlying: Error)
    /// The file is there but could not be read or decoded. Distinct from "no
    /// file" on purpose: a missing file is first launch and an empty set is the
    /// right answer, whereas a present-but-broken one is somebody's dailies
    /// behind a typo, and the only safe thing to do with it is leave it alone.
    case unreadable(path: String, underlying: Error)

    public var errorDescription: String? {
      switch self {
      case .writeFailed(let underlying):
        return "Could not save your dailies: \(underlying.localizedDescription)"
      case .unreadable(let path, let underlying):
        return
          "Could not read your dailies at \(path): \(underlying.localizedDescription) "
          + "Fix or move the file; nothing will be saved over it until it reads."
      }
    }
  }

  public let fileURL: URL

  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(directoryURL: URL, fileName: String = "dailies.json") {
    self.fileURL = directoryURL.appendingPathComponent(fileName)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Pretty-printed here, unlike the log: this file is small, and a human
    // opening it to fix a typo is a perfectly reasonable thing to do.
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  /// A missing file is an empty set, not an error — that is first launch, and
  /// the empty state is a designed screen rather than a failure.
  ///
  /// A file that *exists* but will not read or decode is `StoreError.unreadable`.
  /// This file is hand-editable, so one stray comma is a realistic state, and
  /// the pre-existing behaviour — treat it as empty — meant the next edit saved
  /// that emptiness over the user's dailies with no error. Callers that can show
  /// the error should; callers that can't should fall back to `load()`, which
  /// reads as empty but is never used as the base for a write.
  public func loadStrict() throws -> DailyCollection {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return DailyCollection()
      }
      throw StoreError.unreadable(path: fileURL.path, underlying: error)
    }
    do {
      return try decoder.decode(DailyCollection.self, from: data)
    } catch {
      throw StoreError.unreadable(path: fileURL.path, underlying: error)
    }
  }

  /// `loadStrict()` with the error folded into an empty set, for read-only
  /// callers that have nowhere to show it. Never use the result as the base for
  /// a save — that is what `mutate` is for, and it refuses an unreadable file.
  public func load() -> DailyCollection {
    (try? loadStrict()) ?? DailyCollection()
  }

  public func save(_ collection: DailyCollection) throws {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(collection)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw StoreError.writeFailed(underlying: error)
    }
  }

  /// Applies `transform` to whatever is **on disk right now** and saves the
  /// result, with the file locked for the whole read/modify/write.
  ///
  /// This is the only safe way to change the set of dailies, and callers must
  /// not hand it a snapshot they loaded earlier. The app and the MCP server are
  /// separate processes editing the same file, so a caller that saves its own
  /// in-memory copy overwrites anything the other one added in the meantime —
  /// with no error, because from that caller's point of view the write
  /// succeeded. Re-reading inside the lock means a mutation is expressed as
  /// *what changed*, which composes with a concurrent one; a snapshot is
  /// *everything*, which cannot.
  ///
  /// Refuses — with `StoreError.unreadable` — to touch a file that exists but
  /// did not decode. Saving over it would turn a typo into data loss.
  ///
  /// Returns the saved collection so callers can refresh their cache from the
  /// authoritative value rather than guessing at it.
  @discardableResult
  public func mutate(_ transform: (inout DailyCollection) -> Void) throws -> DailyCollection {
    try FileLock(protecting: fileURL).withExclusiveLock {
      var collection = try loadStrict()
      transform(&collection)
      try save(collection)
      return collection
    }
  }

  /// The current contents, read under the lock so it can't observe a write in
  /// progress. `load()` stays lock-free for the hot path where a torn read is
  /// already handled by falling back to an empty collection.
  public func loadLocked() throws -> DailyCollection {
    try FileLock(protecting: fileURL).withExclusiveLock { try loadStrict() }
  }
}
