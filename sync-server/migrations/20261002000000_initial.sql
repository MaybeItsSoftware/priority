-- The server half of docs/sync.md ("Server storage"). The server stores rows
-- and merges them; it knows nothing about what a task is, so every synced
-- table shares the one `rows` table, keyed by (table_name, row_id).

CREATE TABLE devices (
  id UUID PRIMARY KEY,
  name TEXT,
  platform TEXT,
  -- sha256 of the bearer token, hex. The token itself is never stored.
  token_hash TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ
);

CREATE TABLE pairing_codes (
  code TEXT PRIMARY KEY,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ
);

-- One global sequence: a device's cursor is a position in it, so every change
-- to any row in any table must draw from the same one.
CREATE SEQUENCE row_seq;

CREATE TABLE rows (
  table_name TEXT NOT NULL,
  row_id TEXT NOT NULL,
  data JSONB NOT NULL DEFAULT '{}',
  col_hlc JSONB NOT NULL DEFAULT '{}',
  deleted BOOLEAN NOT NULL DEFAULT false,
  deleted_hlc TEXT,
  seq BIGINT NOT NULL,
  last_device_id UUID,
  PRIMARY KEY (table_name, row_id)
);

CREATE INDEX rows_seq ON rows(seq);
