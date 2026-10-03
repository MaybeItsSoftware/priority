-- The server half of docs/sync.md ("Server storage"). The server stores rows
-- and merges them; it knows nothing about what a task is, so every synced
-- table shares the one `rows` table, keyed by (account, table, row id).
--
-- Accounts are Supabase Auth users: `account_id` is the user's id, the `sub`
-- of the token every request carries. Nothing here references `auth.users`,
-- so the schema runs on any Postgres; deleting an account goes through the
-- server, which deletes these rows and then the user.

-- The devices that have synced, for the device list in settings and for
-- `rows.last_device_id`. A device names itself with a uuid it keeps.
CREATE TABLE devices (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL,
  name TEXT,
  platform TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ
);
CREATE INDEX devices_account ON devices(account_id);

-- One sequence for every account: a cursor only has to rise, so an
-- account's rows having gaps between their numbers costs nothing.
CREATE SEQUENCE row_seq;

CREATE TABLE rows (
  account_id UUID NOT NULL,
  table_name TEXT NOT NULL,
  row_id TEXT NOT NULL,
  data JSONB NOT NULL DEFAULT '{}',
  col_hlc JSONB NOT NULL DEFAULT '{}',
  deleted BOOLEAN NOT NULL DEFAULT false,
  deleted_hlc TEXT,
  seq BIGINT NOT NULL,
  last_device_id UUID,
  PRIMARY KEY (account_id, table_name, row_id)
);
CREATE INDEX rows_account_seq ON rows(account_id, seq);

-- On Supabase nothing but the server should touch these. They sit in their
-- own schema, which the Data API doesn't expose, and RLS with no policies
-- refuses every other role besides; the server connects as the owner.
ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE rows ENABLE ROW LEVEL SECURITY;
