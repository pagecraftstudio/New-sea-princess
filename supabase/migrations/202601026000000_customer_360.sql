-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 2 MIGRATION — Customer 360 & B2C CRM
--  File: supabase/migrations/202601026000000_customer_360.sql
--
--  Purpose: Extend customers table for full 360° profile.
--           Link reviews to customers. Add summary view.
--           All changes are purely additive — no drops, no renames.
--
--  Run after: 202601025000000_crm_foundation.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. EXTEND customers TABLE — personal + preferences + computed fields
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE customers
  -- Personal data
  ADD COLUMN IF NOT EXISTS passport_number     TEXT,
  ADD COLUMN IF NOT EXISTS passport_expiry     DATE,
  ADD COLUMN IF NOT EXISTS date_of_birth       DATE,
  ADD COLUMN IF NOT EXISTS gender              TEXT CHECK (gender IN ('male','female','other')),

  -- Preferences
  ADD COLUMN IF NOT EXISTS preferred_hotel_type  TEXT CHECK (preferred_hotel_type IN ('budget','standard','superior','deluxe','luxury')),
  ADD COLUMN IF NOT EXISTS preferred_room_type   TEXT CHECK (preferred_room_type IN ('single','double','triple','quad')),
  ADD COLUMN IF NOT EXISTS guide_language        TEXT,
  ADD COLUMN IF NOT EXISTS transport_preference  TEXT CHECK (transport_preference IN ('private','shared','any')),
  ADD COLUMN IF NOT EXISTS dietary_requirements  TEXT,
  ADD COLUMN IF NOT EXISTS interests             TEXT[],   -- e.g. ARRAY['religious','cultural','adventure']

  -- Tagging + segmentation
  ADD COLUMN IF NOT EXISTS tags                  TEXT[],   -- free tags: vip / family / honeymoon etc.

  -- Computed/cached financials (updated by trigger below)
  ADD COLUMN IF NOT EXISTS total_bookings        INT     DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_spent           NUMERIC(18,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_outstanding     NUMERIC(18,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_trip_date        DATE;

COMMENT ON COLUMN customers.interests IS 'Array of travel interest tags: religious/cultural/adventure/beach/family/luxury/wildlife';
COMMENT ON COLUMN customers.tags IS 'Free-form admin tags attached to this customer';
COMMENT ON COLUMN customers.total_bookings IS 'Cached count of bookings; refreshed by trg_customer_stats';
COMMENT ON COLUMN customers.total_spent IS 'Cached sum of booking total_price; refreshed by trg_customer_stats';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. LINK reviews TO customers (nullable — existing rows unaffected)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE reviews
  ADD COLUMN IF NOT EXISTS customer_id UUID REFERENCES customers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_reviews_customer_id ON reviews(customer_id) WHERE customer_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. LINK nsp_invoices, nsp_payments, refunds TO customers
--    (these tables already have customer_id → auth.users; we add a separate
--     customer_rec_id → customers to avoid breaking existing FK/RLS)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE nsp_invoices
  ADD COLUMN IF NOT EXISTS customer_rec_id UUID REFERENCES customers(id) ON DELETE SET NULL;

ALTER TABLE nsp_payments
  ADD COLUMN IF NOT EXISTS customer_rec_id UUID REFERENCES customers(id) ON DELETE SET NULL;

ALTER TABLE refunds
  ADD COLUMN IF NOT EXISTS customer_rec_id UUID REFERENCES customers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_invoices_customer_rec    ON nsp_invoices(customer_rec_id) WHERE customer_rec_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_payments_customer_rec    ON nsp_payments(customer_rec_id) WHERE customer_rec_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_refunds_customer_rec     ON refunds(customer_rec_id)      WHERE customer_rec_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. CUSTOMER SEGMENTS — standard values as reference
--    segment column already exists (TEXT) — no schema change needed.
--    Document valid values here for clarity.
-- ─────────────────────────────────────────────────────────────────────────────
-- Valid segment values (enforced in UI, not as DB constraint to allow flexibility):
--   new / returning / vip / high_ltv / family / couple / honeymoon
--   adventure / luxury / religious / corporate / dormant


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. FUNCTION: refresh_customer_stats()
--    Called by trigger on bookings INSERT/UPDATE/DELETE to keep cached fields
--    in sync. Uses customer_id FK added in Phase 1 (025 migration).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION refresh_customer_stats()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_customer_id UUID;
  v_count       INT;
  v_spent       NUMERIC(18,2);
  v_outstanding NUMERIC(18,2);
  v_last_trip   DATE;
BEGIN
  -- Determine which customer_id changed
  v_customer_id := COALESCE(NEW.customer_id, OLD.customer_id);
  IF v_customer_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT
    COUNT(*)                                       INTO v_count
  FROM bookings
  WHERE customer_id = v_customer_id
    AND status NOT IN ('cancelled');

  SELECT
    COALESCE(SUM(total_price), 0),
    COALESCE(SUM(remaining_amount), 0),
    MAX(CASE WHEN status IN ('confirmed','completed') THEN departure_date END)
  INTO v_spent, v_outstanding, v_last_trip
  FROM bookings
  WHERE customer_id = v_customer_id
    AND status NOT IN ('cancelled');

  UPDATE customers SET
    total_bookings    = v_count,
    total_spent       = v_spent,
    total_outstanding = v_outstanding,
    last_trip_date    = v_last_trip,
    updated_at        = now()
  WHERE id = v_customer_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach trigger to bookings
DROP TRIGGER IF EXISTS trg_customer_stats ON bookings;
CREATE TRIGGER trg_customer_stats
  AFTER INSERT OR UPDATE OF customer_id, total_price, remaining_amount, status
  OR DELETE ON bookings
  FOR EACH ROW EXECUTE FUNCTION refresh_customer_stats();


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. VIEW: customer_360_summary
--    Joins customers with live booking/invoice/lead counts.
--    Used by the Customer 360 list page.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW customer_360_summary AS
SELECT
  c.id,
  c.customer_number,
  c.full_name,
  c.email,
  c.phone,
  c.whatsapp,
  c.nationality,
  c.language,
  c.customer_type,
  c.segment,
  c.source,
  c.vip,
  c.tags,
  c.interests,
  c.total_bookings,
  c.total_spent,
  c.total_outstanding,
  c.last_trip_date,
  c.created_at,
  c.updated_at,

  -- Live lead count
  (SELECT COUNT(*) FROM leads l WHERE l.customer_id = c.id AND l.status NOT IN ('won','lost')) AS open_leads,

  -- Live opportunity count
  (SELECT COUNT(*) FROM opportunities o WHERE o.customer_id = c.id AND o.stage NOT IN ('won','lost')) AS open_opportunities,

  -- Invoice outstanding (from nsp_invoices via customer_rec_id)
  COALESCE((
    SELECT SUM(remaining_amount)
    FROM nsp_invoices
    WHERE customer_rec_id = c.id
      AND status NOT IN ('paid','cancelled','refunded')
  ), 0) AS invoice_outstanding,

  -- Review count
  (SELECT COUNT(*) FROM reviews r WHERE r.customer_id = c.id AND r.is_approved) AS review_count,

  -- Linked auth user
  c.user_id

FROM customers c;

GRANT SELECT ON customer_360_summary TO authenticated;

COMMENT ON VIEW customer_360_summary IS
  'Enriched customer list for the Customer 360 admin page. '
  'Combines cached stats with live counts for leads, opportunities, invoices.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. RLS — new columns inherit existing customers policies (no change needed)
--    Verify existing policies still cover SELECT/INSERT/UPDATE on customers.
-- ─────────────────────────────────────────────────────────────────────────────
-- customers_admin_read  → FOR SELECT USING (can_read_bookings())   ✓
-- customers_admin_write → FOR INSERT WITH CHECK (can_write_bookings()) ✓
-- customers_admin_update→ FOR UPDATE USING (can_write_bookings())  ✓
-- customers_self_read   → FOR SELECT USING (user_id = auth.uid())  ✓
-- All new columns are covered by existing row-level policies.


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION QUERIES (run manually in Supabase SQL Editor)
-- ─────────────────────────────────────────────────────────────────────────────

-- Check new columns exist:
-- SELECT column_name FROM information_schema.columns
-- WHERE table_name='customers' AND column_name IN
--   ('passport_number','passport_expiry','date_of_birth','gender',
--    'preferred_hotel_type','preferred_room_type','guide_language',
--    'transport_preference','dietary_requirements','interests','tags',
--    'total_bookings','total_spent','total_outstanding','last_trip_date');

-- Check view:
-- SELECT * FROM customer_360_summary LIMIT 1;

-- Check trigger:
-- SELECT trigger_name FROM information_schema.triggers WHERE trigger_name='trg_customer_stats';

-- ══ END PHASE 2 MIGRATION ════════════════════════════════════════════════════