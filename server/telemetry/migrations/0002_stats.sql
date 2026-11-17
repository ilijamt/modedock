-- One row, recomputed hourly, so serving the stats is a single read.
CREATE TABLE stats (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  body TEXT NOT NULL CHECK (json_valid(body)),
  updated TEXT NOT NULL
);
