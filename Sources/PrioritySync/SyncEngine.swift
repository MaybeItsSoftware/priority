import Foundation
import PriorityWorkspace

/// Runs the client half of the sync cycle in `docs/sync.md` against one store.
///
/// An actor so a cycle never overlaps another: a write that lands mid-cycle
/// stays in the outbox and goes out with the next one, and a second request for
/// a cycle while one runs is folded into a single follow-up.
public actor SyncEngine {
  public enum Status: Equatable, Sendable {
    case idle(lastSyncedAt: Date?)
    case syncing
    case failed(String)
    /// The server refused the token. Retrying cannot help; signing in can.
    case signedOut
  }

  public struct Outcome: Equatable, Sendable {
    public var pushed: Int
    public var pulled: Int
    /// Whether the pull changed the workspace, so the UI knows to reload.
    public var changedWorkspace: Bool
  }

  let store: WorkspaceStore
  let transport: any SyncTransport
  let deviceId: String
  let wallClock: @Sendable () -> Date
  public private(set) var status: Status = .idle(lastSyncedAt: nil)
  // An actor runs other calls while one awaits the network, so two cycles
  // could interleave and a slower pull land its older rows and cursor after a
  // faster one. Cycles queue here instead.
  private var running = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  static let pushBatch = 500
  static let pullPage = 1000

  public init(
    store: WorkspaceStore, transport: any SyncTransport, deviceId: String,
    wallClock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.transport = transport
    self.deviceId = deviceId
    self.wallClock = wallClock
  }

  /// One push-then-pull cycle. The first cycle after pairing snapshots the
  /// workspace and pulls first, so a device joining an account adopts it.
  @discardableResult
  public func sync(wait: Int = 0) async throws -> Outcome {
    while running { await withCheckedContinuation { waiters.append($0) } }
    running = true
    defer {
      running = false
      if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
    guard let state = try store.syncState() else { throw SyncError.notPaired }
    status = .syncing
    do {
      var clock = state.hlc.flatMap(HybridLogicalClock.init) ?? HybridLogicalClock(
        milliseconds: 0, counter: 0, deviceId: deviceId)
      var outcome = Outcome(pushed: 0, pulled: 0, changedWorkspace: false)
      if state.needsSnapshot {
        try store.enqueueSyncSnapshot(now: wallClock())
        try await pull(from: state.cursor, clock: &clock, wait: 0, outcome: &outcome)
        try await push(clock: &clock, outcome: &outcome)
      } else {
        try await push(clock: &clock, outcome: &outcome)
        let cursor = try store.syncState()?.cursor ?? state.cursor
        try await pull(from: cursor, clock: &clock, wait: wait, outcome: &outcome)
      }
      status = .idle(lastSyncedAt: wallClock())
      return outcome
    } catch {
      status = error as? SyncError == .unauthorized ? .signedOut : .failed(error.localizedDescription)
      throw error
    }
  }

  private func push(clock: inout HybridLogicalClock, outcome: inout Outcome) async throws {
    while true {
      let (changes, throughSeq) = try store.pendingSyncChanges(limit: Self.pushBatch)
      guard let throughSeq, !changes.isEmpty else { break }
      var wire: [SyncPushChange] = []
      // Stamped in the order the edits were made, so a later edit to a column
      // always carries the later clock.
      for change in changes.sorted(by: { $0.changedAtMs < $1.changedAtMs }) {
        clock = clock.tick(wallMilliseconds: max(change.changedAtMs, Self.ms(wallClock())))
        wire.append(SyncPushChange(
          table: change.table, id: change.rowId, op: change.operation.rawValue, hlc: clock.description,
          values: change.operation == .delete ? nil : change.values))
      }
      _ = try await transport.push(wire)
      try store.acknowledgeSyncChanges(throughSeq: throughSeq)
      try store.recordSyncProgress(hlc: clock.description, now: wallClock())
      outcome.pushed += wire.count
    }
  }

  private func pull(
    from cursor: Int64, clock: inout HybridLogicalClock, wait: Int, outcome: inout Outcome
  ) async throws {
    var rows: [SyncIncomingRow] = []
    var next = cursor
    var firstPage = true
    while true {
      let page = try await transport.changes(since: next, limit: Self.pullPage, wait: firstPage ? wait : 0)
      firstPage = false
      rows.append(contentsOf: page.rows)
      next = page.cursor
      if !page.hasMore { break }
    }
    for row in rows {
      if let stamp = row.hlc.flatMap(HybridLogicalClock.init) {
        clock = clock.receiving(stamp, wallMilliseconds: Self.ms(wallClock()))
      }
    }
    // Every page lands in one transaction: a task can arrive a page before its
    // list, and only the end of the whole pull is a consistent state.
    let changed = try store.applyRemoteRows(rows, cursor: next, hlc: clock.description, now: wallClock())
    outcome.pulled += rows.count
    outcome.changedWorkspace = outcome.changedWorkspace || changed
  }

  static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
