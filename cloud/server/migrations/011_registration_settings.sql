CREATE TABLE IF NOT EXISTS site_settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    registration_enabled BOOLEAN NOT NULL DEFAULT TRUE
);

-- Seed once so an administrator's choice survives every subsequent startup.
INSERT INTO site_settings(singleton) VALUES(TRUE) ON CONFLICT(singleton) DO NOTHING;
