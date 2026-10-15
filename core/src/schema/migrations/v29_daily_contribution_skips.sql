-- v29_daily_contribution_skips: when a day's appearance of a habit was set
-- aside without being done (cancelling a commitment's subtask skips today).
-- A skipped day is not owed and not missed, but it is not a completion
-- either. NULL is not skipped, which is every contribution before.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "daily_contributions" ADD COLUMN "skippedAt" DATETIME;
