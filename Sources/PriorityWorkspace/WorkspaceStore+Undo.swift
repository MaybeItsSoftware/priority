import Foundation
import GRDB

/// Taking back the last thing you did. Split from `WorkspaceStore.swift` — the
/// same type — because it is a mechanism rather than a feature: nothing else in
/// the store knows it exists.
///
/// Rather than every mutation declaring its own inverse — which is one more
/// thing to get wrong each time a mutation is added — the database records what
/// changed. Triggers on the tables that hold the user's work write the row
/// before and after each insert, update and delete into `change_log`, and undo
/// replays those entries backwards. A mutation added later is covered the day
/// it is written, provided its write goes through `journalledWrite`.
///
/// Focus sessions and the focus queue are deliberately not journalled. A timer
/// is a record of what happened, not an edit to take back, and undoing your way
/// into a half-finished session would be a strange thing to offer.
extension WorkspaceStore {
  /// The tables whose rows are the user's work, and the column each is keyed by.
  static let journalledTables: KeyValuePairs<String, String> = [
    "task_lists": "id",
    "list_folders": "id",
    "tasks": "id",
    "task_metadata": "taskId",
    "dailies": "id",
    "daily_contributions": "id",
  ]

  /// What undo would take back, phrased for a menu item. Nil when there is
  /// nothing to undo.
  public func undoableLabel() throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT label FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1")
    }
  }

  public func redoableLabel() throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT label FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1")
    }
  }

  /// Reverses the most recent group of changes. Returns its label, or nil when
  /// there was nothing to undo.
  @discardableResult
  public func undo() throws -> String? {
    try database.write { db in
      guard let group = try Row.fetchOne(
        db, sql: "SELECT groupId, label FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1")
      else { return nil }
      let groupID: String = group["groupId"]
      let entries = try Row.fetchAll(
        db, sql: "SELECT * FROM change_log WHERE groupId = ? ORDER BY id DESC", arguments: [groupID])
      try Self.replay(entries, reversed: true, in: db)
      try db.execute(sql: "UPDATE change_log SET undone = 1 WHERE groupId = ?", arguments: [groupID])
      return group["label"]
    }
  }

  @discardableResult
  public func redo() throws -> String? {
    try database.write { db in
      guard let group = try Row.fetchOne(
        db, sql: "SELECT groupId, label FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1")
      else { return nil }
      let groupID: String = group["groupId"]
      let entries = try Row.fetchAll(
        db, sql: "SELECT * FROM change_log WHERE groupId = ? ORDER BY id ASC", arguments: [groupID])
      try Self.replay(entries, reversed: false, in: db)
      try db.execute(sql: "UPDATE change_log SET undone = 0 WHERE groupId = ?", arguments: [groupID])
      return group["label"]
    }
  }

  /// Runs a mutation as one undoable step.
  ///
  /// The label is what the user will be offered back, so it names the action
  /// rather than the table. Every write that touches a journalled table goes
  /// through here: a write that does not would be recorded against whichever
  /// step ran before it, and undoing that step would take back both.
  func journalledWrite<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
    try database.write { db in
      // A fresh edit is a new branch of history: what was undone can no longer
      // be redone, exactly as in a text editor.
      try db.execute(sql: "DELETE FROM change_log WHERE undone = 1")
      // Recording is off by default, so a write that has not opted in — a
      // migration, an import, the focus tables — is not an undo step. It is
      // switched on here and off again below, inside the one transaction.
      try db.execute(
        sql: "UPDATE undo_control SET groupId = ?, label = ?, suppressed = 0 WHERE id = 0",
        arguments: [UUID().uuidString, label])
      defer { try? db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0") }
      let result = try block(db)
      try db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0")
      try Self.trimJournal(db)
      return result
    }
  }

  private static func replay(_ entries: [Row], reversed: Bool, in db: Database) throws {
    // Recording is already off outside a journalled write; set explicitly so a
    // replay can never record undoing as another thing to undo.
    try db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0")
    // A subtree comes back parent-first or child-first depending on the order
    // its rows were deleted in, and either way one end of it briefly points at
    // a row that is not there yet.
    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

    for entry in entries {
      let table: String = entry["tableName"]
      let key: String = entry["rowId"]
      let operation: String = entry["operation"]
      let before: String? = entry["beforeJSON"]
      let after: String? = entry["afterJSON"]
      guard let keyColumn = journalledTables.first(where: { $0.key == table })?.value else { continue }

      switch (operation, reversed) {
      case ("insert", true), ("delete", false):
        try db.execute(sql: "DELETE FROM \(table) WHERE \(keyColumn) = ?", arguments: [key])
      case ("delete", true), ("insert", false):
        guard let json = reversed ? before : after else { continue }
        try insertRow(json, into: table, db: db)
      case ("update", _):
        guard let json = reversed ? before : after else { continue }
        try updateRow(json, in: table, key: key, keyColumn: keyColumn, db: db)
      default:
        continue
      }
    }
  }

  /// Puts a deleted row back, exactly as it was.
  private static func insertRow(_ json: String, into table: String, db: Database) throws {
    let columns = try db.columns(in: table).map(\.name)
    let values = columns.map { "json_extract(?, '$.\($0)')" }.joined(separator: ", ")
    try db.execute(
      sql: """
        INSERT INTO \(table) (\(columns.map { "\"\($0)\"" }.joined(separator: ", ")))
        VALUES (\(values))
        """,
      arguments: StatementArguments(Array(repeating: json, count: columns.count)))
  }

  /// Returns an existing row to a recorded state.
  ///
  /// An UPDATE rather than INSERT OR REPLACE: replacing a row deletes it first,
  /// and a delete cascades, so putting back a task's old title would take its
  /// subtree with it.
  private static func updateRow(
    _ json: String, in table: String, key: String, keyColumn: String, db: Database
  ) throws {
    let columns = try db.columns(in: table).map(\.name)
    let assignments = columns.map { "\"\($0)\" = json_extract(?, '$.\($0)')" }.joined(separator: ", ")
    var arguments = Array(repeating: json, count: columns.count)
    arguments.append(key)
    try db.execute(
      sql: "UPDATE \(table) SET \(assignments) WHERE \"\(keyColumn)\" = ?",
      arguments: StatementArguments(arguments))
  }

  /// Keeps the journal to a working depth rather than a complete history. Whole
  /// groups only: half an undo step is worse than none.
  private static func trimJournal(_ db: Database) throws {
    try db.execute(sql: """
      DELETE FROM change_log WHERE groupId IN (
        SELECT groupId FROM change_log GROUP BY groupId
        ORDER BY MAX(id) DESC LIMIT -1 OFFSET \(journalDepth)
      )
      """)
  }

  private static let journalDepth = 100

  /// Writes the recording triggers. Called by the migration that creates the
  /// journal, and again by any later migration that adds or removes a column on
  /// a journalled table — a trigger names its columns, so a schema change
  /// leaves it recording the old shape.
  static func installChangeLogTriggers(_ db: Database) throws {
    for (table, keyColumn) in journalledTables {
      let columns = try db.columns(in: table).map(\.name)
      func json(_ prefix: String) -> String {
        "json_object(" + columns.map { "'\($0)', \(prefix).\"\($0)\"" }.joined(separator: ", ") + ")"
      }
      // Recording is off while an undo is replaying, and off entirely until a
      // journalled write turns it on, so an import or a migration does not
      // arrive as thousands of undo steps.
      let guardClause = "WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0"
      let entry = "INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON)"
      let context = "(SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0)"

      for suffix in ["insert", "update", "delete"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS change_log_\(table)_\(suffix)")
      }
      try db.execute(sql: """
        CREATE TRIGGER change_log_\(table)_insert AFTER INSERT ON \(table) \(guardClause)
        BEGIN
          \(entry) VALUES (\(context), '\(table)', NEW."\(keyColumn)", 'insert', NULL, \(json("NEW")));
        END
        """)
      try db.execute(sql: """
        CREATE TRIGGER change_log_\(table)_update AFTER UPDATE ON \(table) \(guardClause)
        BEGIN
          \(entry) VALUES (\(context), '\(table)', NEW."\(keyColumn)", 'update', \(json("OLD")), \(json("NEW")));
        END
        """)
      try db.execute(sql: """
        CREATE TRIGGER change_log_\(table)_delete AFTER DELETE ON \(table) \(guardClause)
        BEGIN
          \(entry) VALUES (\(context), '\(table)', OLD."\(keyColumn)", 'delete', \(json("OLD")), NULL);
        END
        """)
    }
  }
}
