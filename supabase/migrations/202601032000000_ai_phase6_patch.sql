-- =============================================================================
-- PATCH MIGRATION: 202601032000000_ai_phase6_patch.sql
--
-- Problem: Migration 030 (ai_foundation) failed — rolled back entirely.
--          ai_conversations, ai_requests, ai_recommendations, ai_insights_cache
--          were never created. Migration 031 then failed:
--          "relation ai_recommendations does not exist"
--
-- Fix: Re-create all 4 AI tables (IF NOT EXISTS = idempotent).
--      Wrap RLS policies in DO blocks to avoid duplicate policy errors.
--      Re-apply 031 constraint/RPC changes.
--      Use WHERE NOT EXISTS instead of ON CONFLICT for permission_matrix
--      (permission column has no UNIQUE constraint — only id is PK).
--
-- Safe to run multiple times.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — AI tables
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS ai_conversations (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  context_type TEXT        NOT NULL DEFAULT 'command_center',
  context_id   UUID,
  title        TEXT,
  messages     JSONB       NOT NULL DEFAULT '[]',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_conv_user    ON ai_conversations(user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_conv_context ON ai_conversations(context_type, context_id)
  WHERE context_id IS NOT NULL;

ALTER TABLE ai_conversations ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='ai_conversations' AND policyname='ai_conv_owner') THEN
    CREATE POLICY "ai_conv_owner" ON ai_conversations FOR ALL USING (user_id = auth.uid());
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS ai_requests (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  feature           TEXT        NOT NULL,
  context_type      TEXT,
  context_id        UUID,
  model             TEXT,
  prompt_tokens     INT,
  completion_tokens INT,
  latency_ms        INT,
  status            TEXT        DEFAULT 'success'
                                CHECK (status IN ('success','error','timeout')),
  error_message     TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_req_user    ON ai_requests(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_req_feature ON ai_requests(feature, created_at DESC);

ALTER TABLE ai_requests ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='ai_requests' AND policyname='ai_req_admin') THEN
    CREATE POLICY "ai_req_admin" ON ai_requests FOR SELECT
      USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS ai_recommendations (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  rec_type     TEXT        NOT NULL,
  context_type TEXT,
  context_id   UUID,
  title        TEXT        NOT NULL,
  body         TEXT,
  action_label TEXT,
  action_url   TEXT,
  priority     TEXT        DEFAULT 'medium'
                           CHECK (priority IN ('low','medium','high','critical')),
  status       TEXT        DEFAULT 'active'
                           CHECK (status IN ('active','dismissed','applied')),
  expires_at   TIMESTAMPTZ,
  metadata     JSONB       DEFAULT '{}',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_rec_context ON ai_recommendations(context_type, context_id);
CREATE INDEX IF NOT EXISTS idx_ai_rec_type    ON ai_recommendations(rec_type, status);
CREATE INDEX IF NOT EXISTS idx_ai_rec_user    ON ai_recommendations(user_id, created_at DESC);

ALTER TABLE ai_recommendations ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='ai_recommendations' AND policyname='ai_rec_admin') THEN
    CREATE POLICY "ai_rec_admin" ON ai_recommendations FOR ALL
      USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS ai_insights_cache (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  cache_key    TEXT        UNIQUE NOT NULL,
  data         JSONB       NOT NULL,
  generated_by UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  expires_at   TIMESTAMPTZ NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_cache_key     ON ai_insights_cache(cache_key);
CREATE INDEX IF NOT EXISTS idx_ai_cache_expires ON ai_insights_cache(expires_at);

ALTER TABLE ai_insights_cache ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='ai_insights_cache' AND policyname='ai_cache_admin') THEN
    CREATE POLICY "ai_cache_admin" ON ai_insights_cache FOR ALL
      USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION cleanup_ai_cache()
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  DELETE FROM ai_insights_cache WHERE expires_at < now();
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — AI permissions (WHERE NOT EXISTS — no UNIQUE on permission column)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
SELECT p.permission, p.name_ar, p.category_ar, p.roles::text[]
FROM (VALUES
  ('use_ai_sales',          'استخدام مساعد المبيعات الذكي',     'الذكاء الاصطناعي', '{super_admin,admin,sales_agent,booking_agent}'),
  ('use_ai_operations',     'استخدام مساعد العمليات الذكي',    'الذكاء الاصطناعي', '{super_admin,admin,sales_agent,booking_agent}'),
  ('use_ai_finance',        'استخدام التحليل المالي الذكي',    'الذكاء الاصطناعي', '{super_admin,admin,financial_manager,accountant,auditor}'),
  ('view_ai_dashboard',     'عرض لوحة الذكاء الاصطناعي',      'الذكاء الاصطناعي', '{super_admin,admin,financial_manager,sales_agent,booking_agent,auditor}'),
  ('manage_ai_config',      'إدارة إعدادات الذكاء الاصطناعي', 'الذكاء الاصطناعي', '{super_admin}'),
  ('use_ai_command_center', 'استخدام مركز الأوامر الذكي',      'الذكاء الاصطناعي', '{super_admin,admin,financial_manager,sales_agent,booking_agent}')
) AS p(permission, name_ar, category_ar, roles)
WHERE NOT EXISTS (
  SELECT 1 FROM permission_matrix WHERE permission = p.permission
);


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — Widen constraints (from migration 031)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE ai_recommendations
  DROP CONSTRAINT IF EXISTS ai_recommendations_rec_type_check;

ALTER TABLE ai_recommendations
  ADD CONSTRAINT ai_recommendations_rec_type_check
  CHECK (rec_type IN (
    'lead_priority','opp_risk','follow_up','supplier_score',
    'quote_review','ops_risk','forecast','upsell','next_action',
    'lead_analysis','opp_analysis','itinerary_suggest','command_center',
    'operations_brief','recommendations','follow_up_draft'
  ));

ALTER TABLE ai_conversations
  DROP CONSTRAINT IF EXISTS ai_conversations_context_type_check;

ALTER TABLE ai_conversations
  ADD CONSTRAINT ai_conversations_context_type_check
  CHECK (context_type IN (
    'command_center','lead','opportunity','quotation',
    'itinerary','operations','supplier','quote_review',
    'recommendations','daily_brief'
  ));


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — RPCs and views (from migration 031)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_ai_usage_today()
RETURNS JSON LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT json_build_object(
    'total_requests',   (SELECT count(*) FROM ai_requests WHERE created_at >= current_date),
    'success_requests', (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'error_requests',   (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'error'),
    'avg_latency_ms',   (SELECT round(avg(latency_ms)) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'active_recs',      (SELECT count(*) FROM ai_recommendations WHERE status = 'active'),
    'applied_recs',     (SELECT count(*) FROM ai_recommendations WHERE status = 'applied'),
    'top_feature',      (SELECT feature FROM ai_requests WHERE created_at >= current_date GROUP BY feature ORDER BY count(*) DESC LIMIT 1)
  );
$$;

GRANT EXECUTE ON FUNCTION get_ai_usage_today() TO authenticated;

CREATE OR REPLACE FUNCTION get_lead_conversion_stats()
RETURNS JSON LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT json_build_object(
    'total_leads',         (SELECT count(*) FROM leads),
    'won_leads',           (SELECT count(*) FROM leads WHERE status = 'won'),
    'lost_leads',          (SELECT count(*) FROM leads WHERE status = 'lost'),
    'active_leads',        (SELECT count(*) FROM leads WHERE status NOT IN ('won','lost','unqualified')),
    'conversion_rate_pct',
      CASE WHEN (SELECT count(*) FROM leads WHERE status IN ('won','lost')) > 0
        THEN round(
          (SELECT count(*) FROM leads WHERE status = 'won')::numeric /
          (SELECT count(*) FROM leads WHERE status IN ('won','lost'))::numeric * 100, 1)
        ELSE NULL END,
    'avg_leads_per_month',
      (SELECT round(count(*)::numeric /
        GREATEST(EXTRACT(EPOCH FROM (now() - min(created_at))) / 2592000, 1), 1)
       FROM leads)
  );
$$;

GRANT EXECUTE ON FUNCTION get_lead_conversion_stats() TO authenticated;

CREATE OR REPLACE VIEW v_ai_pipeline_forecast AS
SELECT
  date_trunc('month', COALESCE(expected_close, created_at + interval '30 days'))::date AS forecast_month,
  count(*)                                                                               AS opp_count,
  round(sum(COALESCE(estimated_value, 0)))                                               AS total_value,
  round(sum(COALESCE(estimated_value, 0) * COALESCE(probability, 20) / 100.0))          AS weighted_value
FROM opportunities
WHERE stage NOT IN ('won','lost')
GROUP BY 1
ORDER BY 1;

CREATE OR REPLACE VIEW v_supplier_reliability AS
SELECT
  s.id,
  s.name_ar,
  s.type,
  count(DISTINCT sb.id)                                                 AS total_bills,
  count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')              AS paid_bills,
  count(DISTINCT bc.id)                                                 AS booking_cost_lines,
  round(sum(COALESCE(bc.amount, 0)))                                    AS total_booking_cost,
  round(sum(COALESCE(sb.total_amount, 0)))                              AS total_billed,
  CASE
    WHEN count(DISTINCT sb.id) < 3 THEN 'insufficient_data'
    WHEN count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')::numeric /
         NULLIF(count(DISTINCT sb.id)::numeric, 0) >= 0.9 THEN 'high'
    WHEN count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')::numeric /
         NULLIF(count(DISTINCT sb.id)::numeric, 0) >= 0.7 THEN 'medium'
    ELSE 'low'
  END AS payment_reliability
FROM suppliers s
LEFT JOIN supplier_bills sb ON sb.supplier_id = s.id
LEFT JOIN booking_costs  bc ON bc.supplier_id = s.id
GROUP BY s.id, s.name_ar, s.type;

-- ══ PATCH COMPLETE ═══════════════════════════════════════════════════════════
-- Verification:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--   AND table_name IN (
--     'ai_conversations','ai_requests','ai_recommendations','ai_insights_cache'
--   );
--   -- Expected: 4 rows
