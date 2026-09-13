-- ============================================================
-- Migration 044 — Phase 8 Completion Fixes
--
-- Fixes column-name mismatch: get_partner_dashboard() and
-- get_partner_quotes() were written against bookings.partner_id
-- and quotations.partner_id, but migration 043 renamed them to
-- b2b_partner_id. This patch recreates both RPCs using the
-- correct column names.
--
-- Also adds partner_portal_users last_login UPDATE policy
-- (missing from 042) and a get_my_partner_portal_id() helper
-- used by the admin portal-users management page.
--
-- Safe: CREATE OR REPLACE only — no destructive changes.
-- Run after: 202601043000000_phase8_portal_complete.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. Fix get_partner_dashboard() — use b2b_partner_id columns
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_partner_dashboard()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_partner_id UUID;
  v_result     JSON;
BEGIN
  v_partner_id := get_my_partner_id();
  IF v_partner_id IS NULL THEN
    RETURN '{"error":"not_a_partner"}'::JSON;
  END IF;

  SELECT json_build_object(
    'partner_id',         v_partner_id,
    'open_inquiries',     (SELECT COUNT(*) FROM partner_inquiries
                           WHERE partner_id = v_partner_id
                             AND status NOT IN ('won','lost','cancelled')),
    'pending_quotes',     (SELECT COUNT(*) FROM quotations
                           WHERE b2b_partner_id = v_partner_id
                             AND status IN ('sent','viewed','revision_requested','negotiation')),
    'active_bookings',    (SELECT COUNT(*) FROM bookings
                           WHERE b2b_partner_id = v_partner_id
                             AND status IN ('confirmed','pending')),
    'completed_bookings', (SELECT COUNT(*) FROM bookings
                           WHERE b2b_partner_id = v_partner_id
                             AND status = 'completed'),
    'total_invoices',     (SELECT COUNT(*) FROM nsp_invoices i
                           JOIN bookings b ON b.id = i.booking_id
                           WHERE b.b2b_partner_id = v_partner_id),
    'outstanding_amount', (SELECT COALESCE(SUM(i.remaining_amount), 0)
                           FROM nsp_invoices i
                           JOIN bookings b ON b.id = i.booking_id
                           WHERE b.b2b_partner_id = v_partner_id
                             AND i.status NOT IN ('paid','cancelled'))
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_dashboard() TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2. Fix get_partner_quotes() — use b2b_partner_id + validity_date
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_partner_quotes()
RETURNS TABLE (
  id                  UUID,
  quote_number        TEXT,
  title               TEXT,
  destination         TEXT,
  travel_date_from    DATE,
  travel_date_to      DATE,
  adults_count        INT,
  children_count      INT,
  currency            TEXT,
  total_amount        NUMERIC,
  status              TEXT,
  validity_date       DATE,
  payment_terms       TEXT,
  cancellation_policy TEXT,
  included_services   TEXT,
  excluded_services   TEXT,
  client_notes        TEXT,
  sent_at             TIMESTAMPTZ,
  created_at          TIMESTAMPTZ,
  version             INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_partner_id UUID;
BEGIN
  v_partner_id := get_my_partner_id();
  IF v_partner_id IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    q.id, q.quote_number, q.title, q.destination,
    q.travel_date_from, q.travel_date_to,
    q.adults_count, q.children_count,
    q.currency, q.total_amount,
    q.status, q.validity_date,
    q.payment_terms, q.cancellation_policy,
    q.included_services, q.excluded_services,
    q.client_notes, q.sent_at, q.created_at, q.version
    -- cost_total, gross_profit, margin_pct intentionally excluded
  FROM quotations q
  WHERE q.b2b_partner_id = v_partner_id
    AND q.status NOT IN ('draft','internal_review','cancelled')
  ORDER BY q.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_quotes() TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3. Fix partner_portal_users — add UPDATE policy for last_login
-- ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='partner_portal_users' AND policyname='ppu_self_update'
  ) THEN
    CREATE POLICY "ppu_self_update" ON partner_portal_users
      FOR UPDATE
      USING (user_id = auth.uid());
  END IF;
END$$;


-- ─────────────────────────────────────────────────────────────
-- 4. Admin helper: list portal users for a given partner
--    Used by the admin partner-portal management page.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_partner_portal_users(p_partner_id UUID)
RETURNS TABLE (
  id           UUID,
  user_id      UUID,
  email        TEXT,
  full_name    TEXT,
  role         TEXT,
  is_active    BOOLEAN,
  last_login_at TIMESTAMPTZ,
  invited_at   TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Admin only
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN QUERY
  SELECT
    ppu.id,
    ppu.user_id,
    au.email,
    (au.raw_user_meta_data->>'full_name')::TEXT AS full_name,
    ppu.role,
    ppu.is_active,
    ppu.last_login_at,
    ppu.invited_at
  FROM partner_portal_users ppu
  JOIN auth.users au ON au.id = ppu.user_id
  WHERE ppu.partner_id = p_partner_id
  ORDER BY ppu.invited_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_portal_users(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 5. Admin helper: create portal user for a partner
--    Creates a Supabase auth user + partner_portal_users row.
--    Note: actual user creation must be done via Supabase Admin API
--    or Magic Link. This function inserts the portal_users record
--    after the auth user is created via the admin API call.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION link_partner_portal_user(
  p_partner_id UUID,
  p_user_id    UUID,
  p_role       TEXT DEFAULT 'member'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  INSERT INTO partner_portal_users (user_id, partner_id, role, invited_by)
  VALUES (p_user_id, p_partner_id, p_role, auth.uid())
  ON CONFLICT (user_id, partner_id)
  DO UPDATE SET is_active = TRUE, role = p_role, invited_by = auth.uid()
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION link_partner_portal_user(UUID, UUID, TEXT) TO authenticated;


-- ── END MIGRATION 044 ══════════════════════════════════════════
-- Verify:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name IN (
--     'get_partner_dashboard','get_partner_quotes',
--     'get_partner_portal_users','link_partner_portal_user'
--   );
--   → 4 rows
