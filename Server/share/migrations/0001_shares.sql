-- One row per shared Browse for Me page.
CREATE TABLE shares (
  id TEXT PRIMARY KEY,
  -- SHA-256 of the edit token the app keeps; the token itself is never stored.
  token_hash TEXT NOT NULL,
  -- SHA-256 of the sharer's IP address (salted), only to cap shares per day.
  address_hash TEXT NOT NULL,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  -- The page: { lang, turns: [{ question, answer, sources, images }] }.
  data TEXT NOT NULL
);

CREATE INDEX shares_by_address ON shares (address_hash, created);
