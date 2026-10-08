-- v4_manual_focus_order, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
ALTER TABLE "task_metadata" ADD COLUMN "focusRank" INTEGER;
