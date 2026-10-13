-- v24_condition_categories: a condition's category ("Location", "Equipment", "Energy"), which groups it under a heading.
-- Written for the Rust core; existing places are filed under "Location" and the journal and outbox triggers are reinstalled after it.
ALTER TABLE "task_conditions" ADD COLUMN "category" TEXT;
