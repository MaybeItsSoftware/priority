import Foundation
import GRDB

/// The store's half of multi-device sync. The protocol is specified in
/// `docs/sync.md`; this file is its local schema and the reads and writes the
/// engine in `PrioritySync` drives.
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
  ]

  static func syncKey(for table: String) -> String? {
    syncedTables.first { $0.table == table }?.key
  }

  static func createSyncTables(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE sync_control (
        id INTEGER PRIMARY KEY,
        recording INTEGER NOT NULL DEFAULT 0,
        applying INTEGER NOT NULL DEFAULT 0);
      INSERT INTO sync_control (id) VALUES (0);
      CREATE TABLE sync_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        tableName TEXT NOT NULL,
        rowId TEXT NOT NULL,
        operation TEXT NOT NULL,
        changedJSON TEXT,
        changedAtMs INTEGER NOT NULL);
      CREATE INDEX sync_outbox_on_row ON sync_outbox(tableName, rowId);
      CREATE TABLE sync_state (
        id INTEGER PRIMARY KEY,
        deviceId TEXT NOT NULL,
        cursor INTEGER NOT NULL DEFAULT 0,
        hlc TEXT,
        serverURL TEXT,
        canonicalWorkspaceId TEXT,
        needsSnapshot INTEGER NOT NULL DEFAULT 1,
        lastSyncedAt DATETIME);
      """)
  }

  /// Writes the outbox triggers. Like `installChangeLogTriggers`, a trigger
  /// names its columns, so any later migration that adds or removes a column
  /// on a synced table must call this again.
  static func installSyncTriggers(_ db: Database) throws {
    let guardClause = """
      WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
        AND (SELECT applying FROM sync_control WHERE id = 0) = 0
      """
    let now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
    let entry = "INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs)"
    for (table, key) in syncedTables {
      guard try db.tableExists(table) else { continue }
      let columns = try db.columns(in: table).map(\.name)
      let changed = "json_array(" + columns.map {
        "CASE WHEN OLD.\"\($0)\" IS NOT NEW.\"\($0)\" THEN '\($0)' END"
      }.joined(separator: ", ") + ")"
      for suffix in ["insert", "update", "delete"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS sync_outbox_\(table)_\(suffix)")
      }
      try db.execute(sql: """
        CREATE TRIGGER sync_outbox_\(table)_insert AFTER INSERT ON \(table) \(guardClause)
        BEGIN \(entry) VALUES ('\(table)', NEW."\(key)", 'insert', NULL, \(now)); END
        """)
      try db.execute(sql: """
        CREATE TRIGGER sync_outbox_\(table)_update AFTER UPDATE ON \(table) \(guardClause)
        BEGIN \(entry) VALUES ('\(table)', NEW."\(key)", 'update', \(changed), \(now)); END
        """)
      try db.execute(sql: """
        CREATE TRIGGER sync_outbox_\(table)_delete AFTER DELETE ON \(table) \(guardClause)
        BEGIN \(entry) VALUES ('\(table)', OLD."\(key)", 'delete', NULL, \(now)); END
        """)
    }
  }
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

  init(_ value: DatabaseValue) {
    switch value.storage {
    case .null: self = .null
    case .int64(let int): self = .integer(int)
    case .double(let double): self = .real(double)
    case .string(let string): self = .text(string)
    case .blob(let data): self = .text(data.base64EncodedString())
    }
  }

  var databaseValue: DatabaseValue {
    switch self {
    case .null: return .null
    case .integer(let value): return value.databaseValue
    case .real(let value): return value.databaseValue
    case .text(let value): return value.databaseValue
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

// MARK: - The engine's reads and writes

extension WorkspaceStore {
  /// The device's sync state, or nil while the device has never been paired.
  public func syncState() throws -> SyncLocalState? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 0") else { return nil }
      let recording = try Int.fetchOne(db, sql: "SELECT recording FROM sync_control WHERE id = 0") ?? 0
      return SyncLocalState(
        deviceId: row["deviceId"], cursor: row["cursor"], hlc: row["hlc"], serverURL: row["serverURL"],
        canonicalWorkspaceId: row["canonicalWorkspaceId"], needsSnapshot: (row["needsSnapshot"] as Int) != 0,
        lastSyncedAt: row["lastSyncedAt"], isRecording: recording != 0)
    }
  }

  /// Pairs the store with a server. The first cycle afterwards snapshots every
  /// existing row and pulls before it pushes, so this device adopts whatever
  /// the server already holds.
  public func beginSync(deviceId: String, serverURL: String) throws {
    try database.write { db in
      try db.execute(sql: """
        INSERT INTO sync_state (id, deviceId, serverURL, cursor, needsSnapshot) VALUES (0, ?, ?, 0, 1)
        ON CONFLICT(id) DO UPDATE SET deviceId = excluded.deviceId, serverURL = excluded.serverURL,
          cursor = 0, needsSnapshot = 1, hlc = NULL, canonicalWorkspaceId = NULL
        """, arguments: [deviceId, serverURL])
    }
  }

  /// The newest outbox entry, or nil when nothing is waiting. Polled so a
  /// write from any process is noticed and sent.
  public func latestSyncOutboxSeq() throws -> Int64? {
    try database.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM sync_outbox") }
  }

  /// Unpairs: stops recording and forgets what was waiting to be sent. The
  /// workspace itself is untouched.
  public func endSync() throws {
    try database.write { db in
      try db.execute(sql: "UPDATE sync_control SET recording = 0, applying = 0 WHERE id = 0")
      try db.execute(sql: "DELETE FROM sync_outbox")
      try db.execute(sql: "DELETE FROM sync_state")
    }
  }

  /// Turns recording on and queues every existing row, parents first, as an
  /// insert. Called once, by the first cycle after pairing.
  public func enqueueSyncSnapshot(now: Date = .now) throws {
    let ms = Int64(now.timeIntervalSince1970 * 1000)
    try database.write { db in
      try db.execute(sql: "UPDATE sync_control SET recording = 1 WHERE id = 0")
      for (table, key) in Self.syncedTables {
        try db.execute(sql: """
          INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs)
          SELECT ?, "\(key)", 'insert', NULL, ? FROM \(table)
          """, arguments: [table, ms])
      }
      try db.execute(sql: "UPDATE sync_state SET needsSnapshot = 0 WHERE id = 0")
    }
  }

  /// The outbox, coalesced per row and read from the live rows, up to `limit`
  /// rows. `throughSeq` is the newest entry folded in: acknowledge it once the
  /// server has the batch.
  public func pendingSyncChanges(limit: Int = 500) throws -> (changes: [SyncOutgoingChange], throughSeq: Int64?) {
    try database.read { db in
      let entries = try Row.fetchAll(db, sql: "SELECT * FROM sync_outbox ORDER BY seq")
      guard !entries.isEmpty else { return ([], nil) }

      struct Pending {
        var table: String
        var rowId: String
        var lastOperation: String
        var everyColumn: Bool
        var columns: Set<String>
        var changedAtMs: Int64
      }
      var order: [String] = []
      var pending: [String: Pending] = [:]
      var throughSeq: Int64 = 0
      for entry in entries {
        let table: String = entry["tableName"]
        let rowId: String = entry["rowId"]
        let operation: String = entry["operation"]
        let key = table + "\u{1F}" + rowId
        if pending[key] == nil {
          // Stop at a row boundary, so a row's entries are never split across
          // two batches and acknowledged before they were all sent.
          if order.count == limit { break }
          order.append(key)
          pending[key] = Pending(
            table: table, rowId: rowId, lastOperation: operation, everyColumn: false, columns: [],
            changedAtMs: 0)
        }
        throughSeq = entry["seq"]
        var item = pending[key]!
        item.lastOperation = operation
        item.changedAtMs = max(item.changedAtMs, entry["changedAtMs"])
        switch operation {
        case "insert": item.everyColumn = true
        case "update":
          if let json: String = entry["changedJSON"], let data = json.data(using: .utf8),
            let names = try? JSONSerialization.jsonObject(with: data) as? [Any]
          {
            item.columns.formUnion(names.compactMap { $0 as? String })
          }
        default: break
        }
        pending[key] = item
      }

      var changes: [SyncOutgoingChange] = []
      for key in order {
        guard let item = pending[key], let keyColumn = Self.syncKey(for: item.table) else { continue }
        let live = try Row.fetchOne(
          db, sql: "SELECT * FROM \(item.table) WHERE \"\(keyColumn)\" = ?", arguments: [item.rowId])
        guard item.lastOperation != "delete", let live else {
          changes.append(SyncOutgoingChange(
            table: item.table, rowId: item.rowId, operation: .delete, values: [:],
            changedAtMs: item.changedAtMs))
          continue
        }
        var values: [String: SyncValue] = [:]
        for column in live.columnNames
        where item.everyColumn || item.columns.contains(column) || column == keyColumn {
          values[column] = SyncValue(live[column] as DatabaseValue)
        }
        changes.append(SyncOutgoingChange(
          table: item.table, rowId: item.rowId, operation: .upsert, values: values,
          changedAtMs: item.changedAtMs))
      }
      return (changes, throughSeq)
    }
  }

  /// Forgets the outbox entries the server has accepted.
  public func acknowledgeSyncChanges(throughSeq: Int64) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM sync_outbox WHERE seq <= ?", arguments: [throughSeq])
    }
  }

  /// Writes a pull into the workspace in one transaction, then adopts any
  /// second workspace into the canonical one and clears orphans. Returns
  /// whether anything changed.
  @discardableResult
  public func applyRemoteRows(
    _ rows: [SyncIncomingRow], cursor: Int64, hlc: String?, now: Date = .now
  ) throws -> Bool {
    try database.write { db in
      try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
      try db.execute(sql: "UPDATE sync_control SET applying = 1 WHERE id = 0")
      var changed = false
      do {
        for row in rows {
          guard let keyColumn = Self.syncKey(for: row.table) else { continue }
          // A local edit made since the push is newer than what arrived. Leave
          // it; the next cycle pushes it and the server settles the row.
          let waiting = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE tableName = ? AND rowId = ?)
            """, arguments: [row.table, row.id]) ?? false
          if waiting { continue }
          if row.deleted {
            try db.execute(
              sql: "DELETE FROM \(row.table) WHERE \"\(keyColumn)\" = ?", arguments: [row.id])
          } else {
            try Self.upsertRemote(row, keyColumn: keyColumn, db: db)
          }
          changed = changed || db.changesCount > 0
        }
      } catch {
        try? db.execute(sql: "UPDATE sync_control SET applying = 0 WHERE id = 0")
        throw error
      }
      try db.execute(sql: "UPDATE sync_control SET applying = 0 WHERE id = 0")

      if try Self.adoptWorkspaces(db, now: now) { changed = true }
      if try Self.removeOrphans(db) { changed = true }

      try db.execute(
        sql: "UPDATE sync_state SET cursor = ?, hlc = COALESCE(?, hlc), lastSyncedAt = ? WHERE id = 0",
        arguments: [cursor, hlc, now])
      return changed
    }
  }

  /// Advances the stored clock and the last-synced time without applying rows.
  public func recordSyncProgress(cursor: Int64? = nil, hlc: String?, now: Date = .now) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE sync_state SET cursor = COALESCE(?, cursor), hlc = COALESCE(?, hlc), lastSyncedAt = ?
          WHERE id = 0
          """,
        arguments: [cursor, hlc, now])
    }
  }

  private static func upsertRemote(_ row: SyncIncomingRow, keyColumn: String, db: Database) throws {
    let tableColumns = Set(try db.columns(in: row.table).map(\.name))
    let values = row.values.filter { tableColumns.contains($0.key) && $0.key != keyColumn }
    let exists = try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM \(row.table) WHERE \"\(keyColumn)\" = ?)", arguments: [row.id]) ?? false
    if exists {
      guard !values.isEmpty else { return }
      let names = values.keys.sorted()
      let assignments = names.map { "\"\($0)\" = ?" }.joined(separator: ", ")
      var arguments = names.map { values[$0]!.databaseValue }
      arguments.append(row.id.databaseValue)
      try db.execute(
        sql: "UPDATE \(row.table) SET \(assignments) WHERE \"\(keyColumn)\" = ?",
        arguments: StatementArguments(arguments))
      return
    }
    let names = [keyColumn] + values.keys.sorted()
    let arguments = [row.id.databaseValue] + values.keys.sorted().map { values[$0]!.databaseValue }
    let sql = """
      INSERT INTO \(row.table) (\(names.map { "\"\($0)\"" }.joined(separator: ", ")))
      VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))
      """
    do {
      try db.execute(sql: sql, arguments: StatementArguments(arguments))
    } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
      // Another key already names this row locally: two devices logged the same
      // daily on the same day, or imported the same source. The server's row
      // wins, and the local one goes with a tombstone so the others drop it too.
      switch try resolveUniqueRival(of: row, insertSQL: sql, arguments: arguments, db: db) {
      case .none: throw error
      case .removed: try db.execute(sql: sql, arguments: StatementArguments(arguments))
      case .inserted: break
      }
    }
  }

  private enum RivalResolution { case none, removed, inserted }

  /// Clears the local row that holds the unique key an incoming row needs,
  /// with recording on so its removal syncs. A rival Inbox keeps its tasks:
  /// they move into the incoming one, which is inserted here to receive them.
  private static func resolveUniqueRival(
    of row: SyncIncomingRow, insertSQL: String, arguments: [DatabaseValue], db: Database
  ) throws -> RivalResolution {
    func text(_ column: String) -> String? {
      if case .text(let value)? = row.values[column] { return value }
      return nil
    }
    let rival: String?
    switch row.table {
    case "daily_contributions":
      rival = try String.fetchOne(
        db, sql: "SELECT id FROM daily_contributions WHERE dailyId = ? AND dayKey = ?",
        arguments: [text("dailyId"), text("dayKey")])
    case "tasks":
      rival = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE sourceSystem IS ? AND sourceId = ?",
        arguments: [text("sourceSystem"), text("sourceId")])
    case "task_lists":
      rival = try String.fetchOne(
        db, sql: "SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = ?",
        arguments: [text("workspaceId"), text("systemRole")])
    default:
      rival = nil
    }
    guard let rival, rival != row.id, let keyColumn = syncKey(for: row.table) else { return .none }
    try db.execute(sql: "UPDATE sync_control SET applying = 0 WHERE id = 0")
    defer { try? db.execute(sql: "UPDATE sync_control SET applying = 1 WHERE id = 0") }
    guard row.table == "task_lists" else {
      try db.execute(sql: "DELETE FROM \(row.table) WHERE \"\(keyColumn)\" = ?", arguments: [rival])
      return .removed
    }
    try db.execute(sql: "UPDATE task_lists SET systemRole = NULL WHERE id = ?", arguments: [rival])
    try db.execute(sql: "UPDATE sync_control SET applying = 1 WHERE id = 0")
    try db.execute(sql: insertSQL, arguments: StatementArguments(arguments))
    try db.execute(sql: "UPDATE sync_control SET applying = 0 WHERE id = 0")
    try db.execute(sql: "UPDATE tasks SET listId = ? WHERE listId = ?", arguments: [row.id, rival])
    try db.execute(sql: "DELETE FROM task_lists WHERE id = ?", arguments: [rival])
    return .inserted
  }

  /// Folds every workspace but the canonical one into it: the first workspace
  /// this device received from the server, or its own when the server had none.
  private static func adoptWorkspaces(_ db: Database, now: Date) throws -> Bool {
    let ids = try String.fetchAll(db, sql: "SELECT id FROM workspaces ORDER BY createdAt")
    var canonical = try String.fetchOne(db, sql: "SELECT canonicalWorkspaceId FROM sync_state WHERE id = 0")
    if canonical == nil || !ids.contains(canonical!) {
      // Prefer a workspace the server sent: one with no outbox entry of its own.
      let remote = try String.fetchOne(db, sql: """
        SELECT id FROM workspaces
        WHERE id NOT IN (SELECT rowId FROM sync_outbox WHERE tableName = 'workspaces')
        ORDER BY createdAt LIMIT 1
        """)
      canonical = remote ?? ids.first
      try db.execute(
        sql: "UPDATE sync_state SET canonicalWorkspaceId = ? WHERE id = 0", arguments: [canonical])
    }
    guard let canonical else { return false }
    let others = ids.filter { $0 != canonical }
    guard !others.isEmpty else { return false }

    let canonicalInbox = try String.fetchOne(db, sql: """
      SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = 'inbox'
      """, arguments: [canonical])
    for other in others {
      if let inbox = try String.fetchOne(db, sql: """
        SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = 'inbox'
        """, arguments: [other])
      {
        if let canonicalInbox {
          try db.execute(sql: "UPDATE tasks SET listId = ? WHERE listId = ?", arguments: [canonicalInbox, inbox])
          try db.execute(sql: "DELETE FROM task_lists WHERE id = ?", arguments: [inbox])
        } else {
          try db.execute(sql: "UPDATE task_lists SET workspaceId = ? WHERE id = ?", arguments: [canonical, inbox])
        }
      }
      for table in ["list_folders", "task_lists"] {
        try db.execute(
          sql: "UPDATE \(table) SET workspaceId = ?, updatedAt = ? WHERE workspaceId = ?",
          arguments: [canonical, now, other])
      }
      // Conditions are named, and both devices seed the same names. Keep the
      // canonical ones and drop the duplicates.
      try db.execute(sql: """
        DELETE FROM task_conditions WHERE workspaceId = ?
          AND name IN (SELECT name FROM task_conditions WHERE workspaceId = ?)
        """, arguments: [other, canonical])
      try db.execute(
        sql: "UPDATE task_conditions SET workspaceId = ? WHERE workspaceId = ?", arguments: [canonical, other])
      try db.execute(sql: "DELETE FROM workspaces WHERE id = ?", arguments: [other])
    }
    return true
  }

  /// Deletes rows whose parent was deleted on another device, repeating until
  /// the foreign keys check clean. Recording is on, so the deletions sync.
  private static func removeOrphans(_ db: Database) throws -> Bool {
    var removedAny = false
    for _ in 0..<16 {
      let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
      guard !violations.isEmpty else { break }
      for violation in violations {
        let table: String = violation["table"]
        let rowid: Int64 = violation["rowid"]
        try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [rowid])
        removedAny = true
      }
    }
    return removedAny
  }
}
