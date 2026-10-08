-- v1_local_workspace, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
CREATE TABLE "workspaces" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE TABLE "list_folders" ("id" TEXT PRIMARY KEY, "workspaceId" TEXT NOT NULL REFERENCES "workspaces"("id") ON DELETE CASCADE, "parentFolderId" TEXT REFERENCES "list_folders"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "sortOrder" INTEGER NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "list_folders_on_workspaceId" ON "list_folders"("workspaceId");
-- statement
CREATE INDEX "list_folders_on_parentFolderId" ON "list_folders"("parentFolderId");
-- statement
CREATE TABLE "task_lists" ("id" TEXT PRIMARY KEY, "workspaceId" TEXT NOT NULL REFERENCES "workspaces"("id") ON DELETE CASCADE, "folderId" TEXT REFERENCES "list_folders"("id") ON DELETE SET NULL, "name" TEXT NOT NULL, "colorHex" TEXT, "sortOrder" INTEGER NOT NULL, "isArchived" BOOLEAN NOT NULL DEFAULT 0, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "task_lists_on_workspaceId" ON "task_lists"("workspaceId");
-- statement
CREATE INDEX "task_lists_on_folderId" ON "task_lists"("folderId");
-- statement
CREATE TABLE "tasks" ("id" TEXT PRIMARY KEY, "listId" TEXT NOT NULL REFERENCES "task_lists"("id") ON DELETE CASCADE, "parentTaskId" TEXT REFERENCES "tasks"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "notes" TEXT NOT NULL DEFAULT '', "status" TEXT NOT NULL DEFAULT 'open', "sortOrder" INTEGER NOT NULL, "dueAt" DATETIME, "estimateSeconds" INTEGER, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "tasks_on_listId" ON "tasks"("listId");
-- statement
CREATE INDEX "tasks_on_parentTaskId" ON "tasks"("parentTaskId");
