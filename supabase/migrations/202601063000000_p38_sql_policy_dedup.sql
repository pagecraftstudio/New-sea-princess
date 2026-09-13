-- ============================================================
-- Migration 202601063000000_p38_sql_policy_dedup.sql
-- P3.8 SQL Validation Fix — Unguarded Duplicate Policies
--
-- Context:
--   202601041500000_phase8_b2b_portal.sql creates policies
--   pqa_admin, pqa_partner_read, pqa_partner_insert on
--   partner_quote_actions using get_my_partner_id() RLS helper.
--
--   202601042000000_phase8_b2b_portal.sql re-creates the same
--   three policies with a different (direct) implementation,
--   without DROP POLICY guards. On a fresh install this causes:
--     ERROR: policy "pqa_admin" for table "partner_quote_actions" already exists
--
--   This migration is idempotent. It drops then re-creates the
--   canonical versions (using partner_portal_users directly,
--   consistent with p2_data_integrity.sql and p1_security_hardening.sql).
-- ============================================================

-- Drop all three policies idempotently, then re-create canonical versions.
-- Safe: partner_portal_users is the canonical table (confirmed in p2_data_integrity.sql).

DROP POLICY IF EXISTS "pqa_admin"          ON partner_quote_actions;
DROP POLICY IF EXISTS "pqa_partner_read"   ON partner_quote_actions;
DROP POLICY IF EXISTS "pqa_partner_insert" ON partner_quote_actions;
DROP POLICY IF EXISTS "pqa_partner_update" ON partner_quote_actions;

-- Admin: full access
CREATE POLICY "pqa_admin" ON partner_quote_actions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- Partner read: via partner_portal_users (canonical)
CREATE POLICY "pqa_partner_read" ON partner_quote_actions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id    = auth.uid()
        AND ppu.partner_id = partner_quote_actions.partner_id
        AND ppu.is_active  = TRUE
    )
  );

-- Partner insert: via partner_portal_users (canonical)
CREATE POLICY "pqa_partner_insert" ON partner_quote_actions FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id    = auth.uid()
        AND ppu.partner_id = partner_quote_actions.partner_id
        AND ppu.is_active  = TRUE
    )
  );

-- Partner update (was added in 043 but may be missing if 041500→042 conflict blocked 043)
CREATE POLICY "pqa_partner_update" ON partner_quote_actions FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id    = auth.uid()
        AND ppu.partner_id = partner_quote_actions.partner_id
        AND ppu.is_active  = TRUE
    )
  );

SELECT 'Migration 202601063000000: partner_quote_actions policies reconciled' AS status;
