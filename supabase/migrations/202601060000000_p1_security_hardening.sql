-- =============================================================================
-- MIGRATION: 202601060000000_p1_security_hardening.sql
-- Phase 16.1 — P1 Security Fixes
--
-- Fixes:
--   P1.1 — Add internal admin/permission checks to unprotected SECURITY DEFINER RPCs
--   P1.2 — Revoke excessive EXECUTE grants from PUBLIC; re-grant to appropriate roles
--
-- Approach: use existing permission system (is_any_admin, has_permission, can_*)
-- Never bypass RLS. Never add frontend-only guards.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: REVOKE FROM PUBLIC where functions were left open
-- PostgreSQL auto-grants EXECUTE on new functions to PUBLIC in some configs.
-- Belt-and-suspenders: revoke from PUBLIC, then re-grant explicitly.
-- ─────────────────────────────────────────────────────────────────────────────

-- Role helper functions — authenticated only (used in RLS, must remain fast)
REVOKE ALL ON FUNCTION auth_role()             FROM PUBLIC;
REVOKE ALL ON FUNCTION is_any_admin()          FROM PUBLIC;
REVOKE ALL ON FUNCTION is_super_admin()        FROM PUBLIC;
REVOKE ALL ON FUNCTION can_read_financial()    FROM PUBLIC;
REVOKE ALL ON FUNCTION can_write_financial()   FROM PUBLIC;
REVOKE ALL ON FUNCTION can_handle_payments()   FROM PUBLIC;
REVOKE ALL ON FUNCTION can_approve_financial() FROM PUBLIC;
REVOKE ALL ON FUNCTION can_close_period()      FROM PUBLIC;
REVOKE ALL ON FUNCTION can_read_bookings()     FROM PUBLIC;
REVOKE ALL ON FUNCTION can_write_bookings()    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION auth_role()             TO authenticated;
GRANT EXECUTE ON FUNCTION is_any_admin()          TO authenticated;
GRANT EXECUTE ON FUNCTION is_super_admin()        TO authenticated;
GRANT EXECUTE ON FUNCTION can_read_financial()    TO authenticated;
GRANT EXECUTE ON FUNCTION can_write_financial()   TO authenticated;
GRANT EXECUTE ON FUNCTION can_handle_payments()   TO authenticated;
GRANT EXECUTE ON FUNCTION can_approve_financial() TO authenticated;
GRANT EXECUTE ON FUNCTION can_close_period()      TO authenticated;
GRANT EXECUTE ON FUNCTION can_read_bookings()     TO authenticated;
GRANT EXECUTE ON FUNCTION can_write_bookings()    TO authenticated;

-- get_admin_role — authenticated only, already safe (SELECTs own row)
REVOKE ALL ON FUNCTION get_admin_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_admin_role() TO authenticated;

-- get_quote_by_token — intentionally anon (public quote view link), keep as-is
-- GRANT EXECUTE ON FUNCTION get_quote_by_token(TEXT) TO anon, authenticated; — unchanged

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Add internal auth checks to unprotected SECURITY DEFINER RPCs
-- Each function is rewritten with a guard block at the top.
-- Permission used matches the business domain.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── get_crm_summary() — Sales domain → can_read_bookings() ───────────────────
CREATE OR REPLACE FUNCTION get_crm_summary()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT can_read_bookings() THEN
    RAISE EXCEPTION 'unauthorized: CRM summary requires booking read permission';
  END IF;
  RETURN (
    SELECT json_build_object(
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
    )
  );
END;
$$;

-- ── get_quotation_summary() — Sales/Finance → can_read_bookings() ─────────────
CREATE OR REPLACE FUNCTION get_quotation_summary()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT can_read_bookings() THEN
    RAISE EXCEPTION 'unauthorized: quotation summary requires booking read permission';
  END IF;
  RETURN (
    SELECT json_build_object(
      'total',    (SELECT count(*) FROM quotations),
      'draft',    (SELECT count(*) FROM quotations WHERE status = 'draft'),
      'sent',     (SELECT count(*) FROM quotations WHERE status = 'sent'),
      'accepted', (SELECT count(*) FROM quotations WHERE status = 'accepted'),
      'expired',  (SELECT count(*) FROM quotations WHERE status = 'expired'),
      'total_value', (SELECT COALESCE(sum(total_amount),0) FROM quotations WHERE status NOT IN ('draft','rejected','expired'))
    )
  );
