ALTER TABLE users ADD COLUMN IF NOT EXISTS is_superadmin BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE;
-- Existing installations retain their oldest active administrator as the owner.
UPDATE users SET is_superadmin=TRUE
WHERE id=(SELECT id FROM users WHERE is_admin AND NOT disabled ORDER BY id LIMIT 1)
    AND NOT EXISTS(SELECT 1 FROM users WHERE is_superadmin);
CREATE UNIQUE INDEX IF NOT EXISTS users_single_superadmin ON users(is_superadmin) WHERE is_superadmin;

CREATE TABLE IF NOT EXISTS identity_settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    encrypted_config BYTEA
);
INSERT INTO identity_settings(singleton) VALUES(TRUE) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS email_challenges (
    email TEXT NOT NULL,
    purpose TEXT NOT NULL CHECK (purpose IN ('register','reset')),
    code_hash BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(email,purpose)
);
CREATE TABLE IF NOT EXISTS email_delivery_attempts (
    email TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS email_delivery_window ON email_delivery_attempts(email,requested_at DESC);

CREATE TABLE IF NOT EXISTS oauth_identities (
    provider TEXT NOT NULL CHECK(provider IN ('github','google')),
    subject TEXT NOT NULL,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY(provider,subject),
    UNIQUE(provider,user_id)
);
CREATE TABLE IF NOT EXISTS oauth_states (
    state_hash BYTEA PRIMARY KEY,
    browser_hash BYTEA NOT NULL,
    provider TEXT NOT NULL,
    verifier BYTEA NOT NULL,
    config_hash BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS oauth_tickets (
    token_hash BYTEA PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    auth_version BIGINT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
