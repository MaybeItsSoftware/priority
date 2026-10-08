import Foundation
import GRDB

extension WorkspaceStore {
  /// A number that moves when *another* process commits to this database, and
  /// only then.
  ///
  /// The `priority` CLI, which is also the app's MCP server, writes the task
  /// tree directly, and nothing in GRDB tells this process about it, because
  /// its observation is in-process. `PRAGMA data_version` is SQLite's own
  /// answer. It is per connection and ignores that connection's own commits,
  /// so it is read on the pool's writer, the only connection this process
  /// writes through. Every commit it reports is therefore someone else's.
  public func externalChangeToken() throws -> Int {
    try database.writeWithoutTransaction { db in try Self.dataVersion(db) } - ownCoreCommits
  }

  /// The same token, read without holding the calling thread.
  ///
  /// It still has to be the writer's connection — any other one would count
  /// this process's own commits too — but awaiting it means a poll that lands
  /// behind a write waits on the writer's queue rather than on the main
  /// thread.
  public func readExternalChangeToken() async throws -> Int {
    try await database.writeWithoutTransaction { db in try Self.dataVersion(db) } - ownCoreCommits
  }

  /// Runs one of this store's writes that the Rust core makes on its own
  /// connection (docs/rust-core-migration.md), and keeps it out of the token.
  ///
  /// The writer's `data_version` counts every commit but its own, which now
  /// includes the core's. So the call runs on the writer's queue, where no
  /// GRDB write can slip in, and however far the version moved across it is
  /// added to `ownCoreCommits`, which the token subtracts. Another process's
  /// commit landing in the same moment is absorbed too; that is harmless,
  /// because every caller of a store write reloads afterwards.
  func coreWrite<T>(_ call: () throws -> T) throws -> T {
    try database.writeWithoutTransaction { db in
      let before = try Self.dataVersion(db)
      let result = try Self.mappingCoreErrors(call)
      let after = try Self.dataVersion(db)
      ownCoreCommitLock.withLock { ownCoreCommitCount += after - before }
      return result
    }
  }

  private var ownCoreCommits: Int { ownCoreCommitLock.withLock { ownCoreCommitCount } }

  private static func dataVersion(_ db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
  }
}