END;
$$;

-- ── get_b2b_summary() — B2B/Contracts → can_read_bookings() ──────────────────
CREATE OR REPLACE FUNCTION get_b2b_summary()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT can_read_bookings() THEN
    RAISE EXCEPTION 'unauthorized: B2B summary requires booking read permission';
  END IF;
  RETURN (
    SELECT json_build_object(
      'total_partners',    (SELECT count(*) FROM b2b_partners),
      'active_partners',   (SELECT count(*) FROM b2b_partners WHERE is_active = true),
      'strategic_partners',(SELECT count(*) FROM b2b_partners WHERE tier = 'strategic' AND is_active = true),
      'expiring_soon',     (SELECT count(*) FROM b2b_partners
                            WHERE contract_status = 'active'
                              AND contract_expiry IS NOT NULL
                              AND contract_expiry <= current_date + interval '60 days'),
      'total_contracts',   (SELECT count(*) FROM supplier_contracts),
      'active_contracts',  (SELECT count(*) FROM supplier_contracts WHERE status = 'active'),
      'expiring_contracts',(SELECT count(*) FROM supplier_contracts
                            WHERE status = 'active'
                              AND valid_to <= current_date + interval '30 days'),
      'total_rates',       (SELECT count(*) FROM partner_rates)
    )
  );
END;
$$;

