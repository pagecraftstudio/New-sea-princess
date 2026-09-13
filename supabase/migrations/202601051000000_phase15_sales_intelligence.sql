-- ═══════════════════════════════════════════════════════════════════════════
--  PHASE 15 — Advanced Sales Intelligence
--  File: 202601051000000_phase15_sales_intelligence.sql
--
--  New functions (read-only analytics — zero schema changes):
--    get_sales_kpis(p_days)
--    get_sales_funnel(p_days)
--    get_agent_scorecards(p_days)
--    get_pipeline_value()
--    get_lost_reason_analysis(p_days)
--    get_lead_source_performance(p_days)
--    get_sales_forecast()
--
--  Safe: no DROP, no ALTER, no INSERT/UPDATE/DELETE on any table.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1. CORE KPI SNAPSHOT ────────────────────────────────────────────────────
--  Returns headline numbers for the dashboard top strip.
--  p_days: rolling window in days (default 30)

CREATE OR REPLACE FUNCTION get_sales_kpis(p_days INT DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since      TIMESTAMPTZ := now() - (p_days || ' days')::INTERVAL;
  v_prev_since TIMESTAMPTZ := now() - (p_days * 2 || ' days')::INTERVAL;
  v_result     JSON;
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  SELECT json_build_object(

    -- Leads
    'new_leads',           (SELECT COUNT(*) FROM leads WHERE created_at >= v_since),
    'new_leads_prev',      (SELECT COUNT(*) FROM leads WHERE created_at BETWEEN v_prev_since AND v_since),

    -- Qualified
    'qualified',           (SELECT COUNT(*) FROM leads WHERE status IN ('qualified','opportunity','won') AND updated_at >= v_since),

    -- Opportunities
    'open_opps',           (SELECT COUNT(*) FROM opportunities WHERE stage NOT IN ('won','lost')),
    'open_opps_value',     (SELECT COALESCE(SUM(estimated_value),0) FROM opportunities WHERE stage NOT IN ('won','lost')),

    -- Won
    'won_count',           (SELECT COUNT(*) FROM opportunities WHERE stage='won' AND won_at >= v_since),
    'won_value',           (SELECT COALESCE(SUM(estimated_value),0) FROM opportunities WHERE stage='won' AND won_at >= v_since),
    'won_count_prev',      (SELECT COUNT(*) FROM opportunities WHERE stage='won' AND won_at BETWEEN v_prev_since AND v_since),

    -- Lost
    'lost_count',          (SELECT COUNT(*) FROM opportunities WHERE stage='lost' AND lost_at >= v_since),
    'lost_value',          (SELECT COALESCE(SUM(estimated_value),0) FROM opportunities WHERE stage='lost' AND lost_at >= v_since),

    -- Quotes
    'quotes_sent',         (SELECT COUNT(*) FROM quotations WHERE status IN ('sent','viewed','revision_requested','negotiation','accepted','deposit_pending','confirmed') AND created_at >= v_since),
    'quotes_accepted',     (SELECT COUNT(*) FROM quotations WHERE status IN ('accepted','deposit_pending','confirmed') AND created_at >= v_since),

    -- Bookings revenue (via booking-opportunity link)
    'booking_revenue',     (SELECT COALESCE(SUM(b.total_price),0)
                            FROM bookings b
                            JOIN opportunities o ON b.opportunity_id = o.id
                            WHERE b.created_at >= v_since AND b.status NOT IN ('cancelled')),

    -- Conversion rates
    'lead_to_opp_rate',    (SELECT CASE WHEN COUNT(*) = 0 THEN 0
                              ELSE ROUND(COUNT(*) FILTER (WHERE status IN ('opportunity','won')) * 100.0 / COUNT(*), 1)
                              END FROM leads WHERE created_at >= v_since),

    'opp_win_rate',        (SELECT CASE WHEN COUNT(*) = 0 THEN 0
                              ELSE ROUND(COUNT(*) FILTER (WHERE stage='won') * 100.0 / COUNT(*), 1)
                              END FROM opportunities WHERE (won_at >= v_since OR lost_at >= v_since)),

    -- Avg sales cycle (lead created → opportunity won, days)
    'avg_sales_cycle_days',(SELECT ROUND(AVG(EXTRACT(EPOCH FROM (o.won_at - l.created_at))/86400)::NUMERIC, 1)
                            FROM opportunities o
                            JOIN leads l ON l.id = o.lead_id
                            WHERE o.stage = 'won' AND o.won_at >= v_since),

    -- Overdue follow-ups
    'overdue_followups',   (SELECT COUNT(*) FROM leads
                            WHERE next_follow_up < now()
                              AND status NOT IN ('won','lost','unqualified')),

    'period_days', p_days

  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_kpis(INT) TO authenticated;


-- ── 2. SALES FUNNEL ─────────────────────────────────────────────────────────
--  Stage-by-stage counts for the funnel chart.

CREATE OR REPLACE FUNCTION get_sales_funnel(p_days INT DEFAULT 90)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - (p_days || ' days')::INTERVAL;
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT json_agg(stage_row ORDER BY stage_row.sort_order)
    FROM (
      SELECT 1 AS sort_order, 'leads'          AS stage_key, 'كل العملاء المحتملين'  AS stage_ar,
             COUNT(*) AS count, NULL::NUMERIC   AS value
      FROM leads WHERE created_at >= v_since

      UNION ALL
      SELECT 2, 'contacted',  'تم التواصل',
             COUNT(*), NULL
      FROM leads WHERE status IN ('contacted','qualified','opportunity','won') AND created_at >= v_since

      UNION ALL
      SELECT 3, 'qualified',  'مؤهلون',
             COUNT(*), NULL
      FROM leads WHERE status IN ('qualified','opportunity','won') AND created_at >= v_since

      UNION ALL
      SELECT 4, 'opportunity', 'فرص',
             COUNT(*), COALESCE(SUM(estimated_value),0)
      FROM opportunities WHERE created_at >= v_since AND stage NOT IN ('lost')

      UNION ALL
      SELECT 5, 'quoted',     'تم إرسال عرض',
             COUNT(*), COALESCE(SUM(total_amount),0)
      FROM quotations WHERE created_at >= v_since AND status NOT IN ('cancelled','rejected')

      UNION ALL
      SELECT 6, 'won',        'مكسوب',
             COUNT(*), COALESCE(SUM(estimated_value),0)
      FROM opportunities WHERE stage='won' AND won_at >= v_since
    ) stage_row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_funnel(INT) TO authenticated;


-- ── 3. AGENT SCORECARDS ─────────────────────────────────────────────────────
--  Per-agent performance breakdown.

CREATE OR REPLACE FUNCTION get_agent_scorecards(p_days INT DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - (p_days || ' days')::INTERVAL;
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT COALESCE(json_agg(agent_row ORDER BY agent_row.won_value DESC NULLS LAST), '[]'::JSON)
    FROM (
      SELECT
        p.id            AS agent_id,
        COALESCE(p.full_name, p.email, 'غير معروف') AS agent_name,
        au.role         AS agent_role,

        -- Leads
        COUNT(DISTINCT l.id) FILTER (WHERE l.created_at >= v_since)  AS new_leads,
        COUNT(DISTINCT l.id) FILTER (WHERE l.status NOT IN ('won','lost','unqualified'))
                                                                       AS active_leads,

        -- Opportunities
        COUNT(DISTINCT o.id) FILTER (WHERE o.stage NOT IN ('won','lost'))  AS open_opps,
        COUNT(DISTINCT o.id) FILTER (WHERE o.stage = 'won' AND o.won_at >= v_since) AS won_count,
        COUNT(DISTINCT o.id) FILTER (WHERE o.stage = 'lost' AND o.lost_at >= v_since) AS lost_count,
        COALESCE(SUM(o.estimated_value) FILTER (WHERE o.stage = 'won' AND o.won_at >= v_since), 0) AS won_value,

        -- Quotes sent
        COUNT(DISTINCT q.id) FILTER (WHERE q.created_at >= v_since
          AND q.status NOT IN ('cancelled','rejected'))                  AS quotes_sent,

        -- Activities
        COUNT(DISTINCT la.id) FILTER (WHERE la.created_at >= v_since)  AS activities_count,

        -- Open tasks
        COUNT(DISTINCT t.id) FILTER (WHERE t.status NOT IN ('done','cancelled'))  AS open_tasks,

        -- Win rate %
        CASE WHEN COUNT(DISTINCT o.id) FILTER (WHERE o.stage IN ('won','lost') AND (o.won_at >= v_since OR o.lost_at >= v_since)) = 0
             THEN 0
             ELSE ROUND(
               COUNT(DISTINCT o.id) FILTER (WHERE o.stage='won' AND o.won_at >= v_since) * 100.0 /
               NULLIF(COUNT(DISTINCT o.id) FILTER (WHERE o.stage IN ('won','lost') AND (o.won_at >= v_since OR o.lost_at >= v_since)), 0)
             , 1)
        END AS win_rate_pct,

        -- Avg response time (hours): lead created → first activity
        ROUND(
          AVG(
            EXTRACT(EPOCH FROM (first_act.first_activity_at - l.created_at)) / 3600
          ) FILTER (WHERE first_act.first_activity_at IS NOT NULL AND l.created_at >= v_since)
        ::NUMERIC, 1)
          AS avg_response_hours

      FROM profiles p
      JOIN admin_users au ON au.id = p.id
      LEFT JOIN leads l ON l.assigned_to = p.id
      LEFT JOIN opportunities o ON o.sales_owner = p.id
      LEFT JOIN quotations q ON q.sales_owner = p.id
      LEFT JOIN lead_activities la ON la.lead_id = l.id AND la.created_by = p.id
      LEFT JOIN tasks t ON t.assigned_to = p.id
      LEFT JOIN LATERAL (
        SELECT MIN(la2.created_at) AS first_activity_at
        FROM lead_activities la2
        WHERE la2.lead_id = l.id AND la2.created_by = p.id
      ) first_act ON TRUE

      WHERE au.role IN ('sales_agent','booking_agent','admin','super_admin','financial_manager')
      GROUP BY p.id, p.full_name, p.email, au.role
      HAVING COUNT(DISTINCT l.id) > 0 OR COUNT(DISTINCT o.id) > 0
    ) agent_row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_agent_scorecards(INT) TO authenticated;


-- ── 4. PIPELINE VALUE & FORECAST ────────────────────────────────────────────
--  Weighted pipeline by stage (probability × value).

CREATE OR REPLACE FUNCTION get_pipeline_value()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT COALESCE(json_agg(row ORDER BY row.sort_order), '[]'::JSON)
    FROM (
      SELECT
        stage,
        CASE stage
          WHEN 'new'              THEN 1
          WHEN 'qualification'    THEN 2
          WHEN 'discovery'        THEN 3
          WHEN 'itinerary'        THEN 4
          WHEN 'quote'            THEN 5
          WHEN 'follow_up'        THEN 6
          WHEN 'negotiation'      THEN 7
          WHEN 'deposit_pending'  THEN 8
          WHEN 'won'              THEN 9
          ELSE 10
        END AS sort_order,
        CASE stage
          WHEN 'new'             THEN 'جديد'
          WHEN 'qualification'   THEN 'تأهيل'
          WHEN 'discovery'       THEN 'استكشاف'
          WHEN 'itinerary'       THEN 'بناء جدول'
          WHEN 'quote'           THEN 'عرض سعر'
          WHEN 'follow_up'       THEN 'متابعة'
          WHEN 'negotiation'     THEN 'تفاوض'
          WHEN 'deposit_pending' THEN 'انتظار عربون'
          WHEN 'won'             THEN 'مكسوب'
          ELSE stage
        END AS stage_ar,
        COUNT(*)                                  AS opp_count,
        COALESCE(SUM(estimated_value), 0)         AS total_value,
        ROUND(AVG(probability)::NUMERIC, 0)       AS avg_probability,
        ROUND(COALESCE(SUM(estimated_value * probability / 100.0), 0)::NUMERIC, 2) AS weighted_value,
        currency
      FROM opportunities
      WHERE stage NOT IN ('lost')
      GROUP BY stage, currency
      ORDER BY sort_order
    ) row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_pipeline_value() TO authenticated;


-- ── 5. LOST REASON ANALYSIS ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_lost_reason_analysis(p_days INT DEFAULT 90)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - (p_days || ' days')::INTERVAL;
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT COALESCE(json_agg(row ORDER BY row.count DESC), '[]'::JSON)
    FROM (
      -- Lost opportunities
      SELECT
        COALESCE(lost_reason, 'other')   AS reason,
        COUNT(*)                          AS count,
        COALESCE(SUM(estimated_value), 0) AS lost_value,
        'opportunity'                     AS source
      FROM opportunities
      WHERE stage = 'lost'
        AND (lost_at >= v_since OR (lost_at IS NULL AND updated_at >= v_since))
      GROUP BY lost_reason

      UNION ALL

      -- Lost leads (unqualified/lost without becoming opportunity)
      SELECT
        COALESCE(lost_reason, 'other'),
        COUNT(*),
        0,
        'lead'
      FROM leads
      WHERE status IN ('lost','unqualified')
        AND updated_at >= v_since
        AND lost_reason IS NOT NULL
      GROUP BY lost_reason
    ) row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_lost_reason_analysis(INT) TO authenticated;


-- ── 6. LEAD SOURCE PERFORMANCE ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_lead_source_performance(p_days INT DEFAULT 90)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - (p_days || ' days')::INTERVAL;
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT COALESCE(json_agg(row ORDER BY row.leads_count DESC), '[]'::JSON)
    FROM (
      SELECT
        COALESCE(l.source, 'manual')       AS source,
        COUNT(DISTINCT l.id)               AS leads_count,
        COUNT(DISTINCT l.id) FILTER (WHERE l.status IN ('qualified','opportunity','won')) AS qualified_count,
        COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'won')  AS won_count,
        COUNT(DISTINCT o.id)               AS opp_count,
        COALESCE(SUM(o.estimated_value) FILTER (WHERE o.stage = 'won'), 0) AS won_value,
        CASE WHEN COUNT(DISTINCT l.id) = 0 THEN 0
             ELSE ROUND(COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'won') * 100.0 / COUNT(DISTINCT l.id), 1)
        END AS conversion_rate
      FROM leads l
      LEFT JOIN opportunities o ON o.lead_id = l.id
      WHERE l.created_at >= v_since
      GROUP BY l.source
    ) row
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_lead_source_performance(INT) TO authenticated;


-- ── 7. SALES FORECAST (weighted pipeline projection) ────────────────────────

CREATE OR REPLACE FUNCTION get_sales_forecast()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_any_admin() THEN RETURN '{"error":"unauthorized"}'::JSON; END IF;

  RETURN (
    SELECT json_build_object(
      'total_pipeline',   (SELECT COALESCE(SUM(estimated_value),0) FROM opportunities WHERE stage NOT IN ('won','lost')),
      'weighted_forecast',(SELECT COALESCE(SUM(estimated_value * probability / 100.0),0) FROM opportunities WHERE stage NOT IN ('won','lost')),
      'closing_30d',      (SELECT COALESCE(SUM(estimated_value * probability / 100.0),0)
                           FROM opportunities WHERE stage NOT IN ('won','lost')
                             AND expected_close BETWEEN CURRENT_DATE AND CURRENT_DATE + 30),
      'closing_60d',      (SELECT COALESCE(SUM(estimated_value * probability / 100.0),0)
                           FROM opportunities WHERE stage NOT IN ('won','lost')
                             AND expected_close BETWEEN CURRENT_DATE AND CURRENT_DATE + 60),
      'closing_90d',      (SELECT COALESCE(SUM(estimated_value * probability / 100.0),0)
                           FROM opportunities WHERE stage NOT IN ('won','lost')
                             AND expected_close BETWEEN CURRENT_DATE AND CURRENT_DATE + 90),
      'won_this_month',   (SELECT COALESCE(SUM(estimated_value),0)
                           FROM opportunities WHERE stage='won'
                             AND won_at >= date_trunc('month', now())),
      'won_last_month',   (SELECT COALESCE(SUM(estimated_value),0)
                           FROM opportunities WHERE stage='won'
                             AND won_at >= date_trunc('month', now()) - INTERVAL '1 month'
                             AND won_at  < date_trunc('month', now())),
      'overdue_opps',     (SELECT COUNT(*) FROM opportunities
                           WHERE stage NOT IN ('won','lost')
                             AND expected_close < CURRENT_DATE
                             AND expected_close IS NOT NULL)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_forecast() TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name LIKE 'get_sales%' OR routine_name LIKE 'get_agent%'
--     OR routine_name LIKE 'get_pipeline%' OR routine_name LIKE 'get_lost%'
--     OR routine_name LIKE 'get_lead_source%';
--   → 7 rows
-- ═══════════════════════════════════════════════════════════════════════════
