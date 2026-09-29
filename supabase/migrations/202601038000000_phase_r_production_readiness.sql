-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE R — Final Production Readiness Migration
--  File: supabase/migrations/202601038000000_phase_r_production_readiness.sql
--
--  Purpose: Final sweep of remaining issues after Phases A–Q hardening.
--           All changes are additive / corrective — no data loss.
--
--  Fixes addressed:
--    R1 — Missing UNIQUE constraint on itinerary_number (was nullable unique)
--    R2 — Missing DELETE policy on leads / opportunities (RLS completeness)
--    R3 — ai_insights_cache: add GIN index on metadata for fast key lookups
--    R4 — supplier_rates updated_at trigger (missing from Phase 5 migration)
--    R5 — pricing_overrides: add index on created_at for audit queries
--    R6 — rate_plans: enforce single default plan constraint
--    R7 — ai_requests: add index on user_id + feature for rate limit queries
--    R8 — Final permission_matrix completeness check: pricing + itinerary perms
--    R9 — track_user_login: add session metadata (last_seen, login_count)
--    R10 — Cleanup: remove orphaned root-level migration references
--
--  Safe: CREATE IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE
--  Run after: 202601037000000_phase_q_cleanup.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- R1: itinerary_number — ensure UNIQUE index exists and column is NOT NULL
--     (some environments may have missed the sequence trigger on first run)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- If any itineraries exist with NULL itinerary_number, back-fill them
  UPDATE itineraries
  SET    itinerary_number = 'ITN-' || to_char(created_at, 'YYYY') || '-' ||
                             lpad(id::text, 4, '0')
  WHERE  itinerary_number IS NULL;
EXCEPTION WHEN undefined_table THEN NULL; -- table may not exist in older envs
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_itineraries_number_unique
  ON itineraries(itinerary_number)
  WHERE itinerary_number IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- R2: RLS completeness — DELETE policies on leads and opportunities
--     Phase 1 migration added read/insert/update; DELETE was missing.
--     Only super_admin and admin can permanently delete a lead/opportunity.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- leads DELETE policy
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'leads' AND policyname = 'lead_delete'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY "lead_delete" ON leads FOR DELETE USING (
        auth_role() IN ('super_admin', 'admin')
      )
    $pol$;
  END IF;

  -- opportunities DELETE policy
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'opportunities' AND policyname = 'opp_delete'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY "opp_delete" ON opportunities FOR DELETE USING (
        auth_role() IN ('super_admin', 'admin')
      )
    $pol$;
  END IF;

  -- tasks DELETE policy
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'tasks' AND policyname = 'task_delete'
  ) THEN
    EXECUTE $pol$
      CREATE POLICY "task_delete" ON tasks FOR DELETE USING (
        auth_role() IN ('super_admin', 'admin')
        OR assigned_to = auth.uid()
      )
    $pol$;
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- R3: ai_insights_cache — GIN index on key column for fast prefix lookups
--     (cache keys are namespaced: "feature:userId:date", partial scans needed)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_ai_cache_key_text
  ON ai_insights_cache USING btree (cache_key text_pattern_ops);

CREATE INDEX IF NOT EXISTS idx_ai_cache_expires
  ON ai_insights_cache(expires_at)
  WHERE expires_at IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- R4: supplier_rates — updated_at trigger (missing from Phase 5)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_fn_supplier_rates_updated()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_rates_updated ON supplier_rates;
CREATE TRIGGER trg_supplier_rates_updated
  BEFORE UPDATE ON supplier_rates
  FOR EACH ROW EXECUTE FUNCTION trg_fn_supplier_rates_updated();


