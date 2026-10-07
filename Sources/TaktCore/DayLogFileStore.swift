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

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        // A torn previous append (crash between the JSON and its newline)
        // leaves the file ending mid-line. Appending straight after it would
        // glue this event onto that fragment, and the tolerant reader would
        // then drop the pair — losing a good event to a bad one. Close the
        // fragment first; it costs one byte and the reader skips the stub.
        let end = try handle.seekToEnd()
        if end > 0 {
          try handle.seek(toOffset: end - 1)
          if try handle.read(upToCount: 1) != Data([0x0A]) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
          }
        }
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
  ///
  /// Split as bytes rather than decoded as one string: a single invalid UTF-8
  /// byte in one line used to make the whole-file `String` read fail and
  /// return an empty history, which is exactly the all-or-nothing failure the
  /// line format exists to rule out. Each line is now decoded on its own, so a
  /// bad byte costs that line and nothing else.
  public func loadAll() -> [DayLogEvent] {
    guard let contents = try? Data(contentsOf: fileURL) else { return [] }
    return contents
      .split(separator: 0x0A, omittingEmptySubsequences: true)
      .compactMap { line in
        try? decoder.decode(DayLogEvent.self, from: line)
      }
  }
}
