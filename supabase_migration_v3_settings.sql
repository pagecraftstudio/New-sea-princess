-- ══════════════════════════════════════════════════════════════
--  NSP Migration v3 — app_settings table
--  Run in Supabase SQL Editor
-- ══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS app_settings (
  key   TEXT PRIMARY KEY,
  value JSONB NOT NULL DEFAULT '[]'
);

-- Seed empty lists so upsert works from day one
INSERT INTO app_settings (key, value)
VALUES
  ('custom_categories', '[]'::jsonb),
  ('custom_seasons',    '[]'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- Only admins can read/write
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admins_all" ON app_settings
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM auth.users
      WHERE id = auth.uid()
    )
  );

-- Verify
SELECT key, value FROM app_settings;
