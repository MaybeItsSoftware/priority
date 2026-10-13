-- v27_condition_order_and_context: the order conditions and their categories
-- are shown in, and the context — what holds now — as a row rather than each
-- app's preferences, so the CLI and the agent can read and set it.
-- `sortOrder` is NULL for a condition nobody has placed: it sorts after the
-- placed ones under its heading. `focus_contexts` is local to the device,
-- neither journalled nor synced: where you are is where this machine is.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "task_conditions" ADD COLUMN "sortOrder" INTEGER;
-- statement
CREATE TABLE "focus_contexts" (
  "workspaceId" TEXT PRIMARY KEY NOT NULL REFERENCES "workspaces"("id") ON DELETE CASCADE,
  "conditionIdsJSON" TEXT NOT NULL DEFAULT '[]',
  "conditionsSetAt" DATETIME,
  "availableUntil" DATETIME,
  "expiresAt" DATETIME,
  "mode" TEXT NOT NULL DEFAULT 'progress',
  "suggestedIdsJSON" TEXT NOT NULL DEFAULT '[]',
  "updatedAt" DATETIME NOT NULL
);
