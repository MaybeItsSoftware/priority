-- v32_follow_up_repeat: chasing a waiting task again and again. A waiting
-- task can repeat its follow-up every N days (`waitingFollowUpEveryDays`,
-- 1 to 365, NULL for once): completing the follow-up moves the next one N
-- days on. `waitingFollowUpCount` is how many follow-ups this spell of
-- waiting has made, so the second is "Follow up #2 with Sam: ...". Naming
-- someone else, or clearing the waiting, starts the count again. See
-- core/src/waiting.rs.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "task_metadata" ADD COLUMN "waitingFollowUpEveryDays" INTEGER;
-- statement
ALTER TABLE "task_metadata" ADD COLUMN "waitingFollowUpCount" INTEGER NOT NULL DEFAULT 0;
