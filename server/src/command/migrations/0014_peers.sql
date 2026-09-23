-- Connected peer agents (A2A) + audit log of every agent<->agent exchange.

CREATE TABLE IF NOT EXISTS peers (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,                 -- slug, unique per account, agent-facing id
  card_url TEXT NOT NULL,             -- where the agent card was fetched from
  url TEXT NOT NULL,                  -- the peer's A2A JSON-RPC endpoint (from its card)
  card_json TEXT NOT NULL,
  card_fetched_at TEXT NOT NULL,
  token_ciphertext TEXT,              -- AES-GCM, NULL = unauthenticated peer
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(account_id, name)
);

CREATE TABLE IF NOT EXISTS peer_exchanges (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  peer_id INTEGER REFERENCES peers(id) ON DELETE SET NULL,  -- NULL for inbound
  direction TEXT NOT NULL CHECK (direction IN ('in','out')),
  context_id TEXT,
  request_text TEXT NOT NULL,
  response_text TEXT,
  status TEXT NOT NULL,               -- ok | error:<kind>
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_peer_exchanges_account
  ON peer_exchanges(account_id, created_at);
