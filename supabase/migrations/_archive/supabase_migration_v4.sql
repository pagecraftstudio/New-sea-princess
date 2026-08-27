-- ══════════════════════════════════════════════════════════════
--  NSP Migration v4
--  1. flight_ticket_price on packages
--  2. mecca_rooms / madina_rooms JSONB on bookings (multi-room)
--  3. documents_config already JSONB — now stores adult/child/infant sub-objects
-- ══════════════════════════════════════════════════════════════

-- 1. Flight ticket price per person (0 = included in package price)
ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS flight_ticket_price NUMERIC(10,2) DEFAULT 0;

-- 2. Multi-room selections on bookings
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS mecca_rooms  JSONB,
  ADD COLUMN IF NOT EXISTS madina_rooms JSONB;

-- Verify
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('packages','bookings')
  AND column_name IN ('flight_ticket_price','mecca_rooms','madina_rooms')
ORDER BY table_name, column_name;
