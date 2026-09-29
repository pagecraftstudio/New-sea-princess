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

-- Enable RLS
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- Remove any existing policy before recreating
DO $$
BEGIN
  DROP POLICY IF EXISTS "admins_all" ON app_settings;
END$$;

-- Only rows in admin_users can read/write (admin_users.id = auth uid)
CREATE POLICY "admins_all" ON app_settings
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM admin_users
      WHERE id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM admin_users
      WHERE id = auth.uid()
    )
  );

-- Verify
SELECT key, value FROM app_settings;
