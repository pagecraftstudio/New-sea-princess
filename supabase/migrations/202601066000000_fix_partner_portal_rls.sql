-- ══════════════════════════════════════════════════════════════════════════
--  Migration 202601066000000 — Fix partner portal: get_my_partner_id + RLS
--
--  BUGS:
--  1. partner_inquiries returns empty: get_my_partner_id() reads from
--     legacy "partner_users" table but canonical table is
--     "partner_portal_users". Result: function returns NULL → all RLS
--     policies that use get_my_partner_id() block ALL partner rows.
--
--  2. /partners/quotes.html was requesting column "valid_until" which
--     doesn't exist on quotations (correct column: "validity_date").
--     Fixed in frontend; this migration fixes the DB side if any view/RPC
--     also referenced it.
--
--  FIX: Re-create get_my_partner_id() to read partner_portal_users.
--       Safe to run multiple times (CREATE OR REPLACE).
-- ══════════════════════════════════════════════════════════════════════════

-- Drop old version regardless of signature
DROP FUNCTION IF EXISTS get_my_partner_id();

CREATE OR REPLACE FUNCTION get_my_partner_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT partner_id
  FROM   partner_portal_users
  WHERE  user_id   = auth.uid()
    AND  is_active = TRUE
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_my_partner_id() TO authenticated;
GRANT EXECUTE ON FUNCTION get_my_partner_id() TO anon;

COMMENT ON FUNCTION get_my_partner_id() IS
  'Returns the b2b_partners.id for the currently authenticated partner user. '
  'Reads partner_portal_users (canonical table). '
  'Used by all partner-portal RLS policies. '
  'Returns NULL if caller is not a partner (e.g. admin users).';

-- ── Verify fix by checking the function exists and reads correct table ────
-- Run in SQL Editor after applying:
--   SELECT get_my_partner_id();
--   -- Should return a UUID (or NULL if you run as admin, which is correct)
--
--   SELECT partner_id FROM partner_portal_users
--   WHERE user_id = auth.uid() AND is_active = TRUE LIMIT 1;
--   -- Should return same UUID
