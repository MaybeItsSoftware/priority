-- v10_focus_points, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
CREATE TABLE "focus_awards" ("id" TEXT PRIMARY KEY, "sessionId" TEXT REFERENCES "focus_sessions"("id") ON DELETE SET NULL, "taskId" TEXT REFERENCES "tasks"("id") ON DELETE SET NULL, "taskTitle" TEXT NOT NULL, "seconds" INTEGER NOT NULL, "minutes" DOUBLE NOT NULL, "multiplier" DOUBLE NOT NULL, "points" DOUBLE NOT NULL, "awardedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "focus_awards_on_awardedAt" ON "focus_awards"("awardedAt");
