-- v5_task_source_identity, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE "tasks" ADD COLUMN "sourceSystem" TEXT;
-- statement
ALTER TABLE "tasks" ADD COLUMN "sourceId" TEXT;
-- statement
CREATE UNIQUE INDEX tasks_on_source
ON tasks(sourceSystem, sourceId) WHERE sourceId IS NOT NULL;
