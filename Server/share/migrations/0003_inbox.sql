-- Newsletters sent to a private address of roko's, held only until the iPhone
-- has fetched them, and for 30 days at most.
CREATE TABLE inbox_boxes (
  -- The address's local part, lowercase: <id>@<MAIL_DOMAIN>.
  id TEXT PRIMARY KEY,
  -- SHA-256 of the key's secret part; the secret itself is never stored.
  key_hash TEXT NOT NULL,
  -- SHA-256 of the creating IP address (salted), only to cap new boxes per day.
  address_hash TEXT NOT NULL,
  created INTEGER NOT NULL
);

CREATE INDEX inbox_boxes_by_address ON inbox_boxes (address_hash, created);

CREATE TABLE inbox_mail (
  id TEXT PRIMARY KEY,
  box TEXT NOT NULL,
  sender TEXT NOT NULL,
  sender_name TEXT,
  subject TEXT NOT NULL,
  received INTEGER NOT NULL,
  -- The mail's List-Unsubscribe link, when it has an https one.
  unsubscribe TEXT,
  html TEXT,
  text TEXT
);

CREATE INDEX inbox_mail_by_box ON inbox_mail (box, received);
