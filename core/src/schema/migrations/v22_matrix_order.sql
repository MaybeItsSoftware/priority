-- v22_matrix_order: a task's place within its matrix quadrant.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
ALTER TABLE task_metadata ADD COLUMN matrixRank INTEGER;
