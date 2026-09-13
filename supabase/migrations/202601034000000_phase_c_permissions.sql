-- ============================================================
-- Migration 034 — Phase C: Permission Hardening
-- Fixes: H2 (SECURITY DEFINER bypasses RLS on CRM aggregates)
--        H3 (get_admin_role GRANT review)
--        Phase C: DB-driven permission infrastructure
-- Safe: CREATE OR REPLACE only — no table drops
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- H2: get_crm_summary — restrict to admin_users members only
--
-- Problem: GRANT EXECUTE TO authenticated means any registered
-- public customer (profiles row, no admin_users row) can call
-- this and receive counts of all leads, tasks, opportunities,
-- pipeline value.
--
-- Fix: add an explicit admin membership check inside the function.
-- Non-admin callers get a zero/null result, not an error, so
-- client code doesn't break — it just sees empty data.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_crm_summary()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only admin_users members may see CRM aggregates
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object(
      'error',            'unauthorized',
      'leads_total',       0,
      'leads_new',         0,
      'leads_contacted',   0,
      'leads_qualified',   0,
      'leads_won',         0,
      'leads_lost',        0,
      'overdue_followups', 0,
      'open_tasks',        0,
      'overdue_tasks',     0,
      'pipeline_count',    0,
      'pipeline_value',    0,
      'won_value',         0
    );
  END IF;

  RETURN json_build_object(
    'leads_total',       (SELECT count(*) FROM leads),
    'leads_new',         (SELECT count(*) FROM leads WHERE status = 'new'),
    'leads_contacted',   (SELECT count(*) FROM leads WHERE status = 'contacted'),
    'leads_qualified',   (SELECT count(*) FROM leads WHERE status = 'qualified'),
    'leads_won',         (SELECT count(*) FROM leads WHERE status = 'won'),
    'leads_lost',        (SELECT count(*) FROM leads WHERE status = 'lost'),
    'overdue_followups', (SELECT count(*) FROM leads WHERE next_follow_up < now() AND status NOT IN ('won','lost')),
    'open_tasks',        (SELECT count(*) FROM tasks WHERE status != 'done'),
    'overdue_tasks',     (SELECT count(*) FROM tasks WHERE due_at < now() AND status != 'done'),
    'pipeline_count',    (SELECT count(*) FROM opportunities WHERE stage NOT IN ('won','lost')),
    'pipeline_value',    (SELECT COALESCE(sum(estimated_value), 0) FROM opportunities WHERE stage NOT IN ('won','lost')),
    'won_value',         (SELECT COALESCE(sum(estimated_value), 0) FROM opportunities WHERE stage = 'won')
  );
END;
$$;

-- GRANT stays as authenticated (Supabase client requires this),
-- but the function body now enforces admin membership internally.
GRANT EXECUTE ON FUNCTION get_crm_summary() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- H2: get_quotation_summary — same fix
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_quotation_summary()
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

  RETURN json_build_object(
    'total',          (SELECT COUNT(*) FROM quotations),
    'draft',          (SELECT COUNT(*) FROM quotations WHERE status = 'draft'),
    'sent',           (SELECT COUNT(*) FROM quotations WHERE status IN ('sent','viewed')),
    'accepted',       (SELECT COUNT(*) FROM quotations WHERE status IN ('accepted','deposit_pending','confirmed')),
    'expired',        (SELECT COUNT(*) FROM quotations WHERE status = 'expired'),
    'rejected',       (SELECT COUNT(*) FROM quotations WHERE status IN ('rejected','cancelled')),
    'total_value',    (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status NOT IN ('rejected','cancelled','expired')),
    'accepted_value', (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status IN ('accepted','deposit_pending','confirmed')),
    'pipeline_value', (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status IN ('sent','viewed','revision_requested','negotiation'))
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_quotation_summary() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- H2: get_lead_conversion_stats — same fix
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_lead_conversion_stats()
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

  RETURN json_build_object(
    'total_leads',   (SELECT count(*) FROM leads),
    'won_leads',     (SELECT count(*) FROM leads WHERE status = 'won'),
    'lost_leads',    (SELECT count(*) FROM leads WHERE status = 'lost'),
    'active_leads',  (SELECT count(*) FROM leads WHERE status NOT IN ('won','lost','unqualified')),
    'conversion_rate_pct',
      CASE WHEN (SELECT count(*) FROM leads WHERE status IN ('won','lost')) > 0
        THEN round(
          (SELECT count(*) FROM leads WHERE status = 'won')::numeric /
          (SELECT count(*) FROM leads WHERE status IN ('won','lost'))::numeric * 100, 1
        )
        ELSE NULL
      END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_lead_conversion_stats() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- H2: get_ai_usage_today — admin-only (reads ai_requests)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_ai_usage_today()
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

  RETURN json_build_object(
    'total_requests',   (SELECT count(*) FROM ai_requests WHERE created_at >= current_date),
    'success_requests', (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'error_requests',   (SELECT count(*) FROM ai_requests WHERE created_at >= current_date AND status = 'error'),
    'avg_latency_ms',   (SELECT round(avg(latency_ms)) FROM ai_requests WHERE created_at >= current_date AND status = 'success'),
    'active_recs',      (SELECT count(*) FROM ai_recommendations WHERE status = 'active'),
    'applied_recs',     (SELECT count(*) FROM ai_recommendations WHERE status = 'applied'),
    'top_feature',      (SELECT feature FROM ai_requests WHERE created_at >= current_date GROUP BY feature ORDER BY count(*) DESC LIMIT 1)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_ai_usage_today() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- H3: get_admin_role — review
--
-- Current: SECURITY DEFINER, GRANT TO authenticated.
-- Risk assessment: function returns NULL for non-admin callers
-- (SELECT role FROM admin_users WHERE id = auth.uid() — if no
-- admin_users row, returns NULL). No data leaks to public users.
-- The GRANT TO authenticated is required by Supabase client .rpc().
--
-- Action: add explicit comment documenting safe behavior.
-- No functional change needed — NULL return for non-admins is correct.
-- ────────────────────────────────────────────────────────────
COMMENT ON FUNCTION get_admin_role() IS
'Returns the role of the calling admin user, or NULL if not in admin_users.
SECURITY DEFINER with GRANT TO authenticated is intentional — Supabase client
requires this. Non-admin callers receive NULL, not an error. No data leaks.
Reviewed Phase C — no functional change required. H3.';

-- ────────────────────────────────────────────────────────────
-- Ensure has_permission() helper exists for server-side checks
-- Used by edge function and can be used by future RLS policies
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION has_ai_permission(p_permission TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM admin_users au
    JOIN permission_matrix pm ON p_permission = pm.permission
    WHERE au.id = auth.uid()
      AND au.role = ANY(pm.roles)
  );
$$;

GRANT EXECUTE ON FUNCTION has_ai_permission(TEXT) TO authenticated;

COMMENT ON FUNCTION has_ai_permission(TEXT) IS
'Returns true if the calling user has the specified permission.
Used for DB-driven permission checks in RLS and edge functions. Phase C.';

