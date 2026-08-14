-- ══════════════════════════════════════════════════════════════
--  NSP Migration v16 — Accounting Health Check
--  Implements Section 16 of the ERP spec.
--  Single RPC: get_accounting_health()
--  Returns per-check status: healthy / warning / critical
--  Plus overall system status.
--  Safe additive — run after v15.
-- ══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_accounting_health()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  -- counters
  v_unbalanced_journals     INT := 0;
  v_missing_mappings        INT := 0;
  v_orphan_invoice_items    INT := 0;
  v_orphan_pay_alloc        INT := 0;
  v_closed_period_violations INT := 0;
  v_taxes_no_account        INT := 0;
  v_expenses_no_cost_center INT := 0;
  v_unreconciled_banks      INT := 0;
  v_failed_auto_accounting  INT := 0;
  v_unposted_old_expenses   INT := 0;
  v_invoices_no_journal     INT := 0;

  -- required mapping keys (from v6 seed)
  v_required_mappings TEXT[] := ARRAY[
    'ar_account','cash_account','revenue_default','ap_account',
    'bank_fees','expense_general','customer_advances'
  ];

  v_checks JSON;
  v_overall TEXT;
  v_critical_count INT := 0;
  v_warning_count  INT := 0;
BEGIN
  -- ── 1. UNBALANCED POSTED JOURNALS ──────────────────────────
  SELECT COUNT(*) INTO v_unbalanced_journals
  FROM journal_entries je
  WHERE je.status = 'posted'
    AND ABS(
      (SELECT COALESCE(SUM(debit),0)  FROM journal_entry_lines WHERE journal_entry_id = je.id) -
      (SELECT COALESCE(SUM(credit),0) FROM journal_entry_lines WHERE journal_entry_id = je.id)
    ) > 0.01;

  -- ── 2. MISSING REQUIRED ACCOUNT MAPPINGS ───────────────────
  SELECT COUNT(*) INTO v_missing_mappings
  FROM unnest(v_required_mappings) AS mk(key)
  WHERE NOT EXISTS (
    SELECT 1 FROM accounting_mappings am
    JOIN accounts a ON a.id = am.account_id AND a.is_active = TRUE
    WHERE am.mapping_key = mk.key
  );

  -- ── 3. ORPHAN INVOICE ITEMS (no valid parent invoice) ──────
  SELECT COUNT(*) INTO v_orphan_invoice_items
  FROM invoice_items ii
  WHERE NOT EXISTS (
    SELECT 1 FROM nsp_invoices i WHERE i.id = ii.invoice_id
  );

  -- ── 4. ORPHAN PAYMENT ALLOCATIONS ──────────────────────────
  SELECT COUNT(*) INTO v_orphan_pay_alloc
  FROM payment_allocations pa
  WHERE NOT EXISTS (SELECT 1 FROM nsp_payments p WHERE p.id = pa.payment_id)
     OR NOT EXISTS (SELECT 1 FROM nsp_invoices i WHERE i.id = pa.invoice_id);

  -- ── 5. CLOSED-PERIOD VIOLATIONS ────────────────────────────
  -- Journal entries posted into a closed fiscal period
  SELECT COUNT(*) INTO v_closed_period_violations
  FROM journal_entries je
  JOIN fiscal_periods fp ON fp.id = je.fiscal_period_id
  WHERE je.status = 'posted'
    AND fp.status = 'closed'
    AND je.reversal_of IS NULL  -- reversals are intentional
    AND je.created_at > fp.closed_at;  -- posted AFTER period was closed

  -- ── 6. TAXES WITH NO ACCOUNT MAPPING ───────────────────────
  SELECT COUNT(*) INTO v_taxes_no_account
  FROM taxes
  WHERE is_active = TRUE
    AND tax_account_id IS NULL;

  -- ── 7. APPROVED EXPENSES MISSING COST CENTER ───────────────
  -- Warning only — cost center not always mandatory but recommended
  SELECT COUNT(*) INTO v_expenses_no_cost_center
  FROM nsp_expenses
  WHERE status IN ('approved','posted')
    AND cost_center_id IS NULL
    AND created_at > now() - INTERVAL '90 days';  -- recent only

  -- ── 8. UNRECONCILED BANK ACCOUNTS (stale > 30 days) ────────
  SELECT COUNT(*) INTO v_unreconciled_banks
  FROM cash_accounts ca
  WHERE ca.account_type IN ('bank','wallet')
    AND ca.is_active = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM bank_reconciliations br
      WHERE br.cash_account_id = ca.id
        AND br.status = 'reconciled'
        AND br.period_end >= CURRENT_DATE - 30
    );

  -- ── 9. FAILED ACCOUNTING AUTOMATION ───────────────────────
  -- Invoices/payments that should have a journal entry but don't
  SELECT COUNT(*) INTO v_failed_auto_accounting
  FROM nsp_invoices i
  WHERE i.status IN ('issued','partial','paid')
    AND i.journal_entry_id IS NULL
    AND i.created_at < now() - INTERVAL '1 hour';  -- grace period for in-flight

  -- ── 10. OLD UNPOSTED EXPENSES (> 7 days in approved state) ─
  SELECT COUNT(*) INTO v_unposted_old_expenses
  FROM nsp_expenses
  WHERE status = 'approved'
    AND approved_at < now() - INTERVAL '7 days';

  -- ── BUILD CHECK ARRAY ───────────────────────────────────────
  v_checks := json_build_array(

    json_build_object(
      'id',          'unbalanced_journals',
      'name_ar',     'قيود غير متوازنة',
      'name_en',     'Unbalanced Journal Entries',
      'description', 'Posted journal entries where total debit ≠ total credit',
      'count',       v_unbalanced_journals,
      'status',      CASE WHEN v_unbalanced_journals = 0 THEN 'healthy'
                          WHEN v_unbalanced_journals <= 3 THEN 'warning'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'missing_mappings',
      'name_ar',     'ربط حسابات مفقود',
      'name_en',     'Missing Account Mappings',
      'description', 'Required accounting mappings not configured',
      'count',       v_missing_mappings,
      'status',      CASE WHEN v_missing_mappings = 0 THEN 'healthy'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'orphan_invoice_items',
      'name_ar',     'بنود فواتير يتيمة',
      'name_en',     'Orphan Invoice Items',
      'description', 'Invoice line items with no parent invoice',
      'count',       v_orphan_invoice_items,
      'status',      CASE WHEN v_orphan_invoice_items = 0 THEN 'healthy'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'orphan_allocations',
      'name_ar',     'توزيعات مدفوعات يتيمة',
      'name_en',     'Orphan Payment Allocations',
      'description', 'Payment allocations referencing missing payments or invoices',
      'count',       v_orphan_pay_alloc,
      'status',      CASE WHEN v_orphan_pay_alloc = 0 THEN 'healthy'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'closed_period_violations',
      'name_ar',     'انتهاكات فترات مغلقة',
      'name_en',     'Closed Period Violations',
      'description', 'Entries posted into already-closed fiscal periods',
      'count',       v_closed_period_violations,
      'status',      CASE WHEN v_closed_period_violations = 0 THEN 'healthy'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'taxes_no_account',
      'name_ar',     'ضرائب بدون حساب',
      'name_en',     'Taxes Missing Account',
      'description', 'Active tax types with no linked GL account',
      'count',       v_taxes_no_account,
      'status',      CASE WHEN v_taxes_no_account = 0 THEN 'healthy'
                          WHEN v_taxes_no_account <= 2 THEN 'warning'
                          ELSE 'critical' END,
      'severity',    'warning'
    ),

    json_build_object(
      'id',          'expenses_no_cost_center',
      'name_ar',     'مصاريف بدون مركز تكلفة',
      'name_en',     'Expenses Missing Cost Center',
      'description', 'Recent approved/posted expenses with no cost center assigned (last 90 days)',
      'count',       v_expenses_no_cost_center,
      'status',      CASE WHEN v_expenses_no_cost_center = 0 THEN 'healthy'
                          WHEN v_expenses_no_cost_center <= 10 THEN 'warning'
                          ELSE 'warning' END,
      'severity',    'warning'
    ),

    json_build_object(
      'id',          'unreconciled_banks',
      'name_ar',     'حسابات بنكية غير مطابقة',
      'name_en',     'Unreconciled Bank Accounts',
      'description', 'Bank/wallet accounts with no reconciliation in the last 30 days',
      'count',       v_unreconciled_banks,
      'status',      CASE WHEN v_unreconciled_banks = 0 THEN 'healthy'
                          WHEN v_unreconciled_banks <= 2 THEN 'warning'
                          ELSE 'critical' END,
      'severity',    'warning'
    ),

    json_build_object(
      'id',          'failed_auto_accounting',
      'name_ar',     'فشل الترحيل التلقائي',
      'name_en',     'Failed Accounting Automation',
      'description', 'Issued/paid invoices with no journal entry generated',
      'count',       v_failed_auto_accounting,
      'status',      CASE WHEN v_failed_auto_accounting = 0 THEN 'healthy'
                          WHEN v_failed_auto_accounting <= 5 THEN 'warning'
                          ELSE 'critical' END,
      'severity',    'critical'
    ),

    json_build_object(
      'id',          'stale_approved_expenses',
      'name_ar',     'مصاريف معتمدة غير مرحّلة',
      'name_en',     'Stale Approved Expenses',
      'description', 'Expenses approved > 7 days ago but not yet posted',
      'count',       v_unposted_old_expenses,
      'status',      CASE WHEN v_unposted_old_expenses = 0 THEN 'healthy'
                          WHEN v_unposted_old_expenses <= 5 THEN 'warning'
                          ELSE 'warning' END,
      'severity',    'warning'
    )

  );

  -- ── OVERALL STATUS ──────────────────────────────────────────
  SELECT
    COUNT(*) FILTER (WHERE (j->>'status') = 'critical'),
    COUNT(*) FILTER (WHERE (j->>'status') = 'warning')
  INTO v_critical_count, v_warning_count
  FROM json_array_elements(v_checks) j;

  v_overall := CASE
    WHEN v_critical_count > 0 THEN 'critical'
    WHEN v_warning_count  > 0 THEN 'warning'
    ELSE 'healthy'
  END;

  RETURN json_build_object(
    'ok',             true,
    'overall',        v_overall,
    'critical_count', v_critical_count,
    'warning_count',  v_warning_count,
    'healthy_count',  json_array_length(v_checks) - v_critical_count - v_warning_count,
    'total_checks',   json_array_length(v_checks),
    'checks',         v_checks,
    'generated_at',   now()
  );

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object(
    'ok',     false,
    'error',  SQLERRM,
    'overall','critical'
  );
END;
$$;

-- RLS: any financial reader can run the health check
REVOKE ALL ON FUNCTION get_accounting_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_accounting_health() TO authenticated;

-- ── BALANCE SHEET INTEGRITY (already in v12, expose cleanly) ─
-- Alias for UI — wraps check_balance_sheet_integrity() into JSON
CREATE OR REPLACE FUNCTION get_balance_sheet_status()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  r RECORD;
BEGIN
  SELECT * INTO r FROM check_balance_sheet_integrity();
  RETURN json_build_object(
    'ok',               true,
    'total_assets',     r.total_assets,
    'total_liabilities',r.total_liabilities,
    'total_equity',     r.total_equity,
    'difference',       r.difference,
    'is_balanced',      r.is_balanced,
    'status',           CASE WHEN r.is_balanced THEN 'healthy' ELSE 'critical' END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object('ok', false, 'error', SQLERRM, 'status', 'critical');
END;
$$;

REVOKE ALL ON FUNCTION get_balance_sheet_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_balance_sheet_status() TO authenticated;

-- ══ END v16 ═══════════════════════════════════════════════════
