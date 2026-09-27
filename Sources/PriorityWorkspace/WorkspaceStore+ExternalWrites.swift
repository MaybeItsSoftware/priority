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
    try database.writeWithoutTransaction { db in
      try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
    }
  }
}
