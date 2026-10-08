-- v3_dailies_as_contributions, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
CREATE TABLE "dailies" ("id" TEXT PRIMARY KEY, "taskId" TEXT NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE, "activeWeekdaysMask" INTEGER NOT NULL DEFAULT 127, "intervalDays" INTEGER, "intervalAnchor" DATETIME, "targetSeconds" INTEGER, "sortOrder" INTEGER NOT NULL, "archivedAt" DATETIME, "legacyDailyId" TEXT UNIQUE, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "dailies_on_taskId" ON "dailies"("taskId");
-- statement
CREATE TABLE "daily_contributions" ("id" TEXT PRIMARY KEY, "dailyId" TEXT NOT NULL REFERENCES "dailies"("id") ON DELETE CASCADE, "taskId" TEXT NOT NULL REFERENCES "tasks"("id") ON DELETE CASCADE, "dayKey" TEXT NOT NULL, "secondsLogged" INTEGER NOT NULL DEFAULT 0, "completedAt" DATETIME, "createdAt" DATETIME NOT NULL, UNIQUE ("dailyId", "dayKey"));
-- statement
CREATE INDEX "daily_contributions_on_dailyId" ON "daily_contributions"("dailyId");
-- statement
CREATE INDEX "daily_contributions_on_taskId" ON "daily_contributions"("taskId");
-- statement
ALTER TABLE "focus_queue_items" ADD COLUMN "plannedSeconds" INTEGER;
