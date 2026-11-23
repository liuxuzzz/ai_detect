-- Keep legacy documents for rollback; all new reports store versioned data.
ALTER TABLE reports ADD COLUMN IF NOT EXISTS data JSONB;
ALTER TABLE reports ALTER COLUMN html DROP NOT NULL;
