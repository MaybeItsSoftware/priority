import Foundation
import SQLite3

// A second connection onto a workspace file, for tests that play another
// process (the CLI, an older build) or look underneath the store. The app
// reads and writes only through the Rust core; GRDB, which these tests used
// to open the file with, is gone (docs/rust-core-migration.md). The shape
// follows GRDB's, so a test reads the same as it did.

public enum TestSQLiteError: Error, CustomStringConvertible {
  case sqlite(code: Int32, message: String)

  public var description: String {
    switch self {
    case let .sqlite(code, message): "SQLite error \(code): \(message)"
    }
  }
}

/// Values a statement binds: what `arguments:` takes.
public struct StatementArguments: ExpressibleByArrayLiteral {
  let values: [Any?]

  public init(_ values: [Any?]) { self.values = values }
  public init(arrayLiteral elements: Any?...) { values = elements }
}

/// One connection, opened with the store's own settings.
public final class DatabaseQueue {
  private let database: Database

  public init(path: String) throws {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard code == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
      sqlite3_close(handle)
      throw TestSQLiteError.sqlite(code: code, message: message)
    }
    sqlite3_busy_timeout(handle, 5_000)
    database = Database(handle)
    try database.execute(sql: "PRAGMA foreign_keys = ON")
  }

  /// Runs `body` inside a deferred transaction.
  public func read<T>(_ body: (Database) throws -> T) throws -> T {
    try database.transaction("BEGIN DEFERRED", body)
  }

  /// Runs `body` inside a write transaction, committed if it returns.
  public func write<T>(_ body: (Database) throws -> T) throws -> T {
    try database.transaction("BEGIN IMMEDIATE", body)
  }
}

/// The connection, inside a transaction.
public final class Database {
  let handle: OpaquePointer

  init(_ handle: OpaquePointer) { self.handle = handle }

  deinit { sqlite3_close_v2(handle) }

  func transaction<T>(_ begin: String, _ body: (Database) throws -> T) throws -> T {
    try execute(sql: begin)
    do {
      let result = try body(self)
      try execute(sql: "COMMIT")
      return result
    } catch {
      try? execute(sql: "ROLLBACK")
      throw error
    }
  }

  /// Runs every statement in `sql`; arguments bind to the last one.
  public func execute(sql: String, arguments: StatementArguments = []) throws {
    if arguments.values.isEmpty {
      var message: UnsafeMutablePointer<CChar>?
      let code = sqlite3_exec(handle, sql, nil, nil, &message)
      if code != SQLITE_OK {
        let text = message.map { String(cString: $0) } ?? ""
        sqlite3_free(message)
        throw TestSQLiteError.sqlite(code: code, message: text)
      }
      return
    }
    _ = try rows(sql: sql, arguments: arguments)
  }

  func rows(sql: String, arguments: StatementArguments) throws -> [Row] {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
    defer { sqlite3_finalize(statement) }
    for (index, value) in arguments.values.enumerated() {
      try bind(value, at: Int32(index + 1), in: statement)
    }
    var result: [Row] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { try check(code); break }
      var columns: [(String, Any?)] = []
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        columns.append((name, value(of: statement, at: column)))
      }
      result.append(Row(columns))
    }
    return result
  }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else {
      throw TestSQLiteError.sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private func bind(_ value: Any?, at index: Int32, in statement: OpaquePointer?) throws {
    let code: Int32
    switch value {
    case nil, is NSNull: code = sqlite3_bind_null(statement, index)
    case let text as String: code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
    case let flag as Bool: code = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
    case let number as Int: code = sqlite3_bind_int64(statement, index, Int64(number))
    case let number as Int64: code = sqlite3_bind_int64(statement, index, number)
    case let number as Int32: code = sqlite3_bind_int64(statement, index, Int64(number))
    case let number as Double: code = sqlite3_bind_double(statement, index, number)
    case let date as Date: code = sqlite3_bind_text(statement, index, Self.stored(date), -1, Self.transient)
    case let optional as Any?:
      if case let .some(wrapped) = optional { return try bind(wrapped, at: index, in: statement) }
      code = sqlite3_bind_null(statement, index)
    default: code = sqlite3_bind_text(statement, index, "\(value!)", -1, Self.transient)
    }
    try check(code)
  }

  private func value(of statement: OpaquePointer?, at column: Int32) -> Any? {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_INTEGER: sqlite3_column_int64(statement, column)
    case SQLITE_FLOAT: sqlite3_column_double(statement, column)
    case SQLITE_TEXT: String(cString: sqlite3_column_text(statement, column))
    case SQLITE_BLOB: Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
    default: nil
    }
  }

  /// A date as the workspace stores one: `yyyy-MM-dd HH:mm:ss.SSS`, UTC.
  public static func stored(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: date)
  }
}

/// One result row, read by column name.
public struct Row {
  private let columns: [(String, Any?)]

  init(_ columns: [(String, Any?)]) { self.columns = columns }

  private func raw(_ name: String) -> Any? { columns.first { $0.0 == name }?.1 ?? nil }

  public subscript(_ name: String) -> String? { raw(name) as? String }
  public subscript(_ name: String) -> Int64? { raw(name) as? Int64 }
  public subscript(_ name: String) -> Int? { (raw(name) as? Int64).map { Int($0) } }
  public subscript(_ name: String) -> Double? { raw(name) as? Double ?? (raw(name) as? Int64).map(Double.init) }
  public subscript(_ name: String) -> Bool? { (raw(name) as? Int64).map { $0 != 0 } }

  /// The first column, whatever it is called.
  var first: Any? { columns.first?.1 ?? nil }

  public static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> [Row] {
    try db.rows(sql: sql, arguments: arguments)
  }
}

extension String {
  public static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> [String] {
    try db.rows(sql: sql, arguments: arguments).compactMap { $0.first as? String }
  }

  public static func fetchOne(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> String? {
    try db.rows(sql: sql, arguments: arguments).first?.first as? String
  }
}

extension Int {
  public static func fetchOne(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> Int? {
    (try db.rows(sql: sql, arguments: arguments).first?.first as? Int64).map { Int($0) }
  }
}
