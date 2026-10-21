-- v34_condition_provides: conditions that provide others, and provided
-- conditions switched off for now. `task_conditions.providesJSON` is a JSON
-- array of the ids a condition switches on while it holds (Home: Floor
-- space, Desk, Quiet), NULL for none. `focus_contexts.offIdsJSON` is the
-- provided conditions said not to hold for now (housemates in: Quiet off),
-- kept until whatever provides them is unset or replaced. See
-- core/src/conditions/provides.rs.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "task_conditions" ADD COLUMN "providesJSON" TEXT;
-- statement
ALTER TABLE "focus_contexts" ADD COLUMN "offIdsJSON" TEXT NOT NULL DEFAULT '[]';
