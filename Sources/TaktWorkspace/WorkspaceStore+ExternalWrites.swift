import Foundation
import TaktRustCore

extension WorkspaceStore {
  /// A number that moves when *another* process commits to this database, and
  /// only then.
  ///
  /// The `takt` CLI, which is also the app's MCP server, writes the task tree
  /// directly, and nothing in this process hears about it. `PRAGMA
  /// data_version` is SQLite's own answer: it is per connection and ignores
  /// that connection's own commits. This store reads and writes only through
  /// the Rust core's one connection, so asking that connection
  /// (`CoreWorkspace.dataVersion`) gives exactly the commits made elsewhere.
  public func externalChangeToken() throws -> Int {
    Int(try Self.mappingCoreErrors { try core.dataVersion() })
  }

  /// The same token, read off the calling thread, so a poll that lands
  /// behind a write waits there rather than on the main thread.
  public func readExternalChangeToken() async throws -> Int {
    try await Task.detached(priority: .utility) { [core] in
      Int(try Self.mappingCoreErrors { try core.dataVersion() })
    }.value
  }

  /// A value that changes whenever the file has, whoever changed it: the
  /// external token above, and the rows this store's own writes have
  /// changed (`CoreWorkspace.ownChanges`). Equal stamps mean nothing has been
  /// written in between, so a read keyed to one need not be made again. A
  /// write that rolled back can still move it; that only costs a re-read.
  public func changeStamp() throws -> WorkspaceChangeStamp {
    try Self.mappingCoreErrors {
      WorkspaceChangeStamp(external: try core.dataVersion(), own: try core.ownChanges())
    }
  }

  /// Runs one of this store's writes, which are all the Rust core's
  /// (docs/rust-core-migration.md), with the failures callers react to turned
  /// into the store's own errors. The core's connection does not count its
  /// own commits in `data_version`, so a write here never shows up in
  /// `externalChangeToken`.
  func coreWrite<T>(_ call: () throws -> T) throws -> T {
    try Self.mappingCoreErrors(call)
  }
}

/// See `WorkspaceStore.changeStamp()`.
public struct WorkspaceChangeStamp: Equatable, Sendable {
  public let external: Int64
  public let own: Int64

  public init(external: Int64, own: Int64) {
    self.external = external
    self.own = own
  }
}
