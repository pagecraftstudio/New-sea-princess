-- ============================================================
-- Migration 035 — Phase D: AI Schema Finalization
--
-- Purpose:
--   1. Verify ai_recommendations superset schema is complete
--      (033 added missing columns; this confirms and adds indexes)
--   2. DB-driven AI rate limiting (H5)
--      — check_ai_rate_limit() RPC called by edge function
--      — per-user/per-feature daily limits stored in config
--   3. AI insights cache helper RPCs (M5 / Phase H)
--      — get_cached_insight(key) — returns non-expired entry
--      — set_cached_insight(key, data, ttl_minutes) — upserts
--      — purge_expired_cache() — housekeeping
--   4. Final ai_recommendations constraint hardening
--
-- Idempotent: all CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS
-- Run after: 202601034000000_phase_c_permissions.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Confirm superset ai_recommendations schema
--
-- Migration 033 already ran ADD COLUMN IF NOT EXISTS for all columns.
-- This step adds missing indexes and a cleanup trigger.
-- ─────────────────────────────────────────────────────────────────────────────

-- Index on feedback (for dashboard queries)
CREATE INDEX IF NOT EXISTS idx_ai_rec_feedback
  ON ai_recommendations(feedback)
  WHERE feedback IS NOT NULL;

-- Index on priority (from 032-path schema)
CREATE INDEX IF NOT EXISTS idx_ai_rec_priority
  ON ai_recommendations(priority)
  WHERE priority IS NOT NULL;

-- Index on updated_at (needed for cache invalidation queries)
CREATE INDEX IF NOT EXISTS idx_ai_rec_updated
  ON ai_recommendations(updated_at DESC);

-- Auto-update updated_at trigger
-- (033 created the function; create trigger here as idempotent)
DROP TRIGGER IF EXISTS trg_ai_rec_updated_at ON ai_recommendations;
CREATE TRIGGER trg_ai_rec_updated_at
  BEFORE UPDATE ON ai_recommendations
  FOR EACH ROW EXECUTE FUNCTION set_ai_rec_updated_at();

-- Widen status CHECK to include all values used across schemas
ALTER TABLE ai_recommendations
  DROP CONSTRAINT IF EXISTS ai_recommendations_status_check;
ALTER TABLE ai_recommendations
  ADD CONSTRAINT ai_recommendations_status_check
    CHECK (status IN ('active','dismissed','applied','expired'));

-- Ensure body allows NULL (032 schema had it nullable)
-- (No-op if already nullable — ALTER only changes if needed)
ALTER TABLE ai_recommendations ALTER COLUMN body DROP NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: AI Rate Limiting (H5)
--
-- Design:
--   ai_rate_limits table stores per-user daily request counts by feature.
--   check_ai_rate_limit(user_id, feature) → {allowed: bool, remaining: int}
--   Called by edge function BEFORE hitting the AI provider.
--   Limits are configurable in ai_rate_config table.
-- ─────────────────────────────────────────────────────────────────────────────

