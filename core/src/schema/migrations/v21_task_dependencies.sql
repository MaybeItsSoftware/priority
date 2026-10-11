-- v21_task_dependencies: a task can wait on other tasks until they are done.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
CREATE TABLE "task_dependencies" ("id" TEXT PRIMARY KEY, "taskId" TEXT NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE, "blockedByTaskId" TEXT NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE, "createdAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "task_dependencies_on_taskId" ON "task_dependencies"("taskId");
-- statement
CREATE INDEX "task_dependencies_on_blockedByTaskId" ON "task_dependencies"("blockedByTaskId");
