ALTER TABLE cloud_upstreams ADD COLUMN IF NOT EXISTS description TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_upstreams ADD COLUMN IF NOT EXISTS provider_type TEXT NOT NULL DEFAULT 'openai-compatible';
ALTER TABLE cloud_upstreams ADD COLUMN IF NOT EXISTS pinned BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE cloud_upstreams ADD COLUMN IF NOT EXISTS models JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE cloud_upstreams ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ;

ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS model TEXT NOT NULL DEFAULT '';
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS reasoning_effort TEXT NOT NULL DEFAULT 'default';
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS execution_mode TEXT NOT NULL DEFAULT 'immediate';
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS delay_ms INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS cloud_upstreams_pinned_idx ON cloud_upstreams(pinned DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS reports_dashboard_idx ON reports(owner_id, created_at DESC) WHERE deleted_at IS NULL;
