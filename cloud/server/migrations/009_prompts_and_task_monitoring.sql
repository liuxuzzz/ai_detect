CREATE TABLE IF NOT EXISTS managed_prompts (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    content TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT true,
    preset_key TEXT UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS prompt_id BIGINT REFERENCES managed_prompts(id) ON DELETE SET NULL;
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS live JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE async_tasks ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 0;
UPDATE async_tasks SET status='disabled',finished_at=now(),error='用户已禁用，任务不可执行'
WHERE status IN ('queued','running','paused')
  AND EXISTS (SELECT 1 FROM users owner WHERE owner.id=async_tasks.owner_id AND owner.disabled);
