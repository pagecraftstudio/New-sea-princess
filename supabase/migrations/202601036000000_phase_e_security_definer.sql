-- ============================================================
-- Migration 036 — Phase E: SECURITY DEFINER Audit
--
-- Findings:
--   E1 — get_quotation_summary(): GRANT TO authenticated, no admin
--        check → any public registered user sees total quotation
--        counts and values.
--   E2 — get_accounting_health(): GRANT TO authenticated, no admin
--        check → leaks financial integrity data to public users.
--   E3 — get_balance_sheet_status(): same issue.
--   E4 — get_itinerary_summary(): GRANT TO authenticated, no admin
--        check → any authenticated user sees itinerary totals.
--   E5 — submit_expense(): SECURITY DEFINER, no GRANT (safe default)
--        but no explicit admin/role check inside → add guard.
--   E6 — recalculate_itinerary_totals(): GRANT TO authenticated,
--        SECURITY DEFINER, writes to itineraries table → restrict.
--
-- Fixed functions receive admin_users membership check.
-- Non-admin callers receive a zero/error result, not an exception.
-- This is consistent with the Phase C pattern (get_crm_summary,
-- get_ai_usage_today, get_lead_conversion_stats already fixed in 034).
--
-- Safe: CREATE OR REPLACE only. No table drops. No data changes.
-- Run after: 202601035000000_phase_d_schema.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- E1: get_quotation_summary — restrict to admin_users
-- ─────────────────────────────────────────────────────────────────────────────

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
    'total_value',    (SELECT COALESCE(SUM(total_amount),0) FROM quotations
                        WHERE status NOT IN ('rejected','cancelled','expired')),
    'accepted_value', (SELECT COALESCE(SUM(total_amount),0) FROM quotations
                        WHERE status IN ('accepted','deposit_pending','confirmed')),
    'margin_avg',     (SELECT ROUND(AVG(margin_pct),1) FROM quotations
                        WHERE status NOT IN ('rejected','cancelled','expired')
                          AND total_amount > 0)
  );
END;
$$;

COMMENT ON FUNCTION get_quotation_summary() IS
'Returns quotation KPIs for the CRM dashboard. Admin-only. E1 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- E2: get_accounting_health — restrict to admin_users with financial access
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_accounting_health()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unbalanced_journals      INT := 0;
  v_missing_mappings         INT := 0;
  v_orphan_invoice_items     INT := 0;
  v_orphan_pay_alloc         INT := 0;
  v_closed_period_violations INT := 0;
  v_taxes_no_account         INT := 0;
  v_expenses_no_cost_center  INT := 0;
  v_unreconciled_banks       INT := 0;
  v_failed_auto_accounting   INT := 0;
  v_unposted_old_expenses    INT := 0;
  v_invoices_no_journal      INT := 0;
  v_required_mappings TEXT[] := ARRAY[
    'ar_account','cash_account','revenue_default','ap_account',
    'bank_fees','expense_general','customer_advances'
  ];
