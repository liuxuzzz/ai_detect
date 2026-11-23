ALTER TABLE client_keys ADD COLUMN IF NOT EXISTS encrypted_secret BYTEA;
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS report_id BIGINT REFERENCES reports(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS async_tasks_due_idx ON async_tasks(scheduled_for, id) WHERE status = 'queued';
