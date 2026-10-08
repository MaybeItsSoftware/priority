-- v14_nested_lists, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE "tasks" ADD COLUMN "itemKind" TEXT;
-- statement
ALTER TABLE "tasks" ADD COLUMN "isPromoted" BOOLEAN;
-- statement
ALTER TABLE "tasks" ADD COLUMN "archivedAt" DATETIME;
-- statement
ALTER TABLE "task_lists" ADD COLUMN "completedAt" DATETIME;
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
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'listId', NEW."listId", 'parentTaskId', NEW."parentTaskId", 'title', NEW."title", 'notes', NEW."notes", 'status', NEW."status", 'sortOrder', NEW."sortOrder", 'dueAt', NEW."dueAt", 'estimateSeconds', NEW."estimateSeconds", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceSystem', NEW."sourceSystem", 'sourceId', NEW."sourceId", 'itemKind', NEW."itemKind", 'isPromoted', NEW."isPromoted", 'archivedAt', NEW."archivedAt"));
END;
-- statement
CREATE TRIGGER change_log_tasks_update AFTER UPDATE ON tasks WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', NEW."id", 'update', json_object('id', OLD."id", 'listId', OLD."listId", 'parentTaskId', OLD."parentTaskId", 'title', OLD."title", 'notes', OLD."notes", 'status', OLD."status", 'sortOrder', OLD."sortOrder", 'dueAt', OLD."dueAt", 'estimateSeconds', OLD."estimateSeconds", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceSystem', OLD."sourceSystem", 'sourceId', OLD."sourceId", 'itemKind', OLD."itemKind", 'isPromoted', OLD."isPromoted", 'archivedAt', OLD."archivedAt"), json_object('id', NEW."id", 'listId', NEW."listId", 'parentTaskId', NEW."parentTaskId", 'title', NEW."title", 'notes', NEW."notes", 'status', NEW."status", 'sortOrder', NEW."sortOrder", 'dueAt', NEW."dueAt", 'estimateSeconds', NEW."estimateSeconds", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt", 'sourceSystem', NEW."sourceSystem", 'sourceId', NEW."sourceId", 'itemKind', NEW."itemKind", 'isPromoted', NEW."isPromoted", 'archivedAt', NEW."archivedAt"));
END;
-- statement
CREATE TRIGGER change_log_tasks_delete AFTER DELETE ON tasks WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'tasks', OLD."id", 'delete', json_object('id', OLD."id", 'listId', OLD."listId", 'parentTaskId', OLD."parentTaskId", 'title', OLD."title", 'notes', OLD."notes", 'status', OLD."status", 'sortOrder', OLD."sortOrder", 'dueAt', OLD."dueAt", 'estimateSeconds', OLD."estimateSeconds", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt", 'sourceSystem', OLD."sourceSystem", 'sourceId', OLD."sourceId", 'itemKind', OLD."itemKind", 'isPromoted', OLD."isPromoted", 'archivedAt', OLD."archivedAt"), NULL);
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
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', NEW."id", 'insert', NULL, json_object('id', NEW."id", 'taskId', NEW."taskId", 'activeWeekdaysMask', NEW."activeWeekdaysMask", 'intervalDays', NEW."intervalDays", 'intervalAnchor', NEW."intervalAnchor", 'targetSeconds', NEW."targetSeconds", 'sortOrder', NEW."sortOrder", 'archivedAt', NEW."archivedAt", 'legacyDailyId', NEW."legacyDailyId", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_dailies_update AFTER UPDATE ON dailies WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', NEW."id", 'update', json_object('id', OLD."id", 'taskId', OLD."taskId", 'activeWeekdaysMask', OLD."activeWeekdaysMask", 'intervalDays', OLD."intervalDays", 'intervalAnchor', OLD."intervalAnchor", 'targetSeconds', OLD."targetSeconds", 'sortOrder', OLD."sortOrder", 'archivedAt', OLD."archivedAt", 'legacyDailyId', OLD."legacyDailyId", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), json_object('id', NEW."id", 'taskId', NEW."taskId", 'activeWeekdaysMask', NEW."activeWeekdaysMask", 'intervalDays', NEW."intervalDays", 'intervalAnchor', NEW."intervalAnchor", 'targetSeconds', NEW."targetSeconds", 'sortOrder', NEW."sortOrder", 'archivedAt', NEW."archivedAt", 'legacyDailyId', NEW."legacyDailyId", 'createdAt', NEW."createdAt", 'updatedAt', NEW."updatedAt"));
END;
-- statement
CREATE TRIGGER change_log_dailies_delete AFTER DELETE ON dailies WHEN (SELECT suppressed FROM undo_control WHERE id = 0) = 0
BEGIN
  INSERT INTO change_log(groupId, label, tableName, rowId, operation, beforeJSON, afterJSON) VALUES ((SELECT groupId FROM undo_control WHERE id = 0), (SELECT label FROM undo_control WHERE id = 0), 'dailies', OLD."id", 'delete', json_object('id', OLD."id", 'taskId', OLD."taskId", 'activeWeekdaysMask', OLD."activeWeekdaysMask", 'intervalDays', OLD."intervalDays", 'intervalAnchor', OLD."intervalAnchor", 'targetSeconds', OLD."targetSeconds", 'sortOrder', OLD."sortOrder", 'archivedAt', OLD."archivedAt", 'legacyDailyId', OLD."legacyDailyId", 'createdAt', OLD."createdAt", 'updatedAt', OLD."updatedAt"), NULL);
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
