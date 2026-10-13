-- v25_agent_instructions: the agent panel's standing instructions, one row per
-- scope: "account", "folder:<id>" or "list:<id>" (`agent_instructions`).
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
CREATE TABLE "agent_instructions" ("scope" TEXT PRIMARY KEY, "text" TEXT NOT NULL, "updatedAt" DATETIME NOT NULL);
