-- v9_focus_block_start, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE "focus_sessions" ADD COLUMN "activeTaskStartedAt" DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00.000';
-- statement
UPDATE focus_sessions SET activeTaskStartedAt = startedAt;
