-- v30_google_calendar: two-way Google Calendar (docs/google-calendar.md).
-- `calendar_event_links` is a task's event: synced, pushed whole, never
-- journalled. No foreign key to `tasks`, on purpose: the link of a deleted
-- task is how its event comes to be deleted. `calendar_sync_tokens` is this
-- device's place in each calendar's change feed and is never synced.
-- Written for the Rust core; the journal and outbox triggers are reinstalled after it.
CREATE TABLE "calendar_event_links" ("taskId" TEXT PRIMARY KEY, "calendarId" TEXT NOT NULL, "eventId" TEXT NOT NULL, "state" TEXT NOT NULL DEFAULT 'linked', "pushedJSON" TEXT, "remoteUpdatedAt" DATETIME, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
CREATE INDEX "calendar_event_links_on_eventId" ON "calendar_event_links"("eventId");
CREATE TABLE "calendar_sync_tokens" ("calendarId" TEXT PRIMARY KEY, "syncToken" TEXT, "updatedAt" DATETIME NOT NULL);
