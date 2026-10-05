import Foundation

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

  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(directoryURL: URL, fileName: String = "daylog.jsonl") {
    self.fileURL = directoryURL.appendingPathComponent(fileName)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Explicitly *not* pretty-printed: one line per event is the format.
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  /// Appends one event.
  ///
  /// Locked because the app and the `--mcp-server` process both append here.
  /// Two unsynchronised `seekToEnd` + `write` pairs can interleave and produce
  /// a spliced line — which the tolerant reader then drops, losing *both*
  /// events rather than one. The lock is around a single small append, so
  /// contention is negligible.
  public func append(_ event: DayLogEvent) throws {
    do {
      let data = try encoder.encode(event)
      var line = data
      line.append(0x0A)  // \n

      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      try FileLock(protecting: fileURL).withExclusiveLock {
        guard fileManager.fileExists(atPath: fileURL.path) else {
          try line.write(to: fileURL, options: .atomic)
          return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      }
    } catch {
      throw StoreError.writeFailed(underlying: error)
    }
  }

  /// Every event in the file, in append order. A missing file is an empty log,
  /// not an error — that is the state on first launch, and it is the state the
  /// "collecting since" empty state is built for.
  public func loadAll() -> [DayLogEvent] {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    return contents
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(DayLogEvent.self, from: data)
      }
  }
}
