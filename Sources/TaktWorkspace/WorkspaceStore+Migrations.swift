import Foundation
import GRDB
import TaktCore

// The schema, as the sequence of migrations that produced it. Kept apart from
// the store's methods only for size; a new step goes at the end, and then
// `scripts/dump_workspace_schema.sh` regenerates the fixture the CLI's and
// Android's schema tests are held to (see CLAUDE.md).
extension WorkspaceStore {
  static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_local_workspace") { db in
      try db.create(table: "workspaces") { table in
        table.column("id", .text).primaryKey()
        table.column("name", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "list_folders") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().indexed().references("workspaces", onDelete: .cascade)
        table.column("parentFolderId", .text).indexed().references("list_folders", onDelete: .cascade)
        table.column("name", .text).notNull()
        table.column("sortOrder", .integer).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "task_lists") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().indexed().references("workspaces", onDelete: .cascade)
        table.column("folderId", .text).indexed().references("list_folders", onDelete: .setNull)
        table.column("name", .text).notNull()
        table.column("colorHex", .text)
        table.column("sortOrder", .integer).notNull()
        table.column("isArchived", .boolean).notNull().defaults(to: false)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "tasks") { table in
        table.column("id", .text).primaryKey()
        table.column("listId", .text).notNull().indexed().references("task_lists", onDelete: .cascade)
        table.column("parentTaskId", .text).indexed().references("tasks", onDelete: .cascade)
        table.column("title", .text).notNull()
        table.column("notes", .text).notNull().defaults(to: "")
        table.column("status", .text).notNull().defaults(to: TaskStatus.open.rawValue)
        table.column("sortOrder", .integer).notNull()
        table.column("dueAt", .datetime)
        table.column("estimateSeconds", .integer)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
    }
    migrator.registerMigration("v2_metadata_and_focus") { db in
      try db.create(table: "task_metadata") { table in
        table.column("taskId", .text).primaryKey().references("tasks", onDelete: .cascade)
        table.column("priority", .integer)
        table.column("startAt", .datetime)
        table.column("tagsJSON", .text).notNull().defaults(to: "[]")
        table.column("recurrenceRule", .text)
        table.column("matrixUrgency", .integer)
        table.column("matrixImportance", .integer)
        table.column("kanbanColumn", .text)
        table.column("externalLinksJSON", .text).notNull().defaults(to: "[]")
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "focus_sessions") { table in
        table.column("id", .text).primaryKey()
        table.column("startedAt", .datetime).notNull().indexed()
        table.column("endedAt", .datetime)
        table.column("phase", .text).notNull()
        table.column("activeTaskId", .text).references("tasks", onDelete: .setNull)
        table.column("workDurationSeconds", .integer).notNull()
        table.column("breakDurationSeconds", .integer).notNull()
        table.column("breakEndsAt", .datetime)
      }
      try db.create(table: "focus_queue_items") { table in
        table.column("id", .text).primaryKey()
        table.column("sessionId", .text).notNull().indexed().references("focus_sessions", onDelete: .cascade)
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("sortOrder", .integer).notNull()
        table.column("state", .text).notNull().defaults(to: FocusQueueState.queued.rawValue)
        table.column("completedAt", .datetime)
        table.column("skippedAt", .datetime)
        table.column("createdAt", .datetime).notNull()
      }
    }
    migrator.registerMigration("v3_dailies_as_contributions") { db in
      try db.create(table: "dailies") { table in
        table.column("id", .text).primaryKey()
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("activeWeekdaysMask", .integer).notNull().defaults(to: WorkspaceDaily.allWeekdaysMask)
        table.column("intervalDays", .integer)
        table.column("intervalAnchor", .datetime)
        table.column("targetSeconds", .integer)
        table.column("sortOrder", .integer).notNull()
        table.column("archivedAt", .datetime)
        // The id of the plugin-era daily this came from, so the one-time
        // import can run again without producing a second copy.
        table.column("legacyDailyId", .text).unique()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "daily_contributions") { table in
        table.column("id", .text).primaryKey()
        table.column("dailyId", .text).notNull().indexed().references("dailies", onDelete: .cascade)
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("dayKey", .text).notNull()
        table.column("secondsLogged", .integer).notNull().defaults(to: 0)
        table.column("completedAt", .datetime)
        table.column("createdAt", .datetime).notNull()
        // One row per daily per day: a contribution accumulates into the
        // existing row rather than appending a second one.
        table.uniqueKey(["dailyId", "dayKey"])
      }
      // The estimate the focus screen was started with, which is not the task's
      // standing estimate — "this sitting" and "this job" are different numbers.
      try db.alter(table: "focus_queue_items") { table in
        table.add(column: "plannedSeconds", .integer)
      }
    }
    migrator.registerMigration("v4_manual_focus_order") { db in
      // A hand-placed position in the focus ladder. Null means "not arranged by
      // hand" — those tasks keep following the ranking underneath.
      try db.alter(table: "task_metadata") { table in
        table.add(column: "focusRank", .integer)
      }
    }
    migrator.registerMigration("v5_task_source_identity") { db in
      // Immutable once written: what an outside service calls this task. The
      // pair is what makes a second import run a merge rather than a copy.
      try db.alter(table: "tasks") { table in
        table.add(column: "sourceSystem", .text)
        table.add(column: "sourceId", .text)
      }
      // Partial, so the many locally created tasks — all of which have a null
      // sourceId — do not collide with each other in the index.
      try db.execute(sql: """
        CREATE UNIQUE INDEX tasks_on_source
        ON tasks(sourceSystem, sourceId) WHERE sourceId IS NOT NULL
        """)
    }
    migrator.registerMigration("v6_inbox_as_a_system_list") { db in
      try db.alter(table: "task_lists") { table in
        table.add(column: "systemRole", .text)
      }
      // Claim the list that has been acting as the inbox rather than adding a
      // second one beside it. Oldest wins, so a user who made their own list
      // called Inbox later keeps it as an ordinary list.
      try db.execute(sql: """
        UPDATE task_lists SET systemRole = 'inbox' WHERE id IN (
          SELECT id FROM task_lists AS candidate
          WHERE lower(candidate.name) = 'inbox'
            AND candidate.createdAt = (
              SELECT MIN(earliest.createdAt) FROM task_lists AS earliest
              WHERE lower(earliest.name) = 'inbox' AND earliest.workspaceId = candidate.workspaceId
            )
          GROUP BY candidate.workspaceId
        )
        """)
      try db.execute(sql: """
        CREATE UNIQUE INDEX task_lists_on_system_role
        ON task_lists(workspaceId, systemRole) WHERE systemRole IS NOT NULL
        """)
    }
    migrator.registerMigration("v7_task_full_text_search") { db in
      // External-content FTS5: the index stores no task text of its own, and
      // `synchronize` writes the triggers that keep it level with the tasks
      // table, so no mutation path has to remember to update the index.
      try db.create(virtualTable: "tasks_fts", using: FTS5()) { table in
        table.synchronize(withTable: "tasks")
        table.column("title")
        table.column("notes")
        // Porter over unicode61, so "meeting" finds "meetings" and a search
        // for "cafe" finds "café".
        table.tokenizer = .porter(wrapping: .unicode61())
      }
    }
    migrator.registerMigration("v8_undo_journal") { db in
      try db.create(table: "undo_control") { table in
        table.column("id", .integer).primaryKey()
        // The step any recorded change belongs to, set by `journalledWrite`.
        table.column("groupId", .text)
        table.column("label", .text)
        // Recording is off unless a journalled write turns it on, so imports
        // and migrations do not arrive as thousands of undo steps.
        table.column("suppressed", .integer).notNull().defaults(to: 1)
      }
      try db.execute(sql: "INSERT INTO undo_control (id, suppressed) VALUES (0, 1)")
      try db.create(table: "change_log") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("groupId", .text).indexed()
        table.column("label", .text)
        table.column("tableName", .text).notNull()
        table.column("rowId", .text).notNull()
        table.column("operation", .text).notNull()
        table.column("beforeJSON", .text)
        table.column("afterJSON", .text)
        table.column("undone", .boolean).notNull().defaults(to: false)
      }
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v9_focus_block_start") { db in
      try db.alter(table: "focus_sessions") { table in
        // The default exists only because SQLite needs one to add a NOT NULL
        // column to a table with rows in it; every existing row is overwritten
        // on the next line, and every new row carries its own value.
        table.add(column: "activeTaskStartedAt", .datetime)
          .notNull().defaults(to: Date(timeIntervalSince1970: 0))
      }
      // Existing sessions only ever had one clock, so the session's start is
      // the truest answer available for the block that was running.
      try db.execute(sql: "UPDATE focus_sessions SET activeTaskStartedAt = startedAt")
    }
    migrator.registerMigration("v10_focus_points") { db in
      try db.create(table: "focus_awards") { table in
        table.column("id", .text).primaryKey()
        // Both references let go rather than cascade: deleting a task or
        // clearing out old sessions must not take the score with it.
        table.column("sessionId", .text).references("focus_sessions", onDelete: .setNull)
        table.column("taskId", .text).references("tasks", onDelete: .setNull)
        table.column("taskTitle", .text).notNull()
        table.column("seconds", .integer).notNull()
        table.column("minutes", .double).notNull()
        table.column("multiplier", .double).notNull()
        table.column("points", .double).notNull()
        table.column("awardedAt", .datetime).notNull().indexed()
      }
    }
    migrator.registerMigration("v11_stable_visible_roots") { db in
      // Nullable for older undo snapshots, which predate this column.
      try db.alter(table: "task_lists") { table in
        table.add(column: "visibleRootTaskId", .text).references("tasks", onDelete: .setNull)
      }
      for list in try TaskList.fetchAll(db) {
        try WorkspaceStore.registerVisibleRoot(db, for: list)
      }
      // Carry the inferred identity into pre-upgrade list snapshots as well,
      // so undoing an old colour/name edit does not unhide its wrapper.
      try db.execute(sql: """
        UPDATE change_log SET
          beforeJSON = CASE WHEN beforeJSON IS NULL THEN NULL ELSE
            json_set(beforeJSON, '$.visibleRootTaskId',
              (SELECT visibleRootTaskId FROM task_lists WHERE id = change_log.rowId)) END,
          afterJSON = CASE WHEN afterJSON IS NULL THEN NULL ELSE
            json_set(afterJSON, '$.visibleRootTaskId',
              (SELECT visibleRootTaskId FROM task_lists WHERE id = change_log.rowId)) END
        WHERE tableName = 'task_lists'
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v12_task_conditions_and_work") { db in
      try db.create(table: "task_conditions") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().references("workspaces", onDelete: .cascade)
        table.column("name", .text).notNull()
        table.column("isLocation", .boolean).notNull().defaults(to: false)
        table.column("isArchived", .boolean).notNull().defaults(to: false)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      for workspace in try Workspace.fetchAll(db) {
        try WorkspaceStore.seedConditions(db, workspaceId: workspace.id, now: .now)
      }
      try db.alter(table: "task_metadata") { table in table.add(column: "planningJSON", .text) }
      try db.alter(table: "focus_sessions") { table in
        table.add(column: "activeBlockId", .text)
        table.add(column: "accumulatedSeconds", .integer)
        table.add(column: "pausedAt", .datetime)
        table.add(column: "checkpointAt", .datetime)
      }
      try db.create(table: "focus_work_blocks") { table in
        table.column("id", .text).primaryKey()
        table.column("sessionId", .text).references("focus_sessions", onDelete: .setNull)
        table.column("taskId", .text).indexed().references("tasks", onDelete: .setNull)
        table.column("taskTitle", .text).notNull()
        table.column("seconds", .integer).notNull()
        table.column("recordedAt", .datetime).notNull()
        table.column("originalTaskId", .text).indexed()
      }
      try db.execute(sql: """
        INSERT INTO focus_work_blocks(id, sessionId, taskId, taskTitle, seconds, recordedAt, originalTaskId)
        SELECT 'legacy-' || id, sessionId, taskId, taskTitle, seconds, awardedAt, taskId FROM focus_awards
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v13_legacy_visible_roots") { db in
      // Early bulk imports predate source identity. Recognise only matching
      // wrappers created in the same batch as their list and children.
      for var list in try TaskList.fetchAll(db) where list.visibleRootTaskId == nil {
        let roots = try WorkspaceTask
          .filter(Column("listId") == list.id && Column("parentTaskId") == nil).fetchAll(db)
        guard roots.count == 1, let root = roots.first,
          root.sourceSystem == nil, root.createdAt == list.createdAt,
          !normalizedVisibleRootName(list.name).isEmpty,
          normalizedVisibleRootName(root.title) == normalizedVisibleRootName(list.name),
          try WorkspaceTask.filter(Column("parentTaskId") == root.id
            && Column("createdAt") == list.createdAt).fetchCount(db) > 0
        else { continue }
        list.visibleRootTaskId = root.id
        try list.update(db)
      }
    }
    migrator.registerMigration("v14_nested_lists") { db in
      try db.alter(table: "tasks") { table in
        table.add(column: "itemKind", .text)
        table.add(column: "isPromoted", .boolean)
        table.add(column: "archivedAt", .datetime)
      }
      try db.alter(table: "task_lists") { table in
        table.add(column: "completedAt", .datetime)
      }
      // Nullable additions also keep pre-migration undo snapshots valid.
      try installChangeLogTriggers(db)
    }
    migrator.registerMigration("v15_kanban_board_history") { db in
      try db.create(table: "kanban_boards") { table in
        table.column("id", .text).primaryKey()
        table.column("columnsJSON", .text).notNull()
      }
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v16_task_completion_time") { db in
      try db.alter(table: "tasks") { table in
        table.add(column: "completedAt", .datetime)
      }
      // Existing rows only know when they were last touched. For a task that
      // is already closed that is the closest thing to a completion date the
      // schema ever recorded, so it is backfilled rather than left null —
      // a week's history that starts empty would read as a week of no work.
      try db.execute(sql: """
        UPDATE tasks SET completedAt = updatedAt
        WHERE status = 'completed' AND completedAt IS NULL
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v17_sync") { db in
      try WorkspaceStore.createSyncTables(db)
      try WorkspaceStore.installSyncTriggers(db)
    }
    migrator.registerMigration("v18_themes_and_preferences") { db in
      // Synced, so the outbox triggers are reinstalled to cover them. Not
      // journalled for undo, so `installChangeLogTriggers` is not.
      try WorkspaceStore.createThemeAndPreferenceTables(db)
      try WorkspaceStore.installSyncTriggers(db)
    }
    migrator.registerMigration("v19_habit_options") { db in
      // Raw SQL, not `db.alter`, so the Android and CLI copies can run the
      // very same statements: the schema test compares the resulting SQL text.
      for statement in WorkspaceStore.habitOptionColumns {
        try db.execute(sql: statement)
      }
      // `dailies` is both journalled and synced, and both trigger sets list
      // its columns by name.
      try WorkspaceStore.installChangeLogTriggers(db)
      try WorkspaceStore.installSyncTriggers(db)
    }
    migrator.registerMigration("v20_waiting_follow_ups") { db in
      // Raw SQL for the same reason as v19: Android runs these statements too.
      for statement in WorkspaceStore.waitingColumns {
        try db.execute(sql: statement)
      }
      // `task_metadata` is journalled and synced; both trigger sets name its
      // columns.
      try WorkspaceStore.installChangeLogTriggers(db)
      try WorkspaceStore.installSyncTriggers(db)
    }

    return migrator
  }()
}
