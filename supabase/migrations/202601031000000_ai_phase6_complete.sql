-- =============================================================================
-- MIGRATION: 202601031000000_ai_phase6_complete.sql
-- Phase 6 completion — adds missing pieces to the AI foundation
-- Safe: purely additive
-- =============================================================================

-- ── Extend ai_recommendations rec_type to include itinerary_suggest + command_center
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

-- ── Extend ai_requests feature (no constraint — free text, just an index)
-- Already free text — no change needed

-- ── Extend ai_conversations context_type for itinerary
ALTER TABLE ai_conversations
  DROP CONSTRAINT IF EXISTS ai_conversations_context_type_check;

ALTER TABLE ai_conversations
  ADD CONSTRAINT ai_conversations_context_type_check
  CHECK (context_type IN (
    'command_center','lead','opportunity','quotation',
    'itinerary','operations','supplier','quote_review',
    'recommendations','daily_brief'
  ));

-- ── Helper RPC: get AI usage stats for dashboard
CREATE OR REPLACE FUNCTION get_ai_usage_today()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total_requests',    (SELECT count(*) FROM ai_requests WHERE created_at >= current_date),
    'success_requests',  (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'error_requests',    (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'error'),
    'avg_latency_ms',    (SELECT round(avg(latency_ms)) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'active_recs',       (SELECT count(*) FROM ai_recommendations WHERE status = 'active'),
    'applied_recs',      (SELECT count(*) FROM ai_recommendations WHERE status = 'applied'),
    'top_feature',       (SELECT feature FROM ai_requests WHERE created_at >= current_date GROUP BY feature ORDER BY count(*) DESC LIMIT 1)
  );
$$;

GRANT EXECUTE ON FUNCTION get_ai_usage_today() TO authenticated;

-- ── Forecasting view: simple pipeline forecast based on weighted opportunities
CREATE OR REPLACE VIEW v_ai_pipeline_forecast AS
SELECT
  date_trunc('month', COALESCE(expected_close, created_at + interval '30 days'))::date AS forecast_month,
  count(*)                                                                               AS opp_count,
  round(sum(COALESCE(estimated_value, 0)))                                               AS total_value,
  round(sum(COALESCE(estimated_value, 0) * COALESCE(probability, 20) / 100.0))          AS weighted_value
FROM opportunities
WHERE stage NOT IN ('won', 'lost')
GROUP BY 1
ORDER BY 1;

-- Grant read to admins via existing RLS
-- (view inherits from underlying table RLS)

-- ── Lead conversion rate helper
CREATE OR REPLACE FUNCTION get_lead_conversion_stats()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total_leads',        (SELECT count(*) FROM leads),
    'won_leads',          (SELECT count(*) FROM leads WHERE status = 'won'),
    'lost_leads',         (SELECT count(*) FROM leads WHERE status = 'lost'),
    'active_leads',       (SELECT count(*) FROM leads WHERE status NOT IN ('won','lost','unqualified')),
    'conversion_rate_pct',
      CASE WHEN (SELECT count(*) FROM leads WHERE status IN ('won','lost')) > 0
        THEN round(
          (SELECT count(*) FROM leads WHERE status = 'won')::numeric /
          (SELECT count(*) FROM leads WHERE status IN ('won','lost'))::numeric * 100, 1
        )
        ELSE NULL
      END,
    'avg_leads_per_month',
      (SELECT round(count(*)::numeric / GREATEST(
          EXTRACT(EPOCH FROM (now() - min(created_at))) / 2592000, 1
        ), 1) FROM leads)
  );
$$;

GRANT EXECUTE ON FUNCTION get_lead_conversion_stats() TO authenticated;

-- ── Supplier reliability view (used by supplier intelligence)
CREATE OR REPLACE VIEW v_supplier_reliability AS
SELECT
  s.id,
  s.name_ar,
  s.type,
  count(DISTINCT sb.id)                                                  AS total_bills,
  count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')               AS paid_bills,
  count(DISTINCT bc.id)                                                  AS booking_cost_lines,
  round(sum(COALESCE(bc.amount, 0)))                                     AS total_booking_cost,
  round(sum(COALESCE(sb.total_amount, 0)))                               AS total_billed,
  CASE
    WHEN count(DISTINCT sb.id) < 3 THEN 'insufficient_data'
    WHEN count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')::numeric /
         count(DISTINCT sb.id)::numeric >= 0.9 THEN 'high'
    WHEN count(DISTINCT sb.id) FILTER (WHERE sb.status = 'paid')::numeric /
         count(DISTINCT sb.id)::numeric >= 0.7 THEN 'medium'
    ELSE 'low'
  END                                                                    AS payment_reliability
FROM suppliers s
LEFT JOIN supplier_bills sb   ON sb.supplier_id = s.id
LEFT JOIN booking_costs  bc   ON bc.supplier_id = s.id
GROUP BY s.id, s.name_ar, s.type;

-- ── Add Command Center to AI nav permission
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('use_ai_command_center', 'استخدام مركز الأوامر الذكي', 'الذكاء الاصطناعي',
    ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- Done. Phase 6 AI layer is complete.
-- Next step: deploy supabase/functions/ai-assistant/ and set ANTHROPIC_API_KEY secret.
