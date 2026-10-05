import Foundation
import GRDB

/// A user theme as the workspace holds it: the identifier the file resolves
/// to, and the file's text, verbatim.
///
/// The text is not parsed here. Turning it into a theme is `ThemeFileLoader`'s
/// job on Apple platforms and the Kotlin resolver's on Android. The row is what
/// travels between devices, so a theme that one device cannot load still
/// reaches the others intact.
public struct StoredTheme: Equatable, Sendable {
  public var id: String
  public var json: String
  public var updatedAt: Date

  public init(id: String, json: String, updatedAt: Date) {
    self.id = id
    self.json = json
    self.updatedAt = updatedAt
  }
}

/// The synced preference keys the apps share. A key is free text in the
/// table; these are the ones every app reads.
public enum WorkspacePreferenceKey {
  /// The identifier of the chosen theme.
  public static let themeSelected = "theme.selected"
  /// `system`, `light` or `dark`.
  public static let themeAppearance = "theme.appearance"
}

/// The `themes` and `preferences` tables (`v18_themes_and_preferences`).
///
/// Both sync, and neither is journalled for undo: a theme file is edited in
/// a text editor that has its own undo, and a choice of theme is not
/// something anyone means to undo with ⌘Z in a task list.
///
/// Every write is skipped when it would change nothing. A row only syncs when
/// it really changes, so one device saving a file another device has just
/// written cannot send the same text round and round.
extension WorkspaceStore {
  static func createThemeAndPreferenceTables(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE themes (
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        updatedAt DATETIME NOT NULL);
      CREATE TABLE preferences (
        key TEXT PRIMARY KEY,
        value TEXT,
        updatedAt DATETIME NOT NULL);
      """)
  }

  // MARK: - Themes

  /// Every stored theme, by identifier.
  public func themes() throws -> [StoredTheme] {
    try database.read { db in
      try Row.fetchAll(db, sql: "SELECT id, json, updatedAt FROM themes ORDER BY id").map {
        StoredTheme(id: $0["id"], json: $0["json"], updatedAt: $0["updatedAt"])
      }
    }
  }

  /// Stores `json` as the theme `id`. Returns false, and writes nothing, when
  /// the row already holds exactly that text.
  @discardableResult
  public func upsertTheme(id: String, json: String, now: Date = .now) throws -> Bool {
    try database.write { db in
      let current = try String.fetchOne(db, sql: "SELECT json FROM themes WHERE id = ?", arguments: [id])
      if current == json { return false }
      if current == nil {
        try db.execute(
          sql: "INSERT INTO themes (id, json, updatedAt) VALUES (?, ?, ?)", arguments: [id, json, now])
      } else {
        try db.execute(
          sql: "UPDATE themes SET json = ?, updatedAt = ? WHERE id = ?", arguments: [json, now, id])
      }
      return true
    }
  }

  /// Removes the theme `id`. Returns false when there was none.
  @discardableResult
  public func deleteTheme(id: String) throws -> Bool {
    try database.write { db in
      try db.execute(sql: "DELETE FROM themes WHERE id = ?", arguments: [id])
      return db.changesCount > 0
    }
  }

  // MARK: - Preferences

  /// The value stored under `key`, or nil when it is unset or stored as null.
  public func preference(_ key: String) throws -> String? {
    try database.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM preferences WHERE key = ?", arguments: [key])
    }
  }

  /// Every stored preference. A key stored as null has a nil value.
  public func preferences() throws -> [String: String?] {
    try database.read { db in
      var values: [String: String?] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT key, value FROM preferences") {
        values[row["key"]] = row["value"] as String?
      }
      return values
    }
  }

  /// Stores `value` under `key`. A nil value is kept as a row holding null
  /// rather than deleted, so clearing a choice syncs as an edit and a device
  /// that never saw the key can tell "cleared" from "never set". Returns false,
  /// and writes nothing, when the row already holds that value.
  @discardableResult
  public func setPreference(_ key: String, _ value: String?, now: Date = .now) throws -> Bool {
    try database.write { db in
      let existing = try Row.fetchOne(
        db, sql: "SELECT value FROM preferences WHERE key = ?", arguments: [key])
      if let existing {
        if (existing["value"] as String?) == value { return false }
        try db.execute(
          sql: "UPDATE preferences SET value = ?, updatedAt = ? WHERE key = ?",
          arguments: [value, now, key])
      } else {
        try db.execute(
          sql: "INSERT INTO preferences (key, value, updatedAt) VALUES (?, ?, ?)",
          arguments: [key, value, now])
      }
      return true
    }
  }
}
