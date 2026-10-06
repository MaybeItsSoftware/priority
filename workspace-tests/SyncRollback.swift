import GRDB

extension Database {
  /// Takes `v17_sync` back off a database, and `v18_themes_and_preferences`
  /// and `v19_habit_options` and `v20_waiting_follow_ups` with it since they come later, so a test can rewind to an older schema. Its triggers name every column of the synced tables, so like the
  /// undo journal's they have to come off before a column can be taken away.
  /// Reopening the store runs the migration again.
  func rollBackSyncMigration() throws {
    let triggers = try String.fetchAll(
      self, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync\\_outbox%' ESCAPE '\\'")
    for trigger in triggers { try execute(sql: "DROP TRIGGER \(trigger)") }
    // `v19_habit_options`: the journal's `dailies` triggers name its columns.
    for operation in ["insert", "update", "delete"] {
      try execute(sql: "DROP TRIGGER IF EXISTS change_log_dailies_\(operation)")
    }
    for column in ["sourceTaskId", "placementColumn", "dropsAtDayEnd", "expiryRule", "expiresAt"] {
      try execute(sql: "ALTER TABLE dailies DROP COLUMN \(column)")
    }
    // `v20_waiting_follow_ups`: likewise for `task_metadata`.
    for operation in ["insert", "update", "delete"] {
      try execute(sql: "DROP TRIGGER IF EXISTS change_log_task_metadata_\(operation)")
    }
    for column in ["waitingOn", "waitingFollowUpAt", "waitingFollowUpTaskId", "followUpOfTaskId"] {
      try execute(sql: "ALTER TABLE task_metadata DROP COLUMN \(column)")
    }
    for table in ["sync_outbox", "sync_state", "sync_control", "themes", "preferences"] {
      try execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try execute(
      sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v17_sync', 'v18_themes_and_preferences', 'v19_habit_options', 'v20_waiting_follow_ups')")
  }
}
