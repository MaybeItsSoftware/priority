-- Accounts: anyone can sign up, and each account's rows, devices and pairing
-- codes are its own. Before this a server held one person's workspace and the
-- first device paired with an admin token.

CREATE TABLE accounts (
  id UUID PRIMARY KEY,
  -- Lowercased and trimmed by the server, so the unique constraint is the
  -- case-insensitive one. NULL only for the account below.
  email TEXT UNIQUE,
  -- argon2id, PHC string. NULL means nobody can sign in with a password; the
  -- account's devices still work, and can add more with pairing codes.
  password_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A server that already held a workspace gives it to one account with no
-- email, so the devices syncing it carry on as they were.
INSERT INTO accounts (id)
SELECT gen_random_uuid()
WHERE EXISTS (SELECT 1 FROM devices) OR EXISTS (SELECT 1 FROM rows);

ALTER TABLE devices ADD COLUMN account_id UUID REFERENCES accounts(id) ON DELETE CASCADE;
ALTER TABLE rows ADD COLUMN account_id UUID REFERENCES accounts(id) ON DELETE CASCADE;
ALTER TABLE pairing_codes ADD COLUMN account_id UUID REFERENCES accounts(id) ON DELETE CASCADE;

UPDATE devices SET account_id = (SELECT id FROM accounts LIMIT 1);
UPDATE rows SET account_id = (SELECT id FROM accounts LIMIT 1);
-- Codes live ten minutes, and the old ones belong to nobody in particular.
DELETE FROM pairing_codes;

ALTER TABLE devices ALTER COLUMN account_id SET NOT NULL;
ALTER TABLE rows ALTER COLUMN account_id SET NOT NULL;
ALTER TABLE pairing_codes ALTER COLUMN account_id SET NOT NULL;

-- Two accounts can hold the same row id: a workspace copied between them.
ALTER TABLE rows DROP CONSTRAINT rows_pkey;
ALTER TABLE rows ADD PRIMARY KEY (account_id, table_name, row_id);
DROP INDEX rows_seq;
CREATE INDEX rows_account_seq ON rows(account_id, seq);
CREATE INDEX devices_account ON devices(account_id);
