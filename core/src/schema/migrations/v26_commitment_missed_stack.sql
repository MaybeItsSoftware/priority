-- v26_commitment_missed_stack: the day from which a habit's missed appearances
-- stack (each one owed until it is done) rather than vanish. NULL vanishes,
-- which is how every habit and commitment behaved before.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE "dailies" ADD COLUMN "stacksMissedFrom" DATETIME;
