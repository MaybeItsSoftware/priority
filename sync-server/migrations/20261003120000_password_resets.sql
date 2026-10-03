-- Password reset links. Like device tokens, only the sha256 of the token in
-- the link is kept, so a leaked database holds no working links.
CREATE TABLE password_resets (
  token_hash TEXT PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ
);
CREATE INDEX password_resets_account ON password_resets(account_id, created_at);
