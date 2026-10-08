-- v6_inbox_as_a_system_list, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE "task_lists" ADD COLUMN "systemRole" TEXT;
-- statement
UPDATE task_lists SET systemRole = 'inbox' WHERE id IN (
  SELECT id FROM task_lists AS candidate
  WHERE lower(candidate.name) = 'inbox'
    AND candidate.createdAt = (
      SELECT MIN(earliest.createdAt) FROM task_lists AS earliest
      WHERE lower(earliest.name) = 'inbox' AND earliest.workspaceId = candidate.workspaceId
    )
  GROUP BY candidate.workspaceId
);
-- statement
CREATE UNIQUE INDEX task_lists_on_system_role
ON task_lists(workspaceId, systemRole) WHERE systemRole IS NOT NULL;
