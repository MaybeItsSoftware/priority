-- v23_filter_lists: saved, named rule sets over every task (`filter_lists`).
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
CREATE TABLE "filter_lists" ("id" TEXT PRIMARY KEY, "workspaceId" TEXT NOT NULL REFERENCES "workspaces"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "icon" TEXT, "colorHex" TEXT, "rulesJSON" TEXT NOT NULL, "sortOrder" INTEGER NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
-- statement
CREATE INDEX "filter_lists_on_workspaceId" ON "filter_lists"("workspaceId");
