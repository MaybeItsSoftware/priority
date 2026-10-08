import Foundation
import GRDB

/// The store's half of multi-device sync. The protocol is specified in
/// `docs/sync.md`; this file is its local schema and the reads and writes the
/// engine in `TaktSync` drives.
///
/// The shape mirrors undo. Triggers note which rows changed, and the engine
/// reads the live rows when it pushes. Nothing on the write path calls into
/// Swift: the CLI and `sqlite3` write to this same file, and a trigger calling
/// a function only this process registers would fail every one of their writes.
/// The triggers stay off until the device is paired, so an unpaired workspace
/// pays nothing for them.
extension WorkspaceStore {
  /// Every synced table and the column it is keyed by, parents first. A
  /// snapshot is enqueued in this order so a server replaying it never sees a
  /// child before its parent.
  public static let syncedTables: [(table: String, key: String)] = [
    ("workspaces", "id"),
    ("list_folders", "id"),
    ("task_lists", "id"),
    ("tasks", "id"),
    ("task_metadata", "taskId"),
    ("task_conditions", "id"),
    ("kanban_boards", "id"),
    ("dailies", "id"),
    ("daily_contributions", "id"),
    ("focus_sessions", "id"),
    ("focus_queue_items", "id"),
    ("focus_work_blocks", "id"),
    ("focus_awards", "id"),
    // `v18_themes_and_preferences`. No foreign keys, so their place is free.
    ("themes", "id"),
    ("preferences", "key"),
  ]

}

// MARK: - Values

/// One SQLite value as it travels over the wire: `null`, a number or text,
/// exactly as the column stores it.
public enum SyncValue: Codable, Equatable, Sendable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let int = try? container.decode(Int64.self) {
      self = .integer(int)
    } else if let double = try? container.decode(Double.self) {
      self = .real(double)
    } else {
      self = .text(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .integer(let value): try container.encode(value)
    case .real(let value): try container.encode(value)
    case .text(let value): try container.encode(value)
    }
  }

}

/// A row's local change, coalesced from its outbox entries and read from the
/// live row, ready to be stamped and pushed.
public struct SyncOutgoingChange: Equatable, Sendable {
  public enum Operation: String, Sendable { case upsert, delete }
  public var table: String
  public var rowId: String
  public var operation: Operation
  /// The columns to push and their current values. Empty for a delete.
  public var values: [String: SyncValue]
  /// When the newest of the coalesced edits was made, for stamping the clock.
  public var changedAtMs: Int64
}

/// A row as the server holds it.
public struct SyncIncomingRow: Codable, Equatable, Sendable {
  public var table: String
  public var id: String
  public var deleted: Bool
  public var values: [String: SyncValue]
  public var hlc: String?

  public init(table: String, id: String, deleted: Bool, values: [String: SyncValue], hlc: String? = nil) {
    self.table = table
    self.id = id
    self.deleted = deleted
    self.values = values
    self.hlc = hlc
  }
}

/// What the device remembers about its sync.
public struct SyncLocalState: Equatable, Sendable {
  public var deviceId: String
  public var cursor: Int64
  public var hlc: String?
  public var serverURL: String?
  public var canonicalWorkspaceId: String?
  public var needsSnapshot: Bool
  public var lastSyncedAt: Date?
  public var isRecording: Bool
}
