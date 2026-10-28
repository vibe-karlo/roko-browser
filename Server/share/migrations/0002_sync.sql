-- roko's own sync: to-dos, the shopping lists and links sent to roko, kept the
-- same between the iPhone and the Mac (Raycast). One space per person, opened
-- by a key that roko makes and shows in Settings.
CREATE TABLE sync_spaces (
  id TEXT PRIMARY KEY,
  -- SHA-256 of the key's secret part; the secret itself is never stored.
  key_hash TEXT NOT NULL,
  -- SHA-256 of the creating IP address (salted), only to cap new spaces per day.
  address_hash TEXT NOT NULL,
  created INTEGER NOT NULL,
  -- The last change's number: every write takes the next ones.
  seq INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX sync_spaces_by_address ON sync_spaces (address_hash, created);

-- The latest state of each thing, with the number of the change that made it.
-- A deleted thing stays as a marker, so a device that was away hears of it.
CREATE TABLE sync_records (
  space TEXT NOT NULL,
  -- "todo", "shopping" or "link".
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  -- The thing as JSON; null once deleted.
  data TEXT,
  -- When it was changed, by the device that changed it (ms): the later change wins.
  updated INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space, kind, id)
);

CREATE INDEX sync_records_by_seq ON sync_records (space, seq);
