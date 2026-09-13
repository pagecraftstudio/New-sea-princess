-- ============================================================
-- Migration 202601064000000_ai_provider_column.sql
-- Phase 16.3 — Demo AI Provider: add provider column to ai_requests
--
-- Reason:
--   ai_requests records model but not provider. With the addition of
--   a third provider (demo/Groq), audit logs must record which provider
--   generated each response so operators can distinguish Anthropic,
--   OpenAI, and demo responses in the audit table.
--
-- Change:
--   ALTER TABLE ai_requests ADD COLUMN provider TEXT
--   Backfill existing rows: infer 'anthropic' or 'openai' from model column
--
-- Safe:
--   Additive only. NULL allowed so existing rows and error-log inserts
--   without provider still succeed (old code path). New edge function
--   always supplies provider.
-- ============================================================

ALTER TABLE ai_requests
  ADD COLUMN IF NOT EXISTS provider TEXT;  -- 'anthropic' | 'openai' | 'demo'

-- Backfill existing rows from model name heuristic
-- claude-* → anthropic; gpt-* → openai; NULL/unknown → NULL (honest)
UPDATE ai_requests
SET provider = CASE
  WHEN model LIKE 'claude%' THEN 'anthropic'
  WHEN model LIKE 'gpt%'    THEN 'openai'
  ELSE NULL
END
WHERE provider IS NULL AND model IS NOT NULL;

COMMENT ON COLUMN ai_requests.provider IS
'AI provider that handled this request: anthropic | openai | demo.
Added in Phase 16.3 to support multiple provider audit trail.
NULL on pre-16.3 rows where provider was not yet recorded.';

CREATE INDEX IF NOT EXISTS idx_ai_req_provider ON ai_requests(provider, created_at DESC);
