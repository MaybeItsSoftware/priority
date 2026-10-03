import GRDB

extension Database {
  /// Takes `v17_sync` back off a database, and `v18_themes_and_preferences`
  /// with it since it comes later, so a test can rewind to an older schema. Its triggers name every column of the synced tables, so like the
  /// undo journal's they have to come off before a column can be taken away.
  /// Reopening the store runs the migration again.
  func rollBackSyncMigration() throws {
    let triggers = try String.fetchAll(
      self, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync\\_outbox%' ESCAPE '\\'")
    for trigger in triggers { try execute(sql: "DROP TRIGGER \(trigger)") }
    for table in ["sync_outbox", "sync_state", "sync_control", "themes", "preferences"] {
      try execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try execute(
      sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v17_sync', 'v18_themes_and_preferences')")
  }
}