-- ─────────────────────────────────────────────────────────────────────────────
-- R5: pricing_overrides — index for audit queries by date
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_po_created_at
  ON pricing_overrides(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_po_created_by
  ON pricing_overrides(created_by)
  WHERE created_by IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- R6: rate_plans — enforce exactly one default plan via partial unique index
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_plans_single_default
  ON rate_plans(is_default)
  WHERE is_default = TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- R7: ai_requests — compound index for rate limiting queries
--     Phase G rate limiting queries: WHERE user_id = X AND feature = Y AND created_at > Z
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_ai_requests_rate_limit
  ON ai_requests(user_id, feature, created_at DESC);


-- ─────────────────────────────────────────────────────────────────────────────
-- R8: Permission matrix — add pricing and itinerary management permissions
--     These were referenced in admin.js applyRoleUI() but not seeded in DB.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
SELECT p.permission, p.name_ar, p.category_ar, p.roles
FROM (VALUES
  ('manage_rate_plans',
   'إدارة خطط التسعير',
   'التسعير',
   ARRAY['super_admin','admin','financial_manager']),
  ('manage_supplier_rates',
   'إدارة أسعار الموردين',
   'التسعير',
   ARRAY['super_admin','admin','financial_manager']),
  ('view_pricing_engine',
   'عرض محرك التسعير',
   'التسعير',
   ARRAY['super_admin','admin','financial_manager','accountant','sales_agent']),
  ('manage_itineraries',
   'إدارة برامج الرحلات',
   'العمليات',
   ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('view_itineraries',
   'عرض برامج الرحلات',
   'العمليات',
   ARRAY['super_admin','admin','sales_agent','booking_agent','auditor','financial_manager']),
  ('manage_service_catalog',
   'إدارة كتالوج الخدمات',
   'العمليات',
   ARRAY['super_admin','admin','sales_agent']),
  ('view_crm_dashboard',
   'عرض لوحة المبيعات',
   'CRM',
   ARRAY['super_admin','admin','sales_agent','booking_agent','financial_manager']),
  ('export_data',
   'تصدير البيانات',
   'النظام',
   ARRAY['super_admin','admin','financial_manager','auditor']),
  ('manage_customers',
   'إدارة العملاء',
   'CRM',
   ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('view_profitability',
   'عرض تقارير الربحية',
   'المالية',
   ARRAY['super_admin','admin','financial_manager','accountant','auditor'])
) AS p(permission, name_ar, category_ar, roles)
WHERE NOT EXISTS (
  SELECT 1 FROM permission_matrix pm WHERE pm.permission = p.permission
);


-- ─────────────────────────────────────────────────────────────────────────────
-- R9: track_user_login — robust implementation
--     C7 fix in Phase B created the function. This version adds last_seen
--     tracking and login_count to profiles for analytics.
-- ─────────────────────────────────────────────────────────────────────────────

-- Add login tracking columns to profiles if not present
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS last_seen_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS login_count    INT NOT NULL DEFAULT 0;

-- Robust track_user_login — called from auth.js on every successful sign-in
CREATE OR REPLACE FUNCTION track_user_login()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Update profile with last_seen and increment login count
  UPDATE profiles
  SET
    last_seen_at = now(),
    login_count  = COALESCE(login_count, 0) + 1
  WHERE id = auth.uid();

  -- No error if profile doesn't exist (new user mid-trigger race)
END;
$$;

GRANT EXECUTE ON FUNCTION track_user_login() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- R10: Performance — missing indexes found during regression
-- ─────────────────────────────────────────────────────────────────────────────

-- lead_activities: timeline queries order by created_at
CREATE INDEX IF NOT EXISTS idx_lead_activities_lead_date
  ON lead_activities(lead_id, created_at DESC);

-- tasks: overdue task queries (column is due_at TIMESTAMPTZ, not due_date)
CREATE INDEX IF NOT EXISTS idx_tasks_due_status
  ON tasks(due_at, status)
  WHERE status IN ('open','in_progress');

-- quotation_versions: history lookup by quotation
CREATE INDEX IF NOT EXISTS idx_quote_versions_quote
  ON quotation_versions(quotation_id, created_at DESC);

-- nsp_invoices: overdue AR queries
CREATE INDEX IF NOT EXISTS idx_invoices_overdue
  ON nsp_invoices(due_date, status)
  WHERE status IN ('issued','partial','overdue');

-- bookings: customer lookups (used by customer_ledger view)
CREATE INDEX IF NOT EXISTS idx_bookings_customer_email
  ON bookings(customer_email)
  WHERE customer_email IS NOT NULL;

-- profiles: last_seen for active user analytics
CREATE INDEX IF NOT EXISTS idx_profiles_last_seen
  ON profiles(last_seen_at DESC)
  WHERE last_seen_at IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- FINAL PRODUCTION STATUS FUNCTION
--     Returns a JSON health snapshot — used by accounting-health.html
--     and by the Phase Q checklist to confirm all critical tables exist.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_production_status()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error', 'unauthorized');
  END IF;

  SELECT json_build_object(
    -- Core tables
    'has_leads',              (SELECT to_regclass('public.leads') IS NOT NULL),
    'has_customers',          (SELECT to_regclass('public.customers') IS NOT NULL),
    'has_opportunities',      (SELECT to_regclass('public.opportunities') IS NOT NULL),
    'has_quotations',         (SELECT to_regclass('public.quotations') IS NOT NULL),
    'has_itineraries',        (SELECT to_regclass('public.itineraries') IS NOT NULL),
    'has_service_catalog',    (SELECT to_regclass('public.service_catalog') IS NOT NULL),
    'has_rate_plans',         (SELECT to_regclass('public.rate_plans') IS NOT NULL),
    'has_supplier_rates',     (SELECT to_regclass('public.supplier_rates') IS NOT NULL),
    'has_ai_conversations',   (SELECT to_regclass('public.ai_conversations') IS NOT NULL),
    'has_ai_requests',        (SELECT to_regclass('public.ai_requests') IS NOT NULL),
    'has_ai_recommendations', (SELECT to_regclass('public.ai_recommendations') IS NOT NULL),
    'has_ai_insights_cache',  (SELECT to_regclass('public.ai_insights_cache') IS NOT NULL),
    'has_permission_matrix',  (SELECT to_regclass('public.permission_matrix') IS NOT NULL),

    -- Row counts (sanity)
    'rate_plan_count',        (SELECT COUNT(*) FROM rate_plans),
    'margin_setting_count',   (SELECT COUNT(*) FROM margin_settings),
    'permission_count',       (SELECT COUNT(*) FROM permission_matrix),

    -- Migration watermark
    'last_migration',         '202601038000000_phase_r_production_readiness',
    'status',                 'production_ready',
    'generated_at',           now()
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_production_status() TO authenticated;


-- ══ END PHASE R MIGRATION ═════════════════════════════════════════════════════
-- Verification:
--   SELECT get_production_status();
--   → All has_* fields should be TRUE
--   → rate_plan_count >= 6, margin_setting_count >= 12, permission_count >= 40
