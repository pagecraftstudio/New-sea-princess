-- ============================================================
-- Migration 202601062000000 — P2: Data Integrity & Architecture
--
-- P2.1 Communication send status accuracy
--      Removes false 'sent' on channels with no actual send API.
--      WhatsApp/SMS/in_app → 'pending_manual'
--      Email without RESEND_API_KEY → 'not_configured'
--
-- P2.2 B2B partner architecture — canonical resolution
--      CANONICAL: partner_portal_users (queried by frontend)
--      LEGACY:    partner_users (used only by get_my_partner_id RLS)
--      Fix: redirect get_my_partner_id() to read partner_portal_users
--      so RLS policies work for actual portal users.
--
-- P2.3 Duplicate object cleanup
--      Triggers: all are CREATE OR REPLACE / DROP IF EXISTS already —
--      confirmed safe via migration review.
--      Policies: duplicates already resolved by migration 043 (_v2 names).
--      No additional action needed.
--
-- Safe: additive where possible; DROP+CREATE only for broken objects
-- Run after: 202601061000000_p1_corrective_automation_cooldown.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- P2.1 — Communication statuses: add accurate status values
--
-- The communication_queue table uses a status CHECK constraint.
-- We need to extend it to include accurate non-send states.
-- ─────────────────────────────────────────────────────────────

-- Widen the status constraint to include accurate states
-- (DROP + ADD because PostgreSQL cannot ALTER a CHECK constraint)
ALTER TABLE communication_queue
  DROP CONSTRAINT IF EXISTS communication_queue_status_check;

ALTER TABLE communication_queue
  ADD CONSTRAINT communication_queue_status_check
    CHECK (status IN (
      'queued',           -- waiting to be sent
      'sending',          -- in-flight
      'sent',             -- confirmed sent by provider
      'delivered',        -- confirmed delivered (where supported)
      'failed',           -- provider returned error
      'not_configured',   -- required env var / API key missing
      'pending_manual',   -- no API; requires manual staff action (WhatsApp/SMS)
      'cancelled'         -- explicitly cancelled before send
    ));

-- Fix any historical records incorrectly marked 'sent' for non-email channels
-- These would have been logged as 'sent' by the old edge function logic.
-- We cannot know if they were actually sent, so mark them 'pending_manual'
-- to be honest. Admins can review and update to 'sent' if confirmed.
UPDATE communication_queue
SET status = 'pending_manual'
WHERE channel IN ('whatsapp', 'sms', 'in_app')
  AND status = 'sent'
  AND external_id IS NULL;  -- no provider confirmation ID = was never truly sent

-- Add a status_reason column to record WHY a message is in a given state
ALTER TABLE communication_queue
  ADD COLUMN IF NOT EXISTS status_reason TEXT;   -- e.g. "RESEND_API_KEY not set"

-- ─────────────────────────────────────────────────────────────
-- P2.2 — B2B Architecture: fix get_my_partner_id()
--
-- CANONICAL table: partner_portal_users
--   - Used by frontend (partner-auth.js)
--   - Has role: admin/member/readonly
--   - Has contact_id link
--   - Created in migration 042
--
-- LEGACY table: partner_users
--   - Created in migration 041500
--   - Has role: owner/manager/viewer
--   - NOT used by any frontend page
--   - Only referenced by get_my_partner_id() RLS helper
--   - Therefore: RLS was broken for all portal users
--
-- Fix: redirect get_my_partner_id() to canonical table
-- ─────────────────────────────────────────────────────────────

-- Drop and recreate to fix source table
DROP FUNCTION IF EXISTS get_my_partner_id();

CREATE OR REPLACE FUNCTION get_my_partner_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- CANONICAL: reads partner_portal_users (queried by frontend)
  -- Legacy partner_users table is not used by any frontend page.
  SELECT partner_id
  FROM partner_portal_users
  WHERE user_id   = auth.uid()
    AND is_active = TRUE
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_my_partner_id() TO authenticated;

COMMENT ON FUNCTION get_my_partner_id() IS
'Returns the b2b_partners.id for the currently authenticated portal user.
CANONICAL source: partner_portal_users (not the legacy partner_users table).
Used by RLS policies on partner_inquiries, quotations, bookings, etc.
P2.2 fix: was incorrectly reading from legacy partner_users table.';

-- ─────────────────────────────────────────────────────────────
-- P2.2 — Document legacy partner_users table
--
-- partner_users is NOT dropped because:
--   a) It may have data in applied environments
--   b) DROP would be destructive and irreversible
--   c) It causes no functional harm since nothing queries it
--
-- Instead: add a comment marking it deprecated.
-- A future cleanup migration can DROP it after confirming zero rows.
-- ─────────────────────────────────────────────────────────────

-- Guard: partner_users may not exist in all environments.
-- Migration 202601041500000 was a duplicate-versioned migration that may
-- have been skipped by Supabase if 202601041000000 was already applied.
-- Therefore we check existence before commenting.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'partner_users'
  ) THEN
    COMMENT ON TABLE partner_users IS
    'DEPRECATED (P2.2). Legacy table from migration 041500.
CANONICAL replacement: partner_portal_users (migration 042).
Frontend (partner-auth.js) queries partner_portal_users only.
get_my_partner_id() now reads partner_portal_users.
Safe to DROP in a future cleanup migration after confirming zero rows
or after migrating any existing rows to partner_portal_users.';
  ELSE
    RAISE NOTICE 'partner_users table does not exist — COMMENT skipped. This is expected when migration 041500 was not applied.';
  END IF;
END
$$;

-- ─────────────────────────────────────────────────────────────
-- P2.3 — Duplicate trigger cleanup
--
-- Triggers listed as duplicates are all guarded by
-- DROP TRIGGER IF EXISTS before CREATE TRIGGER in their respective
-- migrations, which is correct CREATE OR REPLACE pattern for triggers.
-- At runtime only one trigger exists per (table, trigger_name).
-- No corrective action needed — confirming safe.
--
-- Duplicate policies: already resolved by migration 043 which drops
-- the originals and creates _v2 variants. Confirmed safe.
-- ─────────────────────────────────────────────────────────────

-- Verify the RLS fix works: add a test-friendly helper
CREATE OR REPLACE FUNCTION get_partner_portal_user()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_row partner_portal_users%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM partner_portal_users
  WHERE user_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN json_build_object(
    'id',         v_row.id,
    'partner_id', v_row.partner_id,
    'role',       v_row.role
  );
END;$$;

REVOKE ALL ON FUNCTION get_partner_portal_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_partner_portal_user() TO authenticated;

COMMENT ON FUNCTION get_partner_portal_user() IS
'Returns minimal portal user context for the authenticated user.
Used by partner portal pages to verify session. P2.2.';

-- ══ END P2 MIGRATION ═════════════════════════════════════════
-- Verify:
--
-- P2.1:
--   SELECT status, count(*) FROM communication_queue GROUP BY status;
--   → should not include 'sent' for whatsapp/sms/in_app with null external_id
--
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='communication_queue' AND column_name='status_reason';
--   → 1 row
--
-- P2.2:
--   SELECT prosrc FROM pg_proc WHERE proname = 'get_my_partner_id';
--   → should reference 'partner_portal_users' not 'partner_users'
--
-- P2.3:
--   SELECT tablename, policyname FROM pg_policies
--   WHERE policyname IN ('quotations_partner_read','bookings_partner_read');
--   → 0 rows (replaced by _v2 in migration 043)
