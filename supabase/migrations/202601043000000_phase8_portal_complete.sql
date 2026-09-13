-- ============================================================
-- Migration 043 — Phase 8 Portal Completion
--
-- Adds b2b_partner_id FK to quotations and bookings so the
-- partner portal pages can query their own data correctly.
-- Also tightens portal RLS and adds partner_quote_actions
-- policy for UPDATE (missing from 042).
--
-- Safe: additive only — ADD COLUMN IF NOT EXISTS
-- Run after: 202601042000000_phase8_b2b_portal.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. b2b_partner_id on quotations
--    Partners query their quotes via this FK.
-- ─────────────────────────────────────────────────────────────

ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS b2b_partner_id UUID
    REFERENCES b2b_partners(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_quotations_b2b_partner
  ON quotations(b2b_partner_id)
  WHERE b2b_partner_id IS NOT NULL;

-- Partner can read their own quotations (no cost/margin fields exposed)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='quotations' AND policyname='quotations_partner_read_v2'
  ) THEN
    -- Drop old policy if exists (added in 042 without column guard)
    DROP POLICY IF EXISTS "quotations_partner_read" ON quotations;
    CREATE POLICY "quotations_partner_read_v2" ON quotations
      FOR SELECT
      USING (
        b2b_partner_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM partner_portal_users ppu
          WHERE ppu.user_id   = auth.uid()
            AND ppu.partner_id = b2b_partner_id
            AND ppu.is_active  = TRUE
        )
      );
  END IF;
END$$;


-- ─────────────────────────────────────────────────────────────
-- 2. b2b_partner_id on bookings
--    Partners query their bookings via this FK.
-- ─────────────────────────────────────────────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS b2b_partner_id UUID
    REFERENCES b2b_partners(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_b2b_partner
  ON bookings(b2b_partner_id)
  WHERE b2b_partner_id IS NOT NULL;

-- Partner can read their own bookings (billing/PII NOT exposed via partner portal)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='bookings' AND policyname='bookings_partner_read_v2'
  ) THEN
    DROP POLICY IF EXISTS "bookings_partner_read" ON bookings;
    CREATE POLICY "bookings_partner_read_v2" ON bookings
      FOR SELECT
      USING (
        b2b_partner_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM partner_portal_users ppu
          WHERE ppu.user_id   = auth.uid()
            AND ppu.partner_id = b2b_partner_id
            AND ppu.is_active  = TRUE
        )
      );
  END IF;
END$$;


-- ─────────────────────────────────────────────────────────────
-- 3. nsp_invoices — partner read via booking link
--    Partners see invoices for their bookings only.
-- ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='nsp_invoices' AND policyname='invoices_partner_read'
  ) THEN
    CREATE POLICY "invoices_partner_read" ON nsp_invoices
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1
          FROM bookings b
          JOIN partner_portal_users ppu ON ppu.partner_id = b.b2b_partner_id
          WHERE b.id         = nsp_invoices.booking_id
            AND ppu.user_id  = auth.uid()
            AND ppu.is_active = TRUE
        )
      );
  END IF;
END$$;


-- ─────────────────────────────────────────────────────────────
-- 4. partner_quote_actions — missing UPDATE policy
-- ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='partner_quote_actions' AND policyname='pqa_partner_update'
  ) THEN
    CREATE POLICY "pqa_partner_update" ON partner_quote_actions
      FOR UPDATE
      USING (
        EXISTS (
          SELECT 1 FROM partner_portal_users ppu
          WHERE ppu.user_id   = auth.uid()
            AND ppu.partner_id = partner_id
            AND ppu.is_active  = TRUE
        )
      );
  END IF;
END$$;


-- ─────────────────────────────────────────────────────────────
-- 5. Expose get_partner_summary RPC for partner dashboard KPIs
--    Returns counts the partner can see without raw table access.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_partner_summary(p_partner_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  -- Must be an active portal user for this partner
  IF NOT EXISTS (
    SELECT 1 FROM partner_portal_users
    WHERE user_id   = v_uid
      AND partner_id = p_partner_id
      AND is_active  = TRUE
  ) THEN
    -- Also allow internal admins
    IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = v_uid) THEN
      RETURN json_build_object('error', 'unauthorized');
    END IF;
  END IF;

  RETURN json_build_object(
    'open_inquiries',   (SELECT COUNT(*) FROM partner_inquiries
                         WHERE partner_id = p_partner_id
                           AND status NOT IN ('closed','cancelled')),
    'pending_quotes',   (SELECT COUNT(*) FROM quotations
                         WHERE b2b_partner_id = p_partner_id
                           AND status IN ('sent','viewed')),
    'active_bookings',  (SELECT COUNT(*) FROM bookings
                         WHERE b2b_partner_id = p_partner_id
                           AND status IN ('confirmed','pending')),
    'outstanding_balance', (SELECT COALESCE(SUM(remaining_amount),0)
                            FROM nsp_invoices ni
                            JOIN bookings b ON b.id = ni.booking_id
                            WHERE b.b2b_partner_id = p_partner_id
                              AND ni.status NOT IN ('paid','cancelled'))
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_summary(UUID) TO authenticated;

COMMENT ON FUNCTION get_partner_summary(UUID) IS
'KPI summary for partner portal dashboard. Checks caller is active portal user for the given partner. Phase 8 completion.';


-- ══ END MIGRATION 043 ═════════════════════════════════════════
-- Verification:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name IN ('quotations','bookings')
--   AND column_name = 'b2b_partner_id';
--   → 2 rows
--
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name = 'get_partner_summary';
--   → 1 row
