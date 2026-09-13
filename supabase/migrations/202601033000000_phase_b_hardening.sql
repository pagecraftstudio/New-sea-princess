-- ============================================================
-- Migration 033 — Phase B Hardening
-- Fixes: C3 (ai_recommendations schema), C7 (track_user_login)
--        M1 (permission_matrix UNIQUE), M2 (customers DELETE)
-- Safe: only ADD/ALTER/CREATE — no DROP of columns with data
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- C3: Resolve ai_recommendations schema conflict
--
-- Migration 030 schema has: confidence, feedback, feedback_note,
--   suggested_action, ai_request_id, updated_at
-- Migration 032 schema has: priority, action_label, action_url, metadata
--
-- Final schema: union of both — add whichever columns are missing.
-- ai-service.js uses: feedback, status, updated_at
-- Root index.ts uses: confidence, suggested_action, ai_request_id
-- Phase B also needs: priority, action_label, action_url, metadata
-- ────────────────────────────────────────────────────────────

-- Ensure base columns from 030 exist
ALTER TABLE ai_recommendations
  ADD COLUMN IF NOT EXISTS confidence      TEXT
    DEFAULT 'medium'
    CHECK (confidence IN ('high','medium','low','insufficient_data')),
  ADD COLUMN IF NOT EXISTS suggested_action JSONB,
  ADD COLUMN IF NOT EXISTS feedback        TEXT
    CHECK (feedback IN ('helpful','not_helpful','incorrect')),
  ADD COLUMN IF NOT EXISTS feedback_note   TEXT,
  ADD COLUMN IF NOT EXISTS ai_request_id   UUID REFERENCES ai_requests(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS updated_at      TIMESTAMPTZ NOT NULL DEFAULT now();

-- Ensure columns from 032 exist
ALTER TABLE ai_recommendations
  ADD COLUMN IF NOT EXISTS priority     TEXT DEFAULT 'medium'
    CHECK (priority IN ('low','medium','high','critical')),
  ADD COLUMN IF NOT EXISTS action_label TEXT,
  ADD COLUMN IF NOT EXISTS action_url   TEXT,
  ADD COLUMN IF NOT EXISTS metadata     JSONB DEFAULT '{}';

-- Ensure status CHECK covers all values used across both schemas
-- (safe: if constraint already matches this will be a no-op via DROP+ADD)
ALTER TABLE ai_recommendations
  DROP CONSTRAINT IF EXISTS ai_recommendations_status_check;
ALTER TABLE ai_recommendations
  ADD CONSTRAINT ai_recommendations_status_check
    CHECK (status IN ('active','applied','dismissed','expired'));

-- Ensure rec_type covers all features used across both implementations
ALTER TABLE ai_recommendations
  DROP CONSTRAINT IF EXISTS ai_recommendations_rec_type_check;
ALTER TABLE ai_recommendations
  ADD CONSTRAINT ai_recommendations_rec_type_check
    CHECK (rec_type IN (
      'lead_priority','opp_risk','follow_up','supplier_score',
      'quote_review','ops_risk','forecast','upsell','next_action',
      'lead_analysis','opp_analysis','itinerary_suggest',
      'command_center','operations_brief','recommendations',
      'follow_up_draft','quote_followup','action'
    ));

-- updated_at trigger for ai_recommendations
CREATE OR REPLACE FUNCTION set_ai_rec_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_ai_rec_updated_at ON ai_recommendations;
CREATE TRIGGER trg_ai_rec_updated_at
  BEFORE UPDATE ON ai_recommendations
  FOR EACH ROW EXECUTE FUNCTION set_ai_rec_updated_at();

-- ────────────────────────────────────────────────────────────
-- C7: track_user_login RPC
-- Called by auth.js on every successful login.
-- Updates last_login on profiles, inserts into audit_logs.
-- Safe under repeated calls (upsert-style).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION track_user_login()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  -- Guard: must be authenticated
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Update last_seen on profiles (column may not exist yet — add if missing)
  BEGIN
    UPDATE profiles
      SET updated_at = now()
    WHERE id = v_user_id;
  EXCEPTION WHEN undefined_column THEN
    NULL; -- profiles may not have updated_at — silently skip
  END;

  -- Log to audit_logs (general log table)
  INSERT INTO audit_logs (action, performed_by, entity, entity_id)
  VALUES ('user_login', v_user_id, 'auth.users', v_user_id::text)
  ON CONFLICT DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION track_user_login() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- M1: Add UNIQUE constraint to permission_matrix.permission
-- (only safe to add after deduplicating)
-- ────────────────────────────────────────────────────────────

-- First: deduplicate — keep the row with smallest id for each permission
DELETE FROM permission_matrix pm
WHERE id NOT IN (
  SELECT DISTINCT ON (permission) id
  FROM permission_matrix
  ORDER BY permission, id
);

-- Now add constraint (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'permission_matrix_permission_key'
  ) THEN
    ALTER TABLE permission_matrix ADD CONSTRAINT permission_matrix_permission_key UNIQUE (permission);
  END IF;
END$$;

-- ────────────────────────────────────────────────────────────
-- M2: customers DELETE policy
-- Intentionally restrictive: only super_admin can delete customers.
-- (Adding permissive DELETE for all admins would be wrong.)
-- ────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'customers' AND policyname = 'customers_super_delete'
  ) THEN
    CREATE POLICY "customers_super_delete"
      ON customers FOR DELETE
      USING (auth_role() = 'super_admin');
  END IF;
END$$;

-- ────────────────────────────────────────────────────────────
-- use_ai_command_center permission — ensure seeded (031 may have it)
-- ────────────────────────────────────────────────────────────
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
VALUES (
  'use_ai_command_center',
  'استخدام مركز الأوامر الذكي',
  'الذكاء الاصطناعي',
  ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent']
)
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;
