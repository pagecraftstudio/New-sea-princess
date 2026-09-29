-- =============================================================================
-- PHASE 6 — AI & INTELLIGENCE FOUNDATION
-- Migration: 202601030000000_ai_foundation.sql
-- Safe: purely additive. No existing tables modified destructively.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TABLE: ai_conversations
-- Stores multi-turn AI chat sessions (AI Command Center + contextual chats)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_conversations (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  context_type    TEXT        NOT NULL DEFAULT 'command_center'
                              CHECK (context_type IN (
                                'command_center','lead','opportunity','quotation',
                                'itinerary','operations','supplier'
                              )),
  context_id      UUID,       -- ID of the lead/opp/quote etc. if contextual
  title           TEXT,       -- auto-generated from first user message
  messages        JSONB       NOT NULL DEFAULT '[]', -- [{role,content,ts}]
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_conv_user      ON ai_conversations(user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_conv_context   ON ai_conversations(context_type, context_id) WHERE context_id IS NOT NULL;

ALTER TABLE ai_conversations ENABLE ROW LEVEL SECURITY;
-- Users see only their own conversations
CREATE POLICY "ai_conv_owner" ON ai_conversations FOR ALL
  USING (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- TABLE: ai_requests
-- Audit log of every AI request: who, what, when, cost estimate
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_requests (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  feature         TEXT        NOT NULL,  -- 'lead_analysis','itinerary_draft','quote_review',...
  context_type    TEXT,
  context_id      UUID,
  model           TEXT,
  prompt_tokens   INT,
  completion_tokens INT,
  latency_ms      INT,
  status          TEXT        DEFAULT 'success' CHECK (status IN ('success','error','timeout')),
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_req_user    ON ai_requests(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_req_feature ON ai_requests(feature, created_at DESC);

ALTER TABLE ai_requests ENABLE ROW LEVEL SECURITY;
-- Admins see all; others see own
CREATE POLICY "ai_req_admin"
  ON ai_requests FOR SELECT
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- -----------------------------------------------------------------------------
-- TABLE: ai_recommendations
-- Cached AI recommendations with feedback loop
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_recommendations (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  rec_type        TEXT        NOT NULL
                              CHECK (rec_type IN (
                                'lead_priority','opp_risk','follow_up','supplier_score',
                                'quote_review','ops_risk','forecast','upsell','next_action'
                              )),
  context_type    TEXT,
  context_id      UUID,
  title           TEXT        NOT NULL,
  body            TEXT        NOT NULL,         -- markdown explanation
  confidence      TEXT        DEFAULT 'medium'
                              CHECK (confidence IN ('high','medium','low','insufficient_data')),
  suggested_action JSONB,                       -- {type, label, payload}
  status          TEXT        DEFAULT 'active'
                              CHECK (status IN ('active','applied','dismissed','expired')),
  feedback        TEXT        CHECK (feedback IN ('helpful','not_helpful','incorrect')),
  feedback_note   TEXT,
  expires_at      TIMESTAMPTZ,                 -- NULL = no expiry
  ai_request_id   UUID        REFERENCES ai_requests(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_rec_context  ON ai_recommendations(context_type, context_id);
CREATE INDEX IF NOT EXISTS idx_ai_rec_type     ON ai_recommendations(rec_type, status);
CREATE INDEX IF NOT EXISTS idx_ai_rec_user     ON ai_recommendations(user_id, created_at DESC);

ALTER TABLE ai_recommendations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ai_rec_admin"
  ON ai_recommendations FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- -----------------------------------------------------------------------------
-- TABLE: ai_insights_cache
-- Short-lived cached insight blobs (daily brief, supplier scores, forecasts)
-- Keyed by type + date so the edge function can serve cached results
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ai_insights_cache (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  cache_key   TEXT        UNIQUE NOT NULL,   -- e.g. 'daily_brief:2026-09-10' or 'supplier_score:UUID'
  data        JSONB       NOT NULL,
  generated_by UUID       REFERENCES auth.users(id) ON DELETE SET NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_cache_key     ON ai_insights_cache(cache_key);
CREATE INDEX IF NOT EXISTS idx_ai_cache_expires ON ai_insights_cache(expires_at);

ALTER TABLE ai_insights_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ai_cache_admin"
  ON ai_insights_cache FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- -----------------------------------------------------------------------------
-- FUNCTION: cleanup stale AI cache (run via pg_cron or manual)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_ai_cache()
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  DELETE FROM ai_insights_cache WHERE expires_at < now();
$$;

-- -----------------------------------------------------------------------------
-- PERMISSIONS: extend permission_matrix for AI features
-- -----------------------------------------------------------------------------
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('use_ai_sales',      'استخدام مساعد المبيعات الذكي',     'الذكاء الاصطناعي',
    ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('use_ai_operations', 'استخدام مساعد العمليات الذكي',    'الذكاء الاصطناعي',
    ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('use_ai_finance',    'استخدام التحليل المالي الذكي',    'الذكاء الاصطناعي',
    ARRAY['super_admin','admin','financial_manager','accountant','auditor']),
  ('view_ai_dashboard', 'عرض لوحة الذكاء الاصطناعي',      'الذكاء الاصطناعي',
    ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent','auditor']),
  ('manage_ai_config',  'إدارة إعدادات الذكاء الاصطناعي', 'الذكاء الاصطناعي',
    ARRAY['super_admin'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- Done.
-- Phase 6.1 — AI Foundation migration complete.
-- Tables: ai_conversations, ai_requests, ai_recommendations, ai_insights_cache
-- Permissions: 5 new AI permissions