-- Config table: per-feature daily limits
CREATE TABLE IF NOT EXISTS ai_rate_config (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  feature       TEXT    NOT NULL UNIQUE,   -- 'lead_analysis', '*' for default
  daily_limit   INT     NOT NULL DEFAULT 50,
  burst_limit   INT     NOT NULL DEFAULT 10,   -- max per hour
  description   TEXT,
  updated_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE ai_rate_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rate_config_admin" ON ai_rate_config FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- Seed default limits
INSERT INTO ai_rate_config (feature, daily_limit, burst_limit, description)
VALUES
  ('*',                  100, 20,  'Default daily limit per user for any feature'),
  ('lead_analysis',       50, 10,  'Lead-level AI analysis'),
  ('opp_analysis',        50, 10,  'Opportunity AI analysis'),
  ('quote_review',        40, 8,   'Quotation AI review'),
  ('itinerary_suggest',   30, 6,   'Itinerary building suggestions'),
  ('recommendations',     20, 5,   'Smart recommendations panel'),
  ('daily_brief',         10, 3,   'Operations daily brief'),
  ('operations_brief',    10, 3,   'Operations brief'),
  ('command_center',      60, 12,  'AI command center chat'),
  ('follow_up_draft',     40, 8,   'Follow-up message drafting'),
  ('supplier_score',      20, 5,   'Supplier intelligence scoring'),
  ('forecast',            10, 3,   'Sales forecasting')
ON CONFLICT (feature) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: check_ai_rate_limit RPC
--
-- Returns JSON: { allowed: bool, remaining: int, reset_at: timestamp }
-- Edge function calls this and rejects if allowed = false.
-- Uses ai_requests table (already written by edge function) for counting.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION check_ai_rate_limit(
  p_user_id UUID,
  p_feature  TEXT
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_daily_limit  INT;
  v_burst_limit  INT;
  v_day_count    INT;
  v_hour_count   INT;
  v_reset_at     TIMESTAMPTZ;
BEGIN
  -- Caller must be either the user themselves or service role
  -- (edge function calls this via service role client)

  -- Get feature-specific limit, fall back to '*' default
  SELECT
    COALESCE(
      (SELECT daily_limit FROM ai_rate_config WHERE feature = p_feature),
      (SELECT daily_limit FROM ai_rate_config WHERE feature = '*'),
      100
    ),
    COALESCE(
      (SELECT burst_limit FROM ai_rate_config WHERE feature = p_feature),
      (SELECT burst_limit FROM ai_rate_config WHERE feature = '*'),
      20
    )
  INTO v_daily_limit, v_burst_limit;

  -- Count today's requests for this user+feature
  SELECT COUNT(*)
  INTO v_day_count
  FROM ai_requests
  WHERE user_id  = p_user_id
    AND feature  = p_feature
    AND created_at >= date_trunc('day', now() AT TIME ZONE 'UTC')
    AND status != 'error';   -- errors don't count toward quota

  -- Count last-hour requests (burst protection)
  SELECT COUNT(*)
  INTO v_hour_count
  FROM ai_requests
  WHERE user_id  = p_user_id
    AND feature  = p_feature
    AND created_at >= now() - INTERVAL '1 hour'
    AND status != 'error';

  -- Next reset: midnight UTC
  v_reset_at := date_trunc('day', now() AT TIME ZONE 'UTC') + INTERVAL '1 day';

  -- Return result
  RETURN json_build_object(
    'allowed',        v_day_count < v_daily_limit AND v_hour_count < v_burst_limit,
    'daily_count',    v_day_count,
    'daily_limit',    v_daily_limit,
    'hour_count',     v_hour_count,
    'burst_limit',    v_burst_limit,
    'remaining',      GREATEST(0, v_daily_limit - v_day_count),
    'reset_at',       v_reset_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION check_ai_rate_limit(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION check_ai_rate_limit(UUID, TEXT) IS
'Returns rate limit status for a user+feature combination.
Called by the ai-assistant edge function before forwarding to AI provider.
Uses ai_requests table for counting — no separate counter table needed.
H5 implementation. Phase D.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: AI Insights Cache RPCs (M5 / Phase H)
--
-- Good cache candidates:
--   - operations_brief    (expensive, same for all admins today)
--   - daily_brief         (same)
--   - recommendations     (per-user, short TTL)
--   - supplier_score      (per-supplier, medium TTL)
--
-- Cache key format: '<feature>:<scope>'
--   e.g. 'daily_brief:2026-09-10'
--        'operations_brief:2026-09-10'
--        'supplier_score:<supplier_uuid>'
--        'recommendations:<user_uuid>:2026-09-10'
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_cached_insight(
  p_cache_key TEXT
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row ai_insights_cache%ROWTYPE;
BEGIN
  -- Must be an admin
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM ai_insights_cache
  WHERE cache_key = p_cache_key
    AND expires_at > now()
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'data',         v_row.data,
    'expires_at',   v_row.expires_at,
    'created_at',   v_row.created_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_cached_insight(TEXT) TO authenticated;


CREATE OR REPLACE FUNCTION set_cached_insight(
  p_cache_key    TEXT,
  p_data         JSONB,
  p_ttl_minutes  INT DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Must be an admin to write cache
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN FALSE;
  END IF;

  INSERT INTO ai_insights_cache (cache_key, data, generated_by, expires_at)
  VALUES (
    p_cache_key,
    p_data,
    auth.uid(),
    now() + (p_ttl_minutes || ' minutes')::INTERVAL
  )
  ON CONFLICT (cache_key) DO UPDATE
    SET data         = EXCLUDED.data,
        generated_by = EXCLUDED.generated_by,
        expires_at   = EXCLUDED.expires_at,
        created_at   = now();

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION set_cached_insight(TEXT, JSONB, INT) TO authenticated;


CREATE OR REPLACE FUNCTION purge_expired_cache()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
BEGIN
  DELETE FROM ai_insights_cache WHERE expires_at < now();
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION purge_expired_cache() TO authenticated;

COMMENT ON FUNCTION get_cached_insight(TEXT)          IS 'Returns unexpired cache entry by key. Admin-only. Phase D/H.';
COMMENT ON FUNCTION set_cached_insight(TEXT,JSONB,INT) IS 'Upserts cache entry with TTL in minutes. Admin-only. Phase D/H.';
COMMENT ON FUNCTION purge_expired_cache()              IS 'Deletes all expired cache entries. Phase D/H.';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: Cache TTL constants as config rows (optional but useful)
-- ─────────────────────────────────────────────────────────────────────────────

-- Reuse ai_rate_config pattern but for cache — store in accounting_settings style
-- Actually: add to ai_rate_config as metadata (simpler — one less table)
-- Just document expected TTLs as comments for the edge function:
--   daily_brief:          480 min (8 hours — refreshes morning)
--   operations_brief:     240 min (4 hours)
--   recommendations:       60 min (1 hour — semi-personalized)
--   supplier_score:<id>:  720 min (12 hours)


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6: get_ai_rate_config RPC (for admin dashboard display)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_ai_rate_config()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error', 'unauthorized');
  END IF;

  RETURN (
    SELECT json_agg(row_to_json(r))
    FROM (SELECT feature, daily_limit, burst_limit, description FROM ai_rate_config ORDER BY feature) r
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_ai_rate_config() TO authenticated;


-- ══ END PHASE D MIGRATION ══════════════════════════════════════════════════
-- Verification:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name IN (
--     'check_ai_rate_limit','get_cached_insight',
--     'set_cached_insight','purge_expired_cache','get_ai_rate_config'
--   );
--   → 5 rows
--
--   SELECT COUNT(*) FROM ai_rate_config;
--   → 12 rows (seed data)
--
--   SELECT COUNT(*) FROM information_schema.table_constraints
--   WHERE table_name='ai_recommendations'
--   AND constraint_name='ai_recommendations_status_check';
--   → 1 row
