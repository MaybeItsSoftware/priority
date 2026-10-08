-- v7_task_full_text_search, as GRDB runs it on an empty database.
-- Captured by workspace-tests/MigrationCaptureTests.swift; do not edit by hand.
CREATE VIRTUAL TABLE "tasks_fts" USING fts5(title, notes, tokenize='''porter'' ''unicode61''', content='tasks');
-- statement
-- CREATE TABLE 'main'.'tasks_fts_data'(id INTEGER PRIMARY KEY, block BLOB);
-- statement
-- CREATE TABLE 'main'.'tasks_fts_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
-- statement
-- CREATE TABLE 'main'.'tasks_fts_docsize'(id INTEGER PRIMARY KEY, sz BLOB);
-- statement
-- CREATE TABLE 'main'.'tasks_fts_config'(k PRIMARY KEY, v) WITHOUT ROWID;
-- statement
-- REPLACE INTO 'main'.'tasks_fts_config' VALUES(?,?);
-- statement
-- PRAGMA 'main'.data_version;
-- statement
-- SELECT k, v FROM 'main'.'tasks_fts_config';
-- statement
CREATE TRIGGER "__tasks_fts_ai" AFTER INSERT ON "tasks" BEGIN
    INSERT INTO "tasks_fts"("rowid", "title", "notes") VALUES (new."rowid", new."title", new."notes");
END;
-- statement
CREATE TRIGGER "__tasks_fts_ad" AFTER DELETE ON "tasks" BEGIN
    INSERT INTO "tasks_fts"("tasks_fts", "rowid", "title", "notes") VALUES('delete', old."rowid", old."title", old."notes");
END;
-- statement
CREATE TRIGGER "__tasks_fts_au" AFTER UPDATE ON "tasks" BEGIN
    INSERT INTO "tasks_fts"("tasks_fts", "rowid", "title", "notes") VALUES('delete', old."rowid", old."title", old."notes");
    INSERT INTO "tasks_fts"("rowid", "title", "notes") VALUES (new."rowid", new."title", new."notes");
END;
-- statement
INSERT INTO "tasks_fts"("tasks_fts") VALUES('rebuild');
-- statement
-- DELETE FROM 'main'.'tasks_fts_data';;
-- statement
-- DELETE FROM 'main'.'tasks_fts_idx';;
-- statement
-- DELETE FROM 'main'.'tasks_fts_docsize';;
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
-- statement
-- REPLACE INTO 'main'.'tasks_fts_config' VALUES(?,?);
-- statement
-- SELECT T.'rowid', T.'title', T.'notes' FROM 'main'.'tasks' AS T;
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
-- statement
-- REPLACE INTO 'main'.'tasks_fts_data'(id, block) VALUES(?,?);
