CREATE TABLE reports (
  report TEXT PRIMARY KEY,
  install TEXT NOT NULL,
  day TEXT NOT NULL,
  schema INTEGER NOT NULL,
  app_version TEXT NOT NULL,
  os_version TEXT NOT NULL,
  language TEXT NOT NULL,
  architecture TEXT NOT NULL,
  country TEXT,
  counts TEXT NOT NULL CHECK (json_valid(counts)),
  setup TEXT CHECK (setup IS NULL OR json_valid(setup))
);

CREATE INDEX reports_install ON reports (install);
CREATE INDEX reports_day ON reports (day);
CREATE INDEX reports_country ON reports (country);
