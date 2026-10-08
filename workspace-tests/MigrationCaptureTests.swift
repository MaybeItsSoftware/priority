import Foundation
import GRDB
@testable import TaktWorkspace
import XCTest

/// Records the SQL GRDB's migrator runs for each migration against an empty
/// database, into `core/src/schema/migrations/<identifier>.sql`. That is the
/// DDL the Rust core replays (docs/rust-core-migration.md, step two), taken
/// from the migrator rather than retyped, so the two cannot start out apart.
///
/// Statements that depend on rows (v11, v12 and v13 walk existing lists and
/// workspaces in Swift) issue nothing against an empty database; the core
/// ports those steps by hand in `core/src/schema/data.rs`.
///
/// Off unless asked for, since it writes into the source tree:
///
///     TAKT_CAPTURE_MIGRATIONS=1 swift test --filter MigrationCaptureTests
final class MigrationCaptureTests: XCTestCase {
  func testCaptureEveryMigrationsSQL() throws {
    guard ProcessInfo.processInfo.environment["TAKT_CAPTURE_MIGRATIONS"] == "1" else {
      throw XCTSkip("Set TAKT_CAPTURE_MIGRATIONS=1 to regenerate core/src/schema/migrations.")
    }
    let output = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "core/src/schema/migrations", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let recorder = StatementRecorder()
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      db.trace(options: .statement) { event in
        if case let .statement(statement) = event { recorder.record(statement.sql) }
      }
    }
    let queue = try DatabaseQueue(configuration: configuration)
    let migrator = WorkspaceStore.migrator
    var manifest: [String] = []
    for identifier in migrator.migrations {
      _ = recorder.drain()
      try migrator.migrate(queue, upTo: identifier)
      let statements = recorder.drain().filter(Self.isSchemaStatement)
      let body = statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + ";" }
        .joined(separator: "\n-- statement\n")
      try ("-- \(identifier), as GRDB runs it on an empty database.\n"
        + "-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.\n"
        + body + "\n")
        .write(to: output.appending(path: "\(identifier).sql"), atomically: true, encoding: .utf8)
      manifest.append(identifier)
    }
    XCTAssertEqual(manifest.count, 20)
  }

  /// GRDB's own bookkeeping and the reads it makes along the way are not part
  /// of the schema; everything that changes the database is.
  private static func isSchemaStatement(_ sql: String) -> Bool {
    let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if head.contains("GRDB_MIGRATIONS") { return false }
    for skipped in ["BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "PRAGMA", "SELECT", "EXPLAIN"]
    where head.hasPrefix(skipped) {
      return false
    }
    return true
  }
}

private final class StatementRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var statements: [String] = []
  func record(_ sql: String) { lock.withLock { statements.append(sql) } }
  func drain() -> [String] {
    lock.withLock {
      defer { statements = [] }
      return statements
    }
  }
}