BEGIN
  -- Restrict to financial readers or above
  IF NOT can_read_financial() THEN
    RETURN json_build_object('error', 'unauthorized');
  END IF;

  -- Unbalanced posted journals
  SELECT COUNT(*) INTO v_unbalanced_journals
  FROM journal_entries
  WHERE status = 'posted'
    AND ABS(total_debit - total_credit) > 0.01;

  -- Missing required accounting_mappings
  SELECT COUNT(*) INTO v_missing_mappings
  FROM unnest(v_required_mappings) AS m(key)
  WHERE NOT EXISTS (
    SELECT 1 FROM accounting_mappings WHERE mapping_key = m.key
  );

  -- Orphan invoice items (invoice deleted, items remain)
  SELECT COUNT(*) INTO v_orphan_invoice_items
  FROM invoice_items ii
  WHERE NOT EXISTS (SELECT 1 FROM nsp_invoices ni WHERE ni.id = ii.invoice_id);

  -- Orphan payment allocations
  SELECT COUNT(*) INTO v_orphan_pay_alloc
  FROM payment_allocations pa
  WHERE NOT EXISTS (SELECT 1 FROM nsp_payments p WHERE p.id = pa.payment_id)
     OR NOT EXISTS (SELECT 1 FROM nsp_invoices i WHERE i.id = pa.invoice_id);

  -- Old unposted expenses (>30 days in draft)
  SELECT COUNT(*) INTO v_unposted_old_expenses
  FROM nsp_expenses
  WHERE status IN ('draft','submitted')
    AND created_at < now() - INTERVAL '30 days';

  -- Invoices in issued/partial status without journal entries
  SELECT COUNT(*) INTO v_invoices_no_journal
  FROM nsp_invoices
  WHERE status IN ('issued','partial','paid')
    AND (journal_entry_id IS NULL);

  RETURN json_build_object(
    'ok',                        true,
    'unbalanced_journals',        v_unbalanced_journals,
    'missing_mappings',           v_missing_mappings,
    'orphan_invoice_items',       v_orphan_invoice_items,
    'orphan_payment_allocations', v_orphan_pay_alloc,
    'unposted_old_expenses',      v_unposted_old_expenses,
    'invoices_missing_journal',   v_invoices_no_journal,
    'status',                     CASE
      WHEN v_unbalanced_journals > 0 OR v_missing_mappings > 0
        THEN 'critical'
      WHEN v_orphan_invoice_items > 0 OR v_invoices_no_journal > 0
        THEN 'warning'
      ELSE 'healthy'
    END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', SQLERRM, 'status', 'critical');
END;
$$;

COMMENT ON FUNCTION get_accounting_health() IS
'Financial health check. Restricted to can_read_financial() roles. E2 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- E3: get_balance_sheet_status — restrict to financial readers
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_balance_sheet_status()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT can_read_financial() THEN
    RETURN json_build_object('error', 'unauthorized');
  END IF;

  RETURN (
    SELECT json_build_object(
      'ok',                true,
      'total_assets',      total_assets,
      'total_liabilities', total_liabilities,
      'total_equity',      total_equity,
      'difference',        difference,
      'is_balanced',       is_balanced,
      'status',            CASE WHEN is_balanced THEN 'healthy' ELSE 'critical' END
    )
    FROM check_balance_sheet_integrity()
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', SQLERRM, 'status', 'critical');
END;
$$;

COMMENT ON FUNCTION get_balance_sheet_status() IS
'Balance sheet integrity check. Restricted to can_read_financial(). E3 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- E4: get_itinerary_summary — restrict to admin_users
-- ─────────────────────────────────────────────────────────────────────────────
-- DROP required: phase E changes return type TABLE(...) → JSON.
-- PostgreSQL forbids CREATE OR REPLACE from changing return type.

DROP FUNCTION IF EXISTS get_itinerary_summary();

CREATE OR REPLACE FUNCTION get_itinerary_summary()
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
    'total_itineraries', (SELECT COUNT(*)                                    FROM itineraries),
    'draft_count',       (SELECT COUNT(*) FILTER (WHERE status='draft')      FROM itineraries),
    'final_count',       (SELECT COUNT(*) FILTER (WHERE status='final')      FROM itineraries),
    'template_count',    (SELECT COUNT(*) FILTER (WHERE is_template=TRUE)    FROM itineraries),
    'total_sell_value',  (SELECT COALESCE(SUM(sell_total),0)                 FROM itineraries)
  );
END;
$$;

COMMENT ON FUNCTION get_itinerary_summary() IS
'Returns itinerary KPIs. Admin-only. E4 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- E5: submit_expense — add is_any_admin() guard
-- Previously: no GRANT (safe) but no role check either.
-- Add GRANT to authenticated (needed for .rpc() calls) + role check.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION submit_expense(p_expense_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exp nsp_expenses%ROWTYPE;
BEGIN
  -- Only admin users can submit expenses
  IF NOT is_any_admin() THEN
    RETURN json_build_object('ok', false, 'error', 'Admin access required');
  END IF;

  SELECT * INTO v_exp FROM nsp_expenses WHERE id = p_expense_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Expense not found');
  END IF;
  IF v_exp.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error',
      'Only draft expenses can be submitted. Current status: ' || v_exp.status);
  END IF;

  UPDATE nsp_expenses
     SET status = 'submitted', submitted_by = auth.uid(), submitted_at = now()
   WHERE id = p_expense_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, after_data)
  VALUES (auth.uid(), 'SUBMIT', 'nsp_expenses', p_expense_id, v_exp.expense_number,
          json_build_object('status','submitted')::jsonb);

  RETURN json_build_object('ok', true, 'expense_number', v_exp.expense_number);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_expense(UUID) TO authenticated;

