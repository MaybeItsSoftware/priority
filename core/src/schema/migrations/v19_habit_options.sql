-- v19_habit_options, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE dailies ADD COLUMN sourceTaskId TEXT;
-- statement
ALTER TABLE dailies ADD COLUMN placementColumn TEXT;
-- statement
ALTER TABLE dailies ADD COLUMN dropsAtDayEnd BOOLEAN NOT NULL DEFAULT 1;
-- statement
ALTER TABLE dailies ADD COLUMN expiryRule TEXT NOT NULL DEFAULT 'never';
-- statement
ALTER TABLE dailies ADD COLUMN expiresAt DATETIME;
-- statement
DROP TRIGGER IF EXISTS change_log_task_lists_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_task_lists_update;
-- statement
DROP TRIGGER IF EXISTS change_log_task_lists_delete;
-- statement
CREATE TRIGGER change_log_task_lists_insert AFTER INSERT ON task_lists WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_lists', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'folderId', NEW."folderId", 'name', NEW."name", 'colorHex', NEW."colorHex", 'sortOrder', NEW."sortOrder", 'isArchived', NEW."isArchived", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'systemRole', NEW."systemRole", 'visibleRootTaskId', NEW."visibleRootTaskId", 'completedAt', NEW."completedAt"));
END;
-- statement
CREATE TRIGGER change_log_task_lists_update AFTER UPDATE ON task_lists WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_lists', NEW."id", 'update', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'folderId', OLD."folderId", 'name', OLD."name", 'colorHex', OLD."colorHex", 'sortOrder', OLD."sortOrder", 'isArchived', OLD."isArchived", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'systemRole', OLD."systemRole", 'visibleRootTaskId', OLD."visibleRootTaskId", 'completedAt', OLD."completedAt"), json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'folderId', NEW."folderId", 'name', NEW."name", 'colorHex', NEW."colorHex", 'sortOrder', NEW."sortOrder", 'isArchived', NEW."isArchived", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'systemRole', NEW."systemRole", 'visibleRootTaskId', NEW."visibleRootTaskId", 'completedAt', NEW."completedAt"));
END;
-- statement
CREATE TRIGGER change_log_task_lists_delete AFTER DELETE ON task_lists WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_lists', OLD."id", 'delete', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'folderId', OLD."folderId", 'name', OLD."name", 'colorHex', OLD."colorHex", 'sortOrder', OLD."sortOrder", 'isArchived', OLD."isArchived", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'systemRole', OLD."systemRole", 'visibleRootTaskId', OLD."visibleRootTaskId", 'completedAt', OLD."completedAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_list_folders_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_list_folders_update;
-- statement
DROP TRIGGER IF EXISTS change_log_list_folders_delete;
-- statement
CREATE TRIGGER change_log_list_folders_insert AFTER INSERT ON list_folders WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'list_folders', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'parentFolderId', NEW."parentFolderId", 'name', NEW."name", 'sortOrder', NEW."sortOrder", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_list_folders_update AFTER UPDATE ON list_folders WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'list_folders', NEW."id", 'update', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'parentFolderId', OLD."parentFolderId", 'name', OLD."name", 'sortOrder', OLD."sortOrder", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'parentFolderId', NEW."parentFolderId", 'name', NEW."name", 'sortOrder', NEW."sortOrder", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_list_folders_delete AFTER DELETE ON list_folders WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'list_folders', OLD."id", 'delete', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'parentFolderId', OLD."parentFolderId", 'name', OLD."name", 'sortOrder', OLD."sortOrder", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_tasks_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_tasks_update;
-- statement
DROP TRIGGER IF EXISTS change_log_tasks_delete;
-- statement
CREATE TRIGGER change_log_tasks_insert AFTER INSERT ON tasks WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'listId', NEW."listId", 'parentTaskId', NEW."parentTaskId", 'title', NEW."title", 'notes', NEW."notes", 'status', NEW."status", 'sortOrder', NEW."sortOrder", 'dueAt', NEW."dueAt", 'estimateSeconds', NEW."estimateSeconds", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceSystem', NEW."sourceSystem", 'sourceId', NEW."sourceId", 'itemKind', NEW."itemKind", 'isPromoted', NEW."isPromoted", 'archivedAt', NEW."archivedAt", 'completedAt', NEW."completedAt"));
END;
-- statement
CREATE TRIGGER change_log_tasks_update AFTER UPDATE ON tasks WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', NEW."id", 'update', json_object('id', OLD."id", 'listId', OLD."listId", 'parentTaskId', OLD."parentTaskId", 'title', OLD."title", 'notes', OLD."notes", 'status', OLD."status", 'sortOrder', OLD."sortOrder", 'dueAt', OLD."dueAt", 'estimateSeconds', OLD."estimateSeconds", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceSystem', OLD."sourceSystem", 'sourceId', OLD."sourceId", 'itemKind', OLD."itemKind", 'isPromoted', OLD."isPromoted", 'archivedAt', OLD."archivedAt", 'completedAt', OLD."completedAt"), json_object('id', NEW."id", 'listId', NEW."listId", 'parentTaskId', NEW."parentTaskId", 'title', NEW."title", 'notes', NEW."notes", 'status', NEW."status", 'sortOrder', NEW."sortOrder", 'dueAt', NEW."dueAt", 'estimateSeconds', NEW."estimateSeconds", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceSystem', NEW."sourceSystem", 'sourceId', NEW."sourceId", 'itemKind', NEW."itemKind", 'isPromoted', NEW."isPromoted", 'archivedAt', NEW."archivedAt", 'completedAt', NEW."completedAt"));
END;
-- statement
CREATE TRIGGER change_log_tasks_delete AFTER DELETE ON tasks WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', OLD."id", 'delete', json_object('id', OLD."id", 'listId', OLD."listId", 'parentTaskId', OLD."parentTaskId", 'title', OLD."title", 'notes', OLD."notes", 'status', OLD."status", 'sortOrder', OLD."sortOrder", 'dueAt', OLD."dueAt", 'estimateSeconds', OLD."estimateSeconds", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceSystem', OLD."sourceSystem", 'sourceId', OLD."sourceId", 'itemKind', OLD."itemKind", 'isPromoted', OLD."isPromoted", 'archivedAt', OLD."archivedAt", 'completedAt', OLD."completedAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_task_metadata_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_task_metadata_update;
-- statement
DROP TRIGGER IF EXISTS change_log_task_metadata_delete;
-- statement
CREATE TRIGGER change_log_task_metadata_insert AFTER INSERT ON task_metadata WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_metadata', NEW."taskId", 'insert', NULL, json_object('taskId', NEW."taskId", 'priority', NEW."priority", 'startAt', NEW."startAt", 'tagsJSON', NEW."tagsJSON", 'recurrenceRule', NEW."recurrenceRule", 'matrixUrgency', NEW."matrixUrgency", 'matrixImportance', NEW."matrixImportance", 'kanbanColumn', NEW."kanbanColumn", 'externalLinksJSON', NEW."externalLinksJSON", 'updatedAt', NEW."updatedAt", 'focusRank', NEW."focusRank", 'planningJSON', NEW."planningJSON"));
END;
-- statement
CREATE TRIGGER change_log_task_metadata_update AFTER UPDATE ON task_metadata WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_metadata', NEW."taskId", 'update', json_object('taskId', OLD."taskId", 'priority', OLD."priority", 'startAt', OLD."startAt", 'tagsJSON', OLD."tagsJSON", 'recurrenceRule', OLD."recurrenceRule", 'matrixUrgency', OLD."matrixUrgency", 'matrixImportance', OLD."matrixImportance", 'kanbanColumn', OLD."kanbanColumn", 'externalLinksJSON', OLD."externalLinksJSON", 'updatedAt', OLD."updatedAt", 'focusRank', OLD."focusRank", 'planningJSON', OLD."planningJSON"), json_object('taskId', NEW."taskId", 'priority', NEW."priority", 'startAt', NEW."startAt", 'tagsJSON', NEW."tagsJSON", 'recurrenceRule', NEW."recurrenceRule", 'matrixUrgency', NEW."matrixUrgency", 'matrixImportance', NEW."matrixImportance", 'kanbanColumn', NEW."kanbanColumn", 'externalLinksJSON', NEW."externalLinksJSON", 'updatedAt', NEW."updatedAt", 'focusRank', NEW."focusRank", 'planningJSON', NEW."planningJSON"));
END;
-- statement
CREATE TRIGGER change_log_task_metadata_delete AFTER DELETE ON task_metadata WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_metadata', OLD."taskId", 'delete', json_object('taskId', OLD."taskId", 'priority', OLD."priority", 'startAt', OLD."startAt", 'tagsJSON', OLD."tagsJSON", 'recurrenceRule', OLD."recurrenceRule", 'matrixUrgency', OLD."matrixUrgency", 'matrixImportance', OLD."matrixImportance", 'kanbanColumn', OLD."kanbanColumn", 'externalLinksJSON', OLD."externalLinksJSON", 'updatedAt', OLD."updatedAt", 'focusRank', OLD."focusRank", 'planningJSON', OLD."planningJSON"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_task_conditions_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_task_conditions_update;
-- statement
DROP TRIGGER IF EXISTS change_log_task_conditions_delete;
-- statement
CREATE TRIGGER change_log_task_conditions_insert AFTER INSERT ON task_conditions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_conditions', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'name', NEW."name", 'isLocation', NEW."isLocation", 'isArchived', NEW."isArchived", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_task_conditions_update AFTER UPDATE ON task_conditions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_conditions', NEW."id", 'update', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'name', OLD."name", 'isLocation', OLD."isLocation", 'isArchived', OLD."isArchived", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), json_object('id', NEW."id", 'workspaceId', NEW."workspaceId", 'name', NEW."name", 'isLocation', NEW."isLocation", 'isArchived', NEW."isArchived", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_task_conditions_delete AFTER DELETE ON task_conditions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'task_conditions', OLD."id", 'delete', json_object('id', OLD."id", 'workspaceId', OLD."workspaceId", 'name', OLD."name", 'isLocation', OLD."isLocation", 'isArchived', OLD."isArchived", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_dailies_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_dailies_update;
-- statement
DROP TRIGGER IF EXISTS change_log_dailies_delete;
-- statement
CREATE TRIGGER change_log_dailies_insert AFTER INSERT ON dailies WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'taskId', NEW."taskId", 'activeWeekdaysMask', NEW."activeWeekdaysMask", 'intervalDays', NEW."intervalDays", 'intervalAnchor', NEW."intervalAnchor", 'targetSeconds', NEW."targetSeconds", 'sortOrder', NEW."sortOrder", 'archivedAt', NEW."archivedAt", 'legacyDailyId', NEW."legacyDailyId", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceTaskId', NEW."sourceTaskId", 'placementColumn', NEW."placementColumn", 'dropsAtDayEnd', NEW."dropsAtDayEnd", 'expiryRule', NEW."expiryRule", 'expiresAt', NEW."expiresAt"));
END;
-- statement
CREATE TRIGGER change_log_dailies_update AFTER UPDATE ON dailies WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', NEW."id", 'update', json_object('id', OLD."id", 'taskId', OLD."taskId", 'activeWeekdaysMask', OLD."activeWeekdaysMask", 'intervalDays', OLD."intervalDays", 'intervalAnchor', OLD."intervalAnchor", 'targetSeconds', OLD."targetSeconds", 'sortOrder', OLD."sortOrder", 'archivedAt', OLD."archivedAt", 'legacyDailyId', OLD."legacyDailyId", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceTaskId', OLD."sourceTaskId", 'placementColumn', OLD."placementColumn", 'dropsAtDayEnd', OLD."dropsAtDayEnd", 'expiryRule', OLD."expiryRule", 'expiresAt', OLD."expiresAt"), json_object('id', NEW."id", 'taskId', NEW."taskId", 'activeWeekdaysMask', NEW."activeWeekdaysMask", 'intervalDays', NEW."intervalDays", 'intervalAnchor', NEW."intervalAnchor", 'targetSeconds', NEW."targetSeconds", 'sortOrder', NEW."sortOrder", 'archivedAt', NEW."archivedAt", 'legacyDailyId', NEW."legacyDailyId", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceTaskId', NEW."sourceTaskId", 'placementColumn', NEW."placementColumn", 'dropsAtDayEnd', NEW."dropsAtDayEnd", 'expiryRule', NEW."expiryRule", 'expiresAt', NEW."expiresAt"));
END;
-- statement
CREATE TRIGGER change_log_dailies_delete AFTER DELETE ON dailies WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', OLD."id", 'delete', json_object('id', OLD."id", 'taskId', OLD."taskId", 'activeWeekdaysMask', OLD."activeWeekdaysMask", 'intervalDays', OLD."intervalDays", 'intervalAnchor', OLD."intervalAnchor", 'targetSeconds', OLD."targetSeconds", 'sortOrder', OLD."sortOrder", 'archivedAt', OLD."archivedAt", 'legacyDailyId', OLD."legacyDailyId", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceTaskId', OLD."sourceTaskId", 'placementColumn', OLD."placementColumn", 'dropsAtDayEnd', OLD."dropsAtDayEnd", 'expiryRule', OLD."expiryRule", 'expiresAt', OLD."expiresAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_daily_contributions_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_daily_contributions_update;
-- statement
DROP TRIGGER IF EXISTS change_log_daily_contributions_delete;
-- statement
CREATE TRIGGER change_log_daily_contributions_insert AFTER INSERT ON daily_contributions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'daily_contributions', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'dailyId', NEW."dailyId", 'taskId', NEW."taskId", 'dayKey', NEW."dayKey", 'secondsLogged', NEW."secondsLogged", 'completedAt', NEW."completedAt", 'createdAt', NEW."createdAt"));
END;
-- statement
CREATE TRIGGER change_log_daily_contributions_update AFTER UPDATE ON daily_contributions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'daily_contributions', NEW."id", 'update', json_object('id', OLD."id", 'dailyId', OLD."dailyId", 'taskId', OLD."taskId", 'dayKey', OLD."dayKey", 'secondsLogged', OLD."secondsLogged", 'completedAt', OLD."completedAt", 'createdAt', OLD."createdAt"), json_object('id', NEW."id", 'dailyId', NEW."dailyId", 'taskId', NEW."taskId", 'dayKey', NEW."dayKey", 'secondsLogged', NEW."secondsLogged", 'completedAt', NEW."completedAt", 'createdAt', NEW."createdAt"));
END;
-- statement
CREATE TRIGGER change_log_daily_contributions_delete AFTER DELETE ON daily_contributions WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'daily_contributions', OLD."id", 'delete', json_object('id', OLD."id", 'dailyId', OLD."dailyId", 'taskId', OLD."taskId", 'dayKey', OLD."dayKey", 'secondsLogged', OLD."secondsLogged", 'completedAt', OLD."completedAt", 'createdAt', OLD."createdAt"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS change_log_kanban_boards_insert;
-- statement
DROP TRIGGER IF EXISTS change_log_kanban_boards_update;
-- statement
DROP TRIGGER IF EXISTS change_log_kanban_boards_delete;
-- statement
CREATE TRIGGER change_log_kanban_boards_insert AFTER INSERT ON kanban_boards WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'kanban_boards', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'columnsJSON', NEW."columnsJSON"));
END;
-- statement
CREATE TRIGGER change_log_kanban_boards_update AFTER UPDATE ON kanban_boards WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'kanban_boards', NEW."id", 'update', json_object('id', OLD."id", 'columnsJSON', OLD."columnsJSON"), json_object('id', NEW."id", 'columnsJSON', NEW."columnsJSON"));
END;
-- statement
CREATE TRIGGER change_log_kanban_boards_delete AFTER DELETE ON kanban_boards WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'kanban_boards', OLD."id", 'delete', json_object('id', OLD."id", 'columnsJSON', OLD."columnsJSON"), NULL);
END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_workspaces_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_workspaces_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_workspaces_delete;
-- statement
CREATE TRIGGER sync_outbox_workspaces_insert AFTER INSERT ON workspaces WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('workspaces', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_workspaces_update AFTER UPDATE ON workspaces WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('workspaces', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."name" IS NOT NEW."name" THEN 'name' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_workspaces_delete AFTER DELETE ON workspaces WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('workspaces', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_list_folders_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_list_folders_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_list_folders_delete;
-- statement
CREATE TRIGGER sync_outbox_list_folders_insert AFTER INSERT ON list_folders WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('list_folders', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_list_folders_update AFTER UPDATE ON list_folders WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('list_folders', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."workspaceId" IS NOT NEW."workspaceId" THEN 'workspaceId' END, CASE WHEN OLD."parentFolderId" IS NOT NEW."parentFolderId" THEN 'parentFolderId' END, CASE WHEN OLD."name" IS NOT NEW."name" THEN 'name' END, CASE WHEN OLD."sortOrder" IS NOT NEW."sortOrder" THEN 'sortOrder' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_list_folders_delete AFTER DELETE ON list_folders WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('list_folders', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_lists_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_lists_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_lists_delete;
-- statement
CREATE TRIGGER sync_outbox_task_lists_insert AFTER INSERT ON task_lists WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_lists', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_lists_update AFTER UPDATE ON task_lists WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_lists', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."workspaceId" IS NOT NEW."workspaceId" THEN 'workspaceId' END, CASE WHEN OLD."folderId" IS NOT NEW."folderId" THEN 'folderId' END, CASE WHEN OLD."name" IS NOT NEW."name" THEN 'name' END, CASE WHEN OLD."colorHex" IS NOT NEW."colorHex" THEN 'colorHex' END, CASE WHEN OLD."sortOrder" IS NOT NEW."sortOrder" THEN 'sortOrder' END, CASE WHEN OLD."isArchived" IS NOT NEW."isArchived" THEN 'isArchived' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END, CASE WHEN OLD."systemRole" IS NOT NEW."systemRole" THEN 'systemRole' END, CASE WHEN OLD."visibleRootTaskId" IS NOT NEW."visibleRootTaskId" THEN 'visibleRootTaskId' END, CASE WHEN OLD."completedAt" IS NOT NEW."completedAt" THEN 'completedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_lists_delete AFTER DELETE ON task_lists WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_lists', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_tasks_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_tasks_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_tasks_delete;
-- statement
CREATE TRIGGER sync_outbox_tasks_insert AFTER INSERT ON tasks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('tasks', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_tasks_update AFTER UPDATE ON tasks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('tasks', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."listId" IS NOT NEW."listId" THEN 'listId' END, CASE WHEN OLD."parentTaskId" IS NOT NEW."parentTaskId" THEN 'parentTaskId' END, CASE WHEN OLD."title" IS NOT NEW."title" THEN 'title' END, CASE WHEN OLD."notes" IS NOT NEW."notes" THEN 'notes' END, CASE WHEN OLD."status" IS NOT NEW."status" THEN 'status' END, CASE WHEN OLD."sortOrder" IS NOT NEW."sortOrder" THEN 'sortOrder' END, CASE WHEN OLD."dueAt" IS NOT NEW."dueAt" THEN 'dueAt' END, CASE WHEN OLD."estimateSeconds" IS NOT NEW."estimateSeconds" THEN 'estimateSeconds' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END, CASE WHEN OLD."sourceSystem" IS NOT NEW."sourceSystem" THEN 'sourceSystem' END, CASE WHEN OLD."sourceId" IS NOT NEW."sourceId" THEN 'sourceId' END, CASE WHEN OLD."itemKind" IS NOT NEW."itemKind" THEN 'itemKind' END, CASE WHEN OLD."isPromoted" IS NOT NEW."isPromoted" THEN 'isPromoted' END, CASE WHEN OLD."archivedAt" IS NOT NEW."archivedAt" THEN 'archivedAt' END, CASE WHEN OLD."completedAt" IS NOT NEW."completedAt" THEN 'completedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_tasks_delete AFTER DELETE ON tasks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('tasks', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_metadata_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_metadata_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_metadata_delete;
-- statement
CREATE TRIGGER sync_outbox_task_metadata_insert AFTER INSERT ON task_metadata WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_metadata', NEW."taskId", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_metadata_update AFTER UPDATE ON task_metadata WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_metadata', NEW."taskId", 'update', json_array(CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."priority" IS NOT NEW."priority" THEN 'priority' END, CASE WHEN OLD."startAt" IS NOT NEW."startAt" THEN 'startAt' END, CASE WHEN OLD."tagsJSON" IS NOT NEW."tagsJSON" THEN 'tagsJSON' END, CASE WHEN OLD."recurrenceRule" IS NOT NEW."recurrenceRule" THEN 'recurrenceRule' END, CASE WHEN OLD."matrixUrgency" IS NOT NEW."matrixUrgency" THEN 'matrixUrgency' END, CASE WHEN OLD."matrixImportance" IS NOT NEW."matrixImportance" THEN 'matrixImportance' END, CASE WHEN OLD."kanbanColumn" IS NOT NEW."kanbanColumn" THEN 'kanbanColumn' END, CASE WHEN OLD."externalLinksJSON" IS NOT NEW."externalLinksJSON" THEN 'externalLinksJSON' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END, CASE WHEN OLD."focusRank" IS NOT NEW."focusRank" THEN 'focusRank' END, CASE WHEN OLD."planningJSON" IS NOT NEW."planningJSON" THEN 'planningJSON' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_metadata_delete AFTER DELETE ON task_metadata WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_metadata', OLD."taskId", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_conditions_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_conditions_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_task_conditions_delete;
-- statement
CREATE TRIGGER sync_outbox_task_conditions_insert AFTER INSERT ON task_conditions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_conditions', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_conditions_update AFTER UPDATE ON task_conditions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_conditions', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."workspaceId" IS NOT NEW."workspaceId" THEN 'workspaceId' END, CASE WHEN OLD."name" IS NOT NEW."name" THEN 'name' END, CASE WHEN OLD."isLocation" IS NOT NEW."isLocation" THEN 'isLocation' END, CASE WHEN OLD."isArchived" IS NOT NEW."isArchived" THEN 'isArchived' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_task_conditions_delete AFTER DELETE ON task_conditions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('task_conditions', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_kanban_boards_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_kanban_boards_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_kanban_boards_delete;
-- statement
CREATE TRIGGER sync_outbox_kanban_boards_insert AFTER INSERT ON kanban_boards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('kanban_boards', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_kanban_boards_update AFTER UPDATE ON kanban_boards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('kanban_boards', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."columnsJSON" IS NOT NEW."columnsJSON" THEN 'columnsJSON' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_kanban_boards_delete AFTER DELETE ON kanban_boards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('kanban_boards', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_dailies_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_dailies_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_dailies_delete;
-- statement
CREATE TRIGGER sync_outbox_dailies_insert AFTER INSERT ON dailies WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('dailies', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_dailies_update AFTER UPDATE ON dailies WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('dailies', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."activeWeekdaysMask" IS NOT NEW."activeWeekdaysMask" THEN 'activeWeekdaysMask' END, CASE WHEN OLD."intervalDays" IS NOT NEW."intervalDays" THEN 'intervalDays' END, CASE WHEN OLD."intervalAnchor" IS NOT NEW."intervalAnchor" THEN 'intervalAnchor' END, CASE WHEN OLD."targetSeconds" IS NOT NEW."targetSeconds" THEN 'targetSeconds' END, CASE WHEN OLD."sortOrder" IS NOT NEW."sortOrder" THEN 'sortOrder' END, CASE WHEN OLD."archivedAt" IS NOT NEW."archivedAt" THEN 'archivedAt' END, CASE WHEN OLD."legacyDailyId" IS NOT NEW."legacyDailyId" THEN 'legacyDailyId' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END, CASE WHEN OLD."sourceTaskId" IS NOT NEW."sourceTaskId" THEN 'sourceTaskId' END, CASE WHEN OLD."placementColumn" IS NOT NEW."placementColumn" THEN 'placementColumn' END, CASE WHEN OLD."dropsAtDayEnd" IS NOT NEW."dropsAtDayEnd" THEN 'dropsAtDayEnd' END, CASE WHEN OLD."expiryRule" IS NOT NEW."expiryRule" THEN 'expiryRule' END, CASE WHEN OLD."expiresAt" IS NOT NEW."expiresAt" THEN 'expiresAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_dailies_delete AFTER DELETE ON dailies WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('dailies', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_daily_contributions_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_daily_contributions_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_daily_contributions_delete;
-- statement
CREATE TRIGGER sync_outbox_daily_contributions_insert AFTER INSERT ON daily_contributions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('daily_contributions', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_daily_contributions_update AFTER UPDATE ON daily_contributions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('daily_contributions', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."dailyId" IS NOT NEW."dailyId" THEN 'dailyId' END, CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."dayKey" IS NOT NEW."dayKey" THEN 'dayKey' END, CASE WHEN OLD."secondsLogged" IS NOT NEW."secondsLogged" THEN 'secondsLogged' END, CASE WHEN OLD."completedAt" IS NOT NEW."completedAt" THEN 'completedAt' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_daily_contributions_delete AFTER DELETE ON daily_contributions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('daily_contributions', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_sessions_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_sessions_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_sessions_delete;
-- statement
CREATE TRIGGER sync_outbox_focus_sessions_insert AFTER INSERT ON focus_sessions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_sessions', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_sessions_update AFTER UPDATE ON focus_sessions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_sessions', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."startedAt" IS NOT NEW."startedAt" THEN 'startedAt' END, CASE WHEN OLD."endedAt" IS NOT NEW."endedAt" THEN 'endedAt' END, CASE WHEN OLD."phase" IS NOT NEW."phase" THEN 'phase' END, CASE WHEN OLD."activeTaskId" IS NOT NEW."activeTaskId" THEN 'activeTaskId' END, CASE WHEN OLD."workDurationSeconds" IS NOT NEW."workDurationSeconds" THEN 'workDurationSeconds' END, CASE WHEN OLD."breakDurationSeconds" IS NOT NEW."breakDurationSeconds" THEN 'breakDurationSeconds' END, CASE WHEN OLD."breakEndsAt" IS NOT NEW."breakEndsAt" THEN 'breakEndsAt' END, CASE WHEN OLD."activeTaskStartedAt" IS NOT NEW."activeTaskStartedAt" THEN 'activeTaskStartedAt' END, CASE WHEN OLD."activeBlockId" IS NOT NEW."activeBlockId" THEN 'activeBlockId' END, CASE WHEN OLD."accumulatedSeconds" IS NOT NEW."accumulatedSeconds" THEN 'accumulatedSeconds' END, CASE WHEN OLD."pausedAt" IS NOT NEW."pausedAt" THEN 'pausedAt' END, CASE WHEN OLD."checkpointAt" IS NOT NEW."checkpointAt" THEN 'checkpointAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_sessions_delete AFTER DELETE ON focus_sessions WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_sessions', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_queue_items_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_queue_items_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_queue_items_delete;
-- statement
CREATE TRIGGER sync_outbox_focus_queue_items_insert AFTER INSERT ON focus_queue_items WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_queue_items', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_queue_items_update AFTER UPDATE ON focus_queue_items WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_queue_items', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."sessionId" IS NOT NEW."sessionId" THEN 'sessionId' END, CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."sortOrder" IS NOT NEW."sortOrder" THEN 'sortOrder' END, CASE WHEN OLD."state" IS NOT NEW."state" THEN 'state' END, CASE WHEN OLD."completedAt" IS NOT NEW."completedAt" THEN 'completedAt' END, CASE WHEN OLD."skippedAt" IS NOT NEW."skippedAt" THEN 'skippedAt' END, CASE WHEN OLD."createdAt" IS NOT NEW."createdAt" THEN 'createdAt' END, CASE WHEN OLD."plannedSeconds" IS NOT NEW."plannedSeconds" THEN 'plannedSeconds' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_queue_items_delete AFTER DELETE ON focus_queue_items WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_queue_items', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_work_blocks_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_work_blocks_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_work_blocks_delete;
-- statement
CREATE TRIGGER sync_outbox_focus_work_blocks_insert AFTER INSERT ON focus_work_blocks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_work_blocks', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_work_blocks_update AFTER UPDATE ON focus_work_blocks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_work_blocks', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."sessionId" IS NOT NEW."sessionId" THEN 'sessionId' END, CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."taskTitle" IS NOT NEW."taskTitle" THEN 'taskTitle' END, CASE WHEN OLD."seconds" IS NOT NEW."seconds" THEN 'seconds' END, CASE WHEN OLD."recordedAt" IS NOT NEW."recordedAt" THEN 'recordedAt' END, CASE WHEN OLD."originalTaskId" IS NOT NEW."originalTaskId" THEN 'originalTaskId' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_work_blocks_delete AFTER DELETE ON focus_work_blocks WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_work_blocks', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_awards_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_awards_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_focus_awards_delete;
-- statement
CREATE TRIGGER sync_outbox_focus_awards_insert AFTER INSERT ON focus_awards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_awards', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_awards_update AFTER UPDATE ON focus_awards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_awards', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."sessionId" IS NOT NEW."sessionId" THEN 'sessionId' END, CASE WHEN OLD."taskId" IS NOT NEW."taskId" THEN 'taskId' END, CASE WHEN OLD."taskTitle" IS NOT NEW."taskTitle" THEN 'taskTitle' END, CASE WHEN OLD."seconds" IS NOT NEW."seconds" THEN 'seconds' END, CASE WHEN OLD."minutes" IS NOT NEW."minutes" THEN 'minutes' END, CASE WHEN OLD."multiplier" IS NOT NEW."multiplier" THEN 'multiplier' END, CASE WHEN OLD."points" IS NOT NEW."points" THEN 'points' END, CASE WHEN OLD."awardedAt" IS NOT NEW."awardedAt" THEN 'awardedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_focus_awards_delete AFTER DELETE ON focus_awards WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('focus_awards', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_themes_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_themes_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_themes_delete;
-- statement
CREATE TRIGGER sync_outbox_themes_insert AFTER INSERT ON themes WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('themes', NEW."id", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_themes_update AFTER UPDATE ON themes WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('themes', NEW."id", 'update', json_array(CASE WHEN OLD."id" IS NOT NEW."id" THEN 'id' END, CASE WHEN OLD."json" IS NOT NEW."json" THEN 'json' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_themes_delete AFTER DELETE ON themes WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('themes', OLD."id", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_preferences_insert;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_preferences_update;
-- statement
DROP TRIGGER IF EXISTS sync_outbox_preferences_delete;
-- statement
CREATE TRIGGER sync_outbox_preferences_insert AFTER INSERT ON preferences WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('preferences', NEW."key", 'insert', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_preferences_update AFTER UPDATE ON preferences WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('preferences', NEW."key", 'update', json_array(CASE WHEN OLD."key" IS NOT NEW."key" THEN 'key' END, CASE WHEN OLD."value" IS NOT NEW."value" THEN 'value' END, CASE WHEN OLD."updatedAt" IS NOT NEW."updatedAt" THEN 'updatedAt' END), CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
-- statement
CREATE TRIGGER sync_outbox_preferences_delete AFTER DELETE ON preferences WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
  AND (SELECT applying FROM sync_control WHERE id = 0) = 0
BEGIN INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) VALUES ('preferences', OLD."key", 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)); END;
