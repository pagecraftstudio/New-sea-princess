-- Add price_child and price_infant columns if they don't exist
-- Safe additive migration
ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS price_child  NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS price_infant NUMERIC(12,2) DEFAULT 0;

-- Add any other columns that may be missing from live DB
ALTER TABLE packages
  ADD COLUMN IF NOT EXISTS flight_ticket_price NUMERIC(10,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discount_percent     INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS transport_type       TEXT,
  ADD COLUMN IF NOT EXISTS airline              TEXT;

-- Restore full select support in bookings
COMMENT ON COLUMN packages.price_child  IS 'سعر الطفل لكل شخص';
COMMENT ON COLUMN packages.price_infant IS 'سعر الرضيع لكل شخص';
