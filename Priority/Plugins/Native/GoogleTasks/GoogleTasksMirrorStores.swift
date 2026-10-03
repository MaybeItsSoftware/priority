import Foundation
import PriorityCore

/// Where the mirror keeps what it last pushed.
///
/// Whole-file and atomically replaced, like `dailies.json` and unlike
/// `daylog.jsonl`: this is not history, it is the mirror's current belief
/// about the far side, and a torn tail would make it lie. Losing the file is
/// survivable — the next pass sees an empty ledger, and adopts whatever is
/// already in the mirrored Google lists rather than duplicating it.
struct GoogleTasksMirrorLedgerStore {
  private let url: URL

  init(directory: URL = DailyLogService.defaultStoreDirectoryURL()) {
    self.url = directory.appendingPathComponent("google-tasks-mirror.json")
  }

  func load() -> GoogleTasksMirror.Ledger {
    guard let data = try? Data(contentsOf: url),
      let ledger = try? JSONDecoder().decode(GoogleTasksMirror.Ledger.self, from: data)
    else { return .empty }
    return ledger
  }

  func save(_ ledger: GoogleTasksMirror.Ledger) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(ledger).write(to: url, options: .atomic)
  }
}

/// One entry in the record of what Priority's authority actually cost.
struct GoogleTasksConflictRecord: Codable, Identifiable, Equatable {
  let id: String
  let resolvedAt: Date
  let taskTitle: String
  let field: GoogleTasksMirror.ConflictField
  let keptValue: String
  let discardedValue: String

  var summary: String {
    switch field {
    case .existence:
      return "\(taskTitle) — deleted in Google Tasks, restored from Takt"
    case .title:
      return "\(taskTitle) — kept the Takt title over “\(discardedValue)”"
    case .notes:
      return "\(taskTitle) — kept the Takt notes; Google's were “\(truncated(discardedValue))”"
    case .due:
      return "\(taskTitle) — kept the Takt due date over \(discardedValue)"
    }
  }

  private func truncated(_ value: String) -> String {
    value.count <= 60 ? value : String(value.prefix(60)) + "…"
  }
}

/// The conflict log: append-only, one JSON object per line.
///
/// History, so it has the shape history should have. The authority rule means
/// Priority sometimes throws away something a person typed on their phone;
/// this is the one place that says so, which is the difference between a rule
/// and a silent data loss.
struct GoogleTasksConflictLog {
  private let url: URL
  /// How many entries a reader is shown. The file keeps everything.
  static let recentLimit = 50

  init(directory: URL = DailyLogService.defaultStoreDirectoryURL()) {
    self.url = directory.appendingPathComponent("google-tasks-conflicts.jsonl")
  }

  var fileURL: URL { url }

  func append(_ records: [GoogleTasksConflictRecord]) {
    guard !records.isEmpty else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let lines = records.compactMap { record -> String? in
      guard let data = try? encoder.encode(record) else { return nil }
      return String(data: data, encoding: .utf8)
    }
    guard !lines.isEmpty else { return }
    let payload = Data((lines.joined(separator: "\n") + "\n").utf8)

    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: payload)
    } else {
      try? payload.write(to: url, options: .atomic)
    }
  }

  /// Most recent first. A torn final line is dropped rather than failing the
  /// read — the same tolerance `daylog.jsonl` has, for the same reason.
  func recent(limit: Int = GoogleTasksConflictLog.recentLimit) -> [GoogleTasksConflictRecord] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return contents.split(separator: "\n")
      .compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(GoogleTasksConflictRecord.self, from: data)
      }
      .suffix(limit)
      .reversed()
  }
}