-- ── get_expiring_contracts() — Contracts domain → can_read_bookings() ─────────
CREATE OR REPLACE FUNCTION get_expiring_contracts(days_ahead INT DEFAULT 30)
RETURNS TABLE (
  id            UUID,
  supplier_id   UUID,
  supplier_name TEXT,
  valid_to      DATE,
  status        TEXT,
  days_left     INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT can_read_bookings() THEN
    RAISE EXCEPTION 'unauthorized: contract data requires booking read permission';
  END IF;
  RETURN QUERY
  SELECT
    sc.id, sc.supplier_id,
    s.name_ar AS supplier_name,
    sc.valid_to, sc.status,
    (sc.valid_to - current_date)::INT AS days_left
  FROM supplier_contracts sc
  JOIN suppliers s ON s.id = sc.supplier_id
  WHERE sc.status = 'active'
    AND sc.valid_to <= current_date + (days_ahead || ' days')::interval
    AND sc.valid_to >= current_date
  ORDER BY sc.valid_to ASC;
END;
$$;

-- ── get_procurement_dashboard() — Procurement → can_read_bookings() ───────────
CREATE OR REPLACE FUNCTION get_procurement_dashboard()
RETURNS TABLE (
  trip_service_id     UUID,
  trip_file_id        UUID,
  trip_number         TEXT,
  trip_title          TEXT,
  trip_status         TEXT,
  travel_date_start   DATE,
  service_type        TEXT,
  service_name        TEXT,
  supplier_id         UUID,
  supplier_name       TEXT,
  service_date        DATE,
  confirmation_status TEXT,
  confirmation_ref    TEXT,
  confirmation_deadline DATE,
  is_critical         BOOLEAN,
  days_to_travel      INT,
  last_request_date   DATE,
  last_request_status TEXT,
  request_count       BIGINT,
  urgency_level       TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: procurement dashboard requires operations access';
  END IF;
  RETURN QUERY
  SELECT
    ts.id                                         AS trip_service_id,
    tf.id                                         AS trip_file_id,
    tf.trip_number,
    COALESCE(tf.customer_name, tf.destination, tf.trip_number) AS trip_title,
    tf.ops_status                                 AS trip_status,
    tf.travel_date_start,
    ts.service_type,
    ts.name_ar                                    AS service_name,
    ts.supplier_id,
    s.name_ar                                     AS supplier_name,
    ts.service_date,
    ts.confirmation_status,
    ts.confirmation_ref,
    ts.confirmation_deadline,
    (tf.travel_date_start IS NOT NULL
      AND tf.travel_date_start <= current_date + interval '7 days'
      AND ts.confirmation_status NOT IN ('confirmed','cancelled'))  AS is_critical,
    (tf.travel_date_start - current_date)::INT    AS days_to_travel,
    pr.last_request_date,
    pr.last_request_status,
    pr.request_count,
    CASE
      WHEN tf.travel_date_start <= current_date + interval '3 days'
           AND ts.confirmation_status NOT IN ('confirmed','cancelled') THEN 'critical'
      WHEN tf.travel_date_start <= current_date + interval '7 days'
           AND ts.confirmation_status NOT IN ('confirmed','cancelled') THEN 'high'
      WHEN tf.travel_date_start <= current_date + interval '14 days' THEN 'medium'
      ELSE 'low'
    END AS urgency_level
  FROM trip_services ts
  JOIN trip_files tf ON tf.id = ts.trip_file_id
  LEFT JOIN suppliers s ON s.id = ts.supplier_id
  LEFT JOIN LATERAL (
    SELECT
      max(sr.request_date)   AS last_request_date,
      max(sr.status)         AS last_request_status,
      count(*)               AS request_count
    FROM supplier_requests sr
    WHERE sr.trip_service_id = ts.id
  ) pr ON TRUE
  WHERE tf.ops_status NOT IN ('cancelled','closed')
  ORDER BY days_to_travel ASC NULLS LAST, urgency_level;
END;
$$;

-- ── get_procurement_summary() — Procurement → can_read_bookings() ─────────────
CREATE OR REPLACE FUNCTION get_procurement_summary()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: procurement summary requires operations access';
  END IF;
  RETURN (
    SELECT json_build_object(
      'pending_confirmations', (SELECT count(*) FROM trip_services WHERE confirmation_status = 'pending'),
      'confirmed',             (SELECT count(*) FROM trip_services WHERE confirmation_status = 'confirmed'),
      'critical',              (
        SELECT count(*) FROM trip_services ts
        JOIN trip_files tf ON tf.id = ts.trip_file_id
        WHERE ts.confirmation_status NOT IN ('confirmed','cancelled')
          AND tf.travel_date_start <= current_date + interval '3 days'
      ),
      'total_active_services', (
        SELECT count(*) FROM trip_services ts
        JOIN trip_files tf ON tf.id = ts.trip_file_id
        WHERE tf.ops_status NOT IN ('cancelled','closed')
      )
    )
  );
END;
$$;

-- ── get_supplier_workload() — Supplier domain → can_read_bookings() ───────────
CREATE OR REPLACE FUNCTION get_supplier_workload(p_supplier_id UUID)
RETURNS TABLE (
  trip_service_id     UUID,
  trip_number         TEXT,
  trip_title          TEXT,
  service_type        TEXT,
  service_name        TEXT,
  service_date        DATE,
  quantity            NUMERIC,
  confirmation_status TEXT,
  confirmation_ref    TEXT,
  travel_date_start   DATE
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: supplier workload requires operations access';
  END IF;
  RETURN QUERY
  SELECT
    ts.id,
    tf.trip_number,
    COALESCE(tf.customer_name, tf.destination, tf.trip_number),
    ts.service_type,
    ts.name_ar,
    ts.service_date,
    ts.quantity,
    ts.confirmation_status,
    ts.confirmation_ref,
    tf.travel_date_start
  FROM trip_services ts
  JOIN trip_files tf ON tf.id = ts.trip_file_id
  WHERE ts.supplier_id = p_supplier_id
    AND tf.ops_status NOT IN ('cancelled','closed')
  ORDER BY ts.service_date ASC;
END;
$$;

-- ── get_communication_stats() — Communications → is_any_admin() ──────────────
CREATE OR REPLACE FUNCTION get_communication_stats()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_any_admin() THEN
    RAISE EXCEPTION 'unauthorized: communication stats requires admin access';
  END IF;
  RETURN (
    SELECT json_build_object(
      'total_sent_today',   (SELECT count(*) FROM communication_queue WHERE status='sent' AND sent_at >= current_date),
      'pending',            (SELECT count(*) FROM communication_queue WHERE status='pending'),
      'failed',             (SELECT count(*) FROM communication_queue WHERE status='failed'),
      'total_this_month',   (SELECT count(*) FROM communication_queue WHERE status='sent' AND sent_at >= date_trunc('month', now())),
      'by_channel',         (SELECT json_object_agg(channel, cnt) FROM (
                                SELECT channel, count(*) AS cnt
                                FROM communication_queue WHERE status='sent' AND sent_at >= current_date
                                GROUP BY channel
                             ) x),
      'templates_active',   (SELECT count(*) FROM communication_templates WHERE is_active=TRUE)
    )
  );
END;
$$;

-- ── render_template() — Communications → is_any_admin() ──────────────────────
-- Template body may contain sensitive trip/customer data variables.
CREATE OR REPLACE FUNCTION render_template(
  p_template_id UUID,
  p_vars        JSONB
)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_body TEXT;
  v_key  TEXT;
  v_val  TEXT;
BEGIN
  IF NOT is_any_admin() THEN
    RAISE EXCEPTION 'unauthorized: template rendering requires admin access';
  END IF;

  SELECT body_ar INTO v_body
  FROM communication_templates
  WHERE id = p_template_id AND is_active = TRUE;

  IF v_body IS NULL THEN RETURN NULL; END IF;

  FOR v_key, v_val IN
    SELECT key, value::TEXT FROM jsonb_each_text(p_vars)
  LOOP
    v_body := replace(v_body, '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  RETURN v_body;
END;
$$;

-- ── check_automation_cooldown() — Marketing → can_read_bookings() ─────────────
-- Cooldown is internal automation logic; only admin/sales should query it.
-- DROP required first: cannot rename parameters with CREATE OR REPLACE (PG 42P13)
DROP FUNCTION IF EXISTS check_automation_cooldown(UUID, UUID);

CREATE OR REPLACE FUNCTION check_automation_cooldown(
  p_rule_id    UUID,   -- the automation rule to check
  p_entity_id  UUID    -- entity/segment context (NULL = global)
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cooldown_hours INT;
  v_last_run       TIMESTAMPTZ;
BEGIN
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: automation check requires marketing access';
  END IF;

  -- Get rule cooldown period (stored in hours per Phase 14 schema)
  SELECT COALESCE(cooldown_hours, 24) INTO v_cooldown_hours
  FROM automation_rules
  WHERE id = p_rule_id;

  IF NOT FOUND THEN RETURN FALSE; END IF;

  -- Check last execution using correct table: automation_executions
  SELECT MAX(executed_at) INTO v_last_run
  FROM automation_executions
  WHERE rule_id   = p_rule_id
    AND (p_entity_id IS NULL OR entity_id = p_entity_id)
    AND status = 'completed';

  IF v_last_run IS NULL THEN RETURN TRUE; END IF;

  RETURN v_last_run < now() - (v_cooldown_hours || ' hours')::INTERVAL;
END;
$$;

-- ── get_daily_schedule() — Operations → can_read_bookings() ───────────────────
CREATE OR REPLACE FUNCTION get_daily_schedule(p_date DATE DEFAULT CURRENT_DATE)
RETURNS TABLE (
  trip_file_id  UUID,
  trip_number   TEXT,
  customer_name TEXT,
  destination   TEXT,
  service_type  TEXT,
  service_name  TEXT,
  service_date  DATE,
  supplier_name TEXT,
  resource_name TEXT,
  start_time    TIME,
  end_time      TIME,
  notes         TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: schedule requires operations access';
  END IF;
  RETURN QUERY
  SELECT
    tf.id,
    tf.trip_number,
    tf.customer_name,
    tf.destination,
    ts.service_type,
    ts.name_ar,
    ts.service_date,
    s.name_ar,
    COALESCE(d.name, g.name, v.plate_number) AS resource_name,
    ra.start_time,
    ra.end_time,
    ra.notes
  FROM trip_services ts
  JOIN trip_files tf ON tf.id = ts.trip_file_id
  LEFT JOIN suppliers s ON s.id = ts.supplier_id
  LEFT JOIN resource_assignments ra ON ra.trip_service_id = ts.id
  LEFT JOIN drivers  d ON d.id = ra.driver_id
  LEFT JOIN guides   g ON g.id = ra.guide_id
  LEFT JOIN vehicles v ON v.id = ra.vehicle_id
  WHERE ts.service_date = p_date
    AND tf.ops_status NOT IN ('cancelled','closed')
  ORDER BY ra.start_time ASC NULLS LAST;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Re-grant only to authenticated (revoke from PUBLIC safety net)
-- ─────────────────────────────────────────────────────────────────────────────

REVOKE ALL ON FUNCTION get_crm_summary()                     FROM PUBLIC;
REVOKE ALL ON FUNCTION get_quotation_summary()               FROM PUBLIC;
REVOKE ALL ON FUNCTION get_b2b_summary()                     FROM PUBLIC;
REVOKE ALL ON FUNCTION get_expiring_contracts(INT)           FROM PUBLIC;
REVOKE ALL ON FUNCTION get_procurement_dashboard()           FROM PUBLIC;
REVOKE ALL ON FUNCTION get_procurement_summary()             FROM PUBLIC;
REVOKE ALL ON FUNCTION get_supplier_workload(UUID)           FROM PUBLIC;
REVOKE ALL ON FUNCTION get_communication_stats()             FROM PUBLIC;
REVOKE ALL ON FUNCTION render_template(UUID, JSONB)          FROM PUBLIC;
REVOKE ALL ON FUNCTION check_automation_cooldown(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION get_daily_schedule(DATE)              FROM PUBLIC;

GRANT EXECUTE ON FUNCTION get_crm_summary()                     TO authenticated;
GRANT EXECUTE ON FUNCTION get_quotation_summary()               TO authenticated;
GRANT EXECUTE ON FUNCTION get_b2b_summary()                     TO authenticated;
GRANT EXECUTE ON FUNCTION get_expiring_contracts(INT)           TO authenticated;
GRANT EXECUTE ON FUNCTION get_procurement_dashboard()           TO authenticated;
GRANT EXECUTE ON FUNCTION get_procurement_summary()             TO authenticated;
GRANT EXECUTE ON FUNCTION get_supplier_workload(UUID)           TO authenticated;
GRANT EXECUTE ON FUNCTION get_communication_stats()             TO authenticated;
GRANT EXECUTE ON FUNCTION render_template(UUID, JSONB)          TO authenticated;
GRANT EXECUTE ON FUNCTION check_automation_cooldown(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_daily_schedule(DATE)              TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Revoke accumulation-of-duplicates (get_ai_usage_today granted 3x)
-- ─────────────────────────────────────────────────────────────────────────────
-- No action needed for duplicate GRANTs — PostgreSQL deduplicates GRANT.
-- Document only: get_ai_usage_today, get_crm_summary, get_quotation_summary,
-- get_lead_conversion_stats, get_itinerary_summary, get_partner_dashboard,
-- get_partner_quotes were granted multiple times across migrations.
-- This is harmless but noted for cleanup.

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: COMMENT — P1.4 Auth guard findings
-- The following pages use custom auth patterns (not adminCheckAuth) but DO
-- verify session + admin_users before rendering data:
--   accounting-health.html  → inline session + admin_users check ✅
-- The following pages include admin.js + use RLS-protected DB calls BUT do
-- NOT call adminCheckAuth() explicitly:
--   expenses.html, suppliers.html, reports.html, ar-ap.html,
--   bank-reconciliation.html, cash-bank-wallets.html, credit-debit-notes.html,
--   fiscal-periods.html, journal-entries.html, roles-permissions.html
-- These pages are protected at DB layer by RLS (can_read_financial, etc).
-- A non-admin user who somehow reaches the page shell sees no data.
-- However: the page shell IS rendered for unauthenticated users (JS redirect
-- only fires after page load). Fix applied in JS patch below.
-- See: p1_auth_guard_patch.js — injected into each page's DOMContentLoaded
-- =============================================================================
-- END OF MIGRATION
-- =============================================================================
