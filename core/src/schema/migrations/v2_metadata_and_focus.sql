-- v2_metadata_and_focus, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
CREATE TABLE "task_metadata" ("taskId" TEXT PRIMARY KEY REFERENCES "tasks"("id") ON DELETE CASCADE, "priority" INTEGER, "startAt" DATETIME, "tagsJSON" TEXT NOT NULL DEFAULT '[]', "recurrenceRule" TEXT, "matrixUrgency" INTEGER, "matrixImportance" INTEGER, "kanbanColumn" TEXT, "externalLinksJSON" TEXT NOT NULL DEFAULT '[]', "updatedAt" DATETIME NOT NULL);
-- statement
CREATE TABLE "focus_sessions" ("id" TEXT PRIMARY KEY, "startedAt" DATETIME NOT NULL, "endedAt" DATETIME, "phase" TEXT NOT NULL, "activeTaskId" TEXT REFERENCES "tasks"("id") ON DELETE SET NULL, "workDurationSeconds" INTEGER NOT NULL, "breakDurationSeconds" INTEGER NOT NULL, "breakEndsAt" DATETIME);
-- statement
CREATE INDEX "focus_sessions_on_startedAt" ON "focus_sessions"("startedAt");
-- statement
CREATE TABLE "focus_queue_items" ("id" TEXT PRIMARY KEY, "sessionId" TEXT NOT NULL REFERENCES "focus_sessions"("id") ON DELETE CASCADE, "taskId" TEXT NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE, "sortOrder" INTEGER NOT NULL, "state" TEXT NOT NULL DEFAULT 'queued', "completedAt" DATETIME, "skippedAt" DATETIME, "createdAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "focus_queue_items_on_sessionId" ON "focus_queue_items"("sessionId");
-- statement
CREATE INDEX "focus_queue_items_on_taskId" ON "focus_queue_items"("taskId");