COMMENT ON FUNCTION submit_expense(UUID) IS
'Submits a draft expense for approval. Requires is_any_admin(). E5 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- E6: recalculate_itinerary_totals — restrict to admin_users
-- This writes to itineraries.cost_total/sell_total so must be guarded.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalculate_itinerary_totals(p_itinerary_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cost  NUMERIC(14,2);
  v_sell  NUMERIC(14,2);
  v_gp    NUMERIC(14,2);
  v_marg  NUMERIC(5,2);
BEGIN
  -- Only admins can trigger recalculation
  IF NOT is_any_admin() THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;

  SELECT
    COALESCE(SUM(cost_total), 0),
    COALESCE(SUM(sell_total), 0)
  INTO v_cost, v_sell
  FROM itinerary_items
  WHERE itinerary_id = p_itinerary_id
    AND is_included = TRUE;

  v_gp   := v_sell - v_cost;
  v_marg := CASE WHEN v_sell > 0 THEN ROUND((v_gp / v_sell) * 100, 2) ELSE 0 END;

  UPDATE itineraries
  SET cost_total   = v_cost,
      sell_total   = v_sell,
      gross_profit = v_gp,
      margin_pct   = v_marg,
      updated_at   = now()
  WHERE id = p_itinerary_id;
END;
$$;

COMMENT ON FUNCTION recalculate_itinerary_totals(UUID) IS
'Recalculates and writes itinerary cost/sell/profit totals. Admin-only. E6 Phase E.';


-- ─────────────────────────────────────────────────────────────────────────────
-- COMPREHENSIVE GRANT AUDIT SUMMARY (documentation)
--
-- Functions reviewed and their final authorization status:
--
-- TRIGGER functions (SECURITY DEFINER for elevated access during triggers):
--   fn_audit_financial()           — trigger only, no client GRANT → SAFE
--   trg_booking_number_fn()        — trigger only → SAFE
--   trg_new_user()                 — trigger only → SAFE
--   set_ai_rec_updated_at()        — trigger only → SAFE
--   sync_opportunity_quotes_count()— trigger only, GRANT TO authenticated → LOW RISK (no data leak)
--   recalculate_quote_totals()     — GRANT TO authenticated, writes → acceptable (quote owner only)
--
-- Role/permission helpers (SECURITY DEFINER, safe by design):
--   auth_role(), is_any_admin(), is_super_admin(), can_*()  — return booleans only → SAFE
--   get_admin_role()               — returns caller's own role only → SAFE (reviewed H3)
--   has_permission(), has_ai_permission() — boolean only → SAFE
--   get_my_permissions()           — caller's own permissions only → SAFE
--
-- CRM/financial aggregates (previously unprotected — fixed in 034 + this migration):
--   get_crm_summary()             — admin gate added in 034 ✓
--   get_lead_conversion_stats()   — admin gate added in 034 ✓
--   get_ai_usage_today()          — admin gate added in 034 ✓
--   get_quotation_summary()       — admin gate added THIS migration ✓
--   get_accounting_health()       — financial_reader gate added THIS migration ✓
--   get_balance_sheet_status()    — financial_reader gate added THIS migration ✓
--   get_itinerary_summary()       — admin gate added THIS migration ✓
--
-- Financial approval RPCs (SECURITY DEFINER, no GRANT — safe default):
--   submit_expense()              — is_any_admin() guard added THIS migration ✓
--   approve_expense()             — can_approve_financial() already inside body ✓
--   reject_expense()              — can_approve_financial() already inside body ✓
--   approve_credit_note()         — permission checked inside body ✓
--   reject_credit_note()          — permission checked inside body ✓
--   submit_refund()               — same pattern as submit_expense (no check)
--   approve_refund()              — permission checked inside body ✓
--   reject_refund()               — permission checked inside body ✓
--   get_pending_approvals()       — can_approve_financial() inside body ✓
--
-- AI/rate/cache functions:
--   check_ai_rate_limit()        — service-role caller (edge fn), no public risk ✓
--   get_cached_insight()         — admin gate added in 035 ✓
--   set_cached_insight()         — admin gate added in 035 ✓
--   purge_expired_cache()        — admin gate via service role ✓
--
-- Pricing engine:
--   calculate_sell_price()       — pure math, no data leak → SAFE
--   get_supplier_rate()          — returns rates; GRANT TO authenticated acceptable
--                                  (rates are not highly sensitive, needed for quote UI)
--   get_margin_setting()         — returns margin targets; GRANT TO authenticated acceptable
--   recalculate_quotation_totals()— writes, GRANT TO authenticated (quote owner checked via RLS on update)
--
-- ─────────────────────────────────────────────────────────────────────────────

-- Note: submit_refund has same pattern as old submit_expense.
-- Adding guard here too for completeness.
CREATE OR REPLACE FUNCTION submit_refund(p_refund_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_refund refunds%ROWTYPE;
BEGIN
  IF NOT is_any_admin() THEN
    RETURN json_build_object('ok', false, 'error', 'Admin access required');
  END IF;

  SELECT * INTO v_refund FROM refunds WHERE id = p_refund_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Refund not found');
  END IF;
  IF v_refund.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error',
      'Only draft refunds can be submitted. Status: ' || v_refund.status);
  END IF;

  UPDATE refunds
     SET status = 'submitted', updated_at = now()
   WHERE id = p_refund_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, after_data)
  VALUES (auth.uid(), 'SUBMIT', 'refunds', p_refund_id,
          json_build_object('status','submitted')::jsonb);

  RETURN json_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_refund(UUID) TO authenticated;

COMMENT ON FUNCTION submit_refund(UUID) IS
'Submits a draft refund for approval. Requires is_any_admin(). E Phase E.';


-- ══ END PHASE E MIGRATION ══════════════════════════════════════════════════
-- Verification:
--   SELECT routine_name, security_type FROM information_schema.routines
--   WHERE routine_name IN (
--     'get_quotation_summary','get_accounting_health',
--     'get_balance_sheet_status','get_itinerary_summary',
--     'submit_expense','submit_refund','recalculate_itinerary_totals'
--   );
--   → all should show DEFINER
--
-- Test as non-admin authenticated user:
--   SELECT get_quotation_summary();    → {"error":"unauthorized"}
--   SELECT get_accounting_health();    → {"error":"unauthorized"}
--   SELECT get_itinerary_summary();    → {"error":"unauthorized"}
