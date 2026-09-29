-- ══════════════════════════════════════════════════════════════
--  NSP Migration v2 — Preorder + Extended Docs + Categories
--  Run in Supabase SQL Editor (Dashboard → SQL Editor)
-- ══════════════════════════════════════════════════════════════

-- 1. Pre-order fields
ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS is_preorder    BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS preorder_note  TEXT;

-- 2. Document special conditions (plain text, shown to customer)
ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS doc_conditions TEXT;

-- 3. documents_config already JSONB — no schema change needed.
--    New keys added by app: meningitis, covid, birth_cert, custom_docs[]

-- 4. bookings: store preorder flag
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS is_preorder BOOLEAN DEFAULT FALSE;

-- 5. Index on category for faster filtering (optional but helpful)
CREATE INDEX IF NOT EXISTS idx_packages_category ON packages(category);

-- Verify
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'packages'
  AND column_name IN ('is_preorder','preorder_note','doc_conditions','documents_config')
ORDER BY column_name;
