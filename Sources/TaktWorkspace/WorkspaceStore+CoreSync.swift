import Foundation
import TaktRustCore

// The sync engine's reads and writes: the Rust core's `core/src/sync.rs`,
// which Android calls too. The transport and the clock stay in TaktSync; this
// is everything that touches the file. The store's own sync types are kept as
// the engine's vocabulary and converted at this edge.

extension TaktWorkspace.SyncValue {
  var core: TaktRustCore.SyncValue {
    switch self {
    case .null: .null
    case .integer(let value): .integer(value: value)
    case .real(let value): .real(value: value)
    case .text(let value): .text(value: value)
    }
  }

  init(_ core: TaktRustCore.SyncValue) {
    switch core {
    case .null: self = .null
    case .integer(let value): self = .integer(value)
    case .real(let value): self = .real(value)
    case .text(let value): self = .text(value)
    }
  }
}

extension WorkspaceStore {
  /// The device's sync state, or nil while the device has never been paired.
  public func syncState() throws -> SyncLocalState? {
    try Self.mappingCoreErrors { try core.syncState() }.map { state in
      SyncLocalState(
        deviceId: state.deviceId, cursor: state.cursor, hlc: state.hlc, serverURL: state.serverUrl,
        canonicalWorkspaceId: state.canonicalWorkspaceId, needsSnapshot: state.needsSnapshot,
        lastSyncedAt: state.lastSyncedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
        isRecording: state.isRecording)
    }
  }

  /// Pairs the store with a server. The first cycle afterwards snapshots every
  /// existing row and pulls before it pushes.
  public func beginSync(deviceId: String, serverURL: String) throws {
    try coreWrite { try core.beginSync(deviceId: deviceId, serverUrl: serverURL) }
  }

  /// The newest outbox entry, or nil when nothing is waiting.
  public func latestSyncOutboxSeq() throws -> Int64? {
    try Self.mappingCoreErrors { try core.latestSyncOutboxSeq() }
  }

  /// Unpairs: stops recording and forgets what was waiting to be sent.
  public func endSync() throws {
    try coreWrite { try core.endSync() }
  }

  /// Turns recording on and queues every existing row as an insert.
  public func enqueueSyncSnapshot(now: Date = .now) throws {
    try coreWrite { try core.enqueueSyncSnapshot(nowMs: now.coreMilliseconds) }
  }

  /// The outbox, coalesced per row and read from the live rows.
  public func pendingSyncChanges(limit: Int = 500) throws -> (changes: [SyncOutgoingChange], throughSeq: Int64?) {
    let pending = try Self.mappingCoreErrors { try core.pendingSyncChanges(limit: UInt32(clamping: max(0, limit))) }
    let changes = pending.changes.map { change in
      SyncOutgoingChange(
        table: change.table, rowId: change.rowId,
        operation: change.operation == "delete" ? .delete : .upsert,
        values: change.values.mapValues { TaktWorkspace.SyncValue($0) }, changedAtMs: change.changedAtMs)
    }
    return (changes, pending.throughSeq)
  }

  /// Forgets the outbox entries the server has accepted.
  public func acknowledgeSyncChanges(throughSeq: Int64) throws {
    try coreWrite { try core.acknowledgeSyncChanges(throughSeq: throughSeq) }
  }

  /// Writes a pull into the workspace in one transaction, then adopts any
  /// second workspace and clears orphans. Returns whether anything changed.
  @discardableResult
  public func applyRemoteRows(
    _ rows: [SyncIncomingRow], cursor: Int64, hlc: String?, now: Date = .now
  ) throws -> Bool {
    let incoming = rows.map { row in
      IncomingRow(
        table: row.table, id: row.id, deleted: row.deleted, values: row.values.mapValues(\.core), hlc: row.hlc)
    }
    return try coreWrite {
      try core.applyRemoteRows(rows: incoming, cursor: cursor, hlc: hlc, nowMs: now.coreMilliseconds)
    }
  }

  /// Advances the stored clock and the last-synced time without applying rows.
  public func recordSyncProgress(cursor: Int64? = nil, hlc: String?, now: Date = .now) throws {
    try coreWrite { try core.recordSyncProgress(cursor: cursor, hlc: hlc, nowMs: now.coreMilliseconds) }
  }
}
