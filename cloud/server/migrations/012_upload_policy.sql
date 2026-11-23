ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS upload_limit BIGINT NOT NULL DEFAULT 100
    CHECK (upload_limit BETWEEN 1 AND 1000000);
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS upload_window_seconds BIGINT NOT NULL DEFAULT 86400
    CHECK (upload_window_seconds BETWEEN 1 AND 31536000);

CREATE INDEX IF NOT EXISTS reports_upload_window_idx ON reports(owner_id, created_at DESC);
