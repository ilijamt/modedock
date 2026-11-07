-- The public stats, recomputed daily by the cron trigger, so serving them reads one row.
CREATE TABLE stats (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  body TEXT NOT NULL CHECK (json_valid(body)),
  updated TEXT NOT NULL
);
