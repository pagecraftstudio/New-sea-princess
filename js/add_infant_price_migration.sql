-- ════════════════════════════════════════════════════════════
-- Migration: add price_infant to packages
-- Run this once in Supabase SQL editor.
-- ════════════════════════════════════════════════════════════

ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS price_infant DECIMAL(10,2);

COMMENT ON COLUMN packages.price_infant IS
  'Price per infant (under 2 years old). NULL = infants travel free / not priced separately.';

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS infants_count INTEGER NOT NULL DEFAULT 0 CHECK (infants_count >= 0);

COMMENT ON COLUMN bookings.infants_count IS
  'Number of infant travelers (under 2 years old) on this booking.';
