-- ============================================================
-- Migration v12: Financial Reports (Section 12)
-- All views derive from the accounting ledger (journal_entry_lines).
-- Safe additive. Run after v11.
-- ============================================================

-- ── HELPER: account balance from posted journal lines ─────────
-- Positive = normal-balance side, negative = contra side.
-- Used by every report below.

CREATE OR REPLACE FUNCTION account_balance(
  p_account_id     UUID,
  p_from_date      DATE DEFAULT NULL,
  p_to_date        DATE DEFAULT CURRENT_DATE,
  p_cost_center_id UUID DEFAULT NULL
) RETURNS NUMERIC(18,2) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_normal TEXT;
  v_bal    NUMERIC(18,2);
BEGIN
  SELECT normal_balance INTO v_normal FROM accounts WHERE id = p_account_id;

  SELECT
    COALESCE(SUM(
      CASE WHEN v_normal = 'debit' THEN jel.debit - jel.credit
           ELSE jel.credit - jel.debit END
    ), 0)
  INTO v_bal
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  WHERE jel.account_id = p_account_id
    AND je.status = 'posted'
    AND (p_from_date IS NULL OR je.entry_date >= p_from_date)
    AND je.entry_date <= p_to_date
    AND (p_cost_center_id IS NULL OR jel.cost_center_id = p_cost_center_id);

  RETURN v_bal;
END;
$$;

-- ── 0. DROP EXISTING VIEWS (column lists changed) ────────────
DROP VIEW IF EXISTS general_ledger       CASCADE;
DROP VIEW IF EXISTS trial_balance        CASCADE;
DROP VIEW IF EXISTS booking_profitability CASCADE;

-- ── 1. GENERAL LEDGER ─────────────────────────────────────────
-- One row per posted journal line, enriched with account info.
CREATE OR REPLACE VIEW general_ledger AS
SELECT
  je.entry_date                                    AS txn_date,
  je.entry_number,
  je.description                                   AS entry_description,
  je.reference_type,
  je.reference_id,
  a.code                                           AS account_code,
  a.name_ar                                        AS account_name_ar,
  a.name_en                                        AS account_name_en,
  a.type                                           AS account_type,
  a.normal_balance,
  jel.description                                  AS line_description,
  jel.debit,
  jel.credit,
  jel.currency,
  jel.exchange_rate,
  jel.original_amount,
  cc.name_ar                                       AS cost_center_ar,
  cc.name_en                                       AS cost_center_en,
  je.id                                            AS journal_entry_id,
  jel.id                                           AS line_id,
  je.posted_at,
  je.created_by
FROM journal_entry_lines jel
JOIN journal_entries je ON je.id = jel.journal_entry_id
JOIN accounts a         ON a.id  = jel.account_id
LEFT JOIN cost_centers cc ON cc.id = jel.cost_center_id
WHERE je.status = 'posted'
ORDER BY je.entry_date, je.entry_number, jel.line_order;

GRANT SELECT ON general_ledger TO authenticated;

-- ── 2. TRIAL BALANCE ──────────────────────────────────────────
-- Total debits and credits per account from posted entries.
-- Integrity check: SUM(debit) must equal SUM(credit).
CREATE OR REPLACE VIEW trial_balance AS
SELECT
  a.code,
  a.name_ar,
  a.name_en,
  a.type,
  a.normal_balance,
  ac.name_ar                                       AS category_ar,
  ac.name_en                                       AS category_en,
  COALESCE(SUM(jel.debit),  0)                    AS total_debit,
  COALESCE(SUM(jel.credit), 0)                    AS total_credit,
  -- Net balance in account's normal-balance direction
  CASE WHEN a.normal_balance = 'debit'
       THEN COALESCE(SUM(jel.debit),0) - COALESCE(SUM(jel.credit),0)
       ELSE COALESCE(SUM(jel.credit),0) - COALESCE(SUM(jel.debit),0)
  END                                              AS net_balance
FROM accounts a
LEFT JOIN account_categories ac ON ac.id = a.category_id
LEFT JOIN journal_entry_lines jel ON jel.account_id = a.id
  AND EXISTS (
    SELECT 1 FROM journal_entries je
    WHERE je.id = jel.journal_entry_id AND je.status = 'posted'
  )
WHERE a.is_active = TRUE
GROUP BY a.id, a.code, a.name_ar, a.name_en, a.type, a.normal_balance,
         ac.name_ar, ac.name_en
ORDER BY a.code;

GRANT SELECT ON trial_balance TO authenticated;

-- ── 3. PROFIT & LOSS ──────────────────────────────────────────
CREATE OR REPLACE VIEW profit_and_loss AS
WITH lines AS (
  SELECT
    a.type,
    a.code,
    a.name_ar,
    a.name_en,
    ac.name_ar  AS category_ar,
    ac.name_en  AS category_en,
    CASE WHEN a.normal_balance = 'credit'
         THEN COALESCE(SUM(jel.credit),0) - COALESCE(SUM(jel.debit),0)
         ELSE COALESCE(SUM(jel.debit),0)  - COALESCE(SUM(jel.credit),0)
    END         AS net_amount
  FROM accounts a
  LEFT JOIN account_categories ac ON ac.id = a.category_id
  LEFT JOIN journal_entry_lines jel ON jel.account_id = a.id
    AND EXISTS (
      SELECT 1 FROM journal_entries je
      WHERE je.id = jel.journal_entry_id AND je.status = 'posted'
    )
  WHERE a.type IN ('revenue','direct_cost','expense')
  GROUP BY a.id, a.code, a.name_ar, a.name_en, a.normal_balance,
           a.type, ac.name_ar, ac.name_en
)
SELECT
  type,
  code,
  name_ar,
  name_en,
  category_ar,
  category_en,
  net_amount,
  CASE type
    WHEN 'revenue'      THEN 1
    WHEN 'direct_cost'  THEN 2
    WHEN 'expense'      THEN 3
  END                   AS sort_order
FROM lines
ORDER BY sort_order, code;

GRANT SELECT ON profit_and_loss TO authenticated;

-- ── 4. BALANCE SHEET ─────────────────────────────────────────
CREATE OR REPLACE VIEW balance_sheet AS
SELECT
  a.type,
  a.code,
  a.name_ar,
  a.name_en,
  ac.name_ar    AS category_ar,
  ac.name_en    AS category_en,
  CASE WHEN a.normal_balance = 'debit'
       THEN COALESCE(SUM(jel.debit),0) - COALESCE(SUM(jel.credit),0)
       ELSE COALESCE(SUM(jel.credit),0) - COALESCE(SUM(jel.debit),0)
  END           AS balance,
  CASE a.type
    WHEN 'asset'     THEN 1
    WHEN 'liability' THEN 2
    WHEN 'equity'    THEN 3
  END           AS sort_order
FROM accounts a
LEFT JOIN account_categories ac ON ac.id = a.category_id
LEFT JOIN journal_entry_lines jel ON jel.account_id = a.id
  AND EXISTS (
    SELECT 1 FROM journal_entries je
    WHERE je.id = jel.journal_entry_id AND je.status = 'posted'
  )
WHERE a.type IN ('asset','liability','equity')
  AND a.is_active = TRUE
GROUP BY a.id, a.code, a.name_ar, a.name_en, a.type,
         a.normal_balance, ac.name_ar, ac.name_en
ORDER BY sort_order, a.code;

GRANT SELECT ON balance_sheet TO authenticated;

-- ── 5. CASH FLOW (indirect method, simplified) ───────────────
-- Operating: net profit ± working capital changes
-- Financing/Investing: approximated via account types
-- Full indirect method requires period comparison — this view gives
-- movement in each cash/bank account per posted entry.
CREATE OR REPLACE VIEW cash_flow AS
SELECT
  je.entry_date,
  je.entry_number,
  je.description,
  je.reference_type,
  a.code                                           AS account_code,
  a.name_ar                                        AS account_name_ar,
  a.name_en                                        AS account_name_en,
  -- inflow = debit to cash/bank (money coming in)
  jel.debit                                        AS inflow,
  jel.credit                                       AS outflow,
  jel.debit - jel.credit                          AS net,
  jel.currency,
  jel.exchange_rate,
  cc.name_ar                                       AS cost_center_ar
FROM journal_entry_lines jel
JOIN journal_entries je ON je.id = jel.journal_entry_id
JOIN accounts a         ON a.id  = jel.account_id
LEFT JOIN cost_centers cc ON cc.id = jel.cost_center_id
WHERE je.status = 'posted'
  AND a.code LIKE '11%'   -- Cash & Banks (1100 range)
ORDER BY je.entry_date, je.entry_number;

GRANT SELECT ON cash_flow TO authenticated;

-- ── 6. JOURNAL REPORT ─────────────────────────────────────────
CREATE OR REPLACE VIEW journal_report AS
SELECT
  je.id                  AS journal_id,
  je.entry_number,
  je.entry_date,
  je.description,
  je.reference_type,
  je.reference_id,
  je.status,
  je.total_debit,
  je.total_credit,
  je.currency,
  je.notes,
  fp.name                AS fiscal_period,
  cc.name_ar             AS cost_center_ar,
  u_created.email        AS created_by_email,
  u_posted.email         AS posted_by_email,
  je.posted_at,
  je.created_at,
  je.reversal_of
FROM journal_entries je
LEFT JOIN fiscal_periods fp ON fp.id = je.fiscal_period_id
LEFT JOIN cost_centers   cc ON cc.id = je.cost_center_id
LEFT JOIN auth.users u_created ON u_created.id = je.created_by
LEFT JOIN auth.users u_posted  ON u_posted.id  = je.posted_by
ORDER BY je.entry_date DESC, je.entry_number DESC;

GRANT SELECT ON journal_report TO authenticated;

-- ── 7. AR AGING (corrected from v10) ─────────────────────────
-- Drop first: column list changed from v10 version.
DROP VIEW IF EXISTS ar_aging CASCADE;
CREATE VIEW ar_aging AS
SELECT
  i.customer_id,
  COALESCE(i.customer_name, 'Unknown')             AS customer_name,
  COUNT(i.id)                                      AS invoice_count,
  SUM(i.remaining_amount)                          AS total_outstanding,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) <= 0
           THEN i.remaining_amount ELSE 0 END)     AS bucket_current,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) BETWEEN  1 AND 30
           THEN i.remaining_amount ELSE 0 END)     AS bucket_30,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) BETWEEN 31 AND 60
           THEN i.remaining_amount ELSE 0 END)     AS bucket_60,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) > 60
           THEN i.remaining_amount ELSE 0 END)     AS bucket_90plus,
  SUM(i.remaining_amount * i.exchange_rate)        AS total_outstanding_egp
FROM nsp_invoices i
WHERE i.status IN ('issued','partial','overdue')
  AND i.remaining_amount > 0
GROUP BY i.customer_id, i.customer_name;

GRANT SELECT ON ar_aging TO authenticated;

-- ── 8. AP AGING (corrected from v10) ─────────────────────────
DROP VIEW IF EXISTS ap_aging CASCADE;
CREATE VIEW ap_aging AS
SELECT
  s.id                                             AS supplier_id,
  COALESCE(s.name_en, s.name_ar, 'Unknown')       AS supplier_name,
  COUNT(e.id)                                      AS expense_count,
  SUM(e.total_amount - e.paid_amount)              AS total_outstanding,
  SUM(CASE WHEN e.due_date IS NULL
            OR (CURRENT_DATE - e.due_date) <= 0
           THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_current,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) BETWEEN  1 AND 30
           THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_30,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) BETWEEN 31 AND 60
           THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_60,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) > 60
           THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_90plus,
  SUM((e.total_amount - e.paid_amount) * e.exchange_rate)  AS total_outstanding_egp
FROM nsp_expenses e
LEFT JOIN suppliers s ON s.id = e.supplier_id
WHERE e.status IN ('approved','partial','posted')
  AND (e.total_amount - e.paid_amount) > 0
GROUP BY s.id, s.name_en, s.name_ar;

GRANT SELECT ON ap_aging TO authenticated;

-- ── 9. CUSTOMER STATEMENT ────────────────────────────────────
CREATE OR REPLACE VIEW customer_statement AS
SELECT
  i.customer_id,
  i.customer_name,
  'invoice'                                        AS txn_type,
  i.invoice_number                                 AS reference,
  i.issue_date                                     AS txn_date,
  i.due_date,
  i.total_amount                                   AS debit,
  0::NUMERIC(18,2)                                 AS credit,
  i.remaining_amount                               AS balance,
  i.currency,
  i.status
FROM nsp_invoices i
WHERE i.status != 'cancelled'

UNION ALL

SELECT
  p.customer_id,
  p.customer_name,
  'payment',
  p.payment_number,
  p.payment_date,
  NULL,
  0::NUMERIC(18,2),
  p.amount,
  0::NUMERIC(18,2),
  p.currency,
  p.status
FROM nsp_payments p
WHERE p.status != 'cancelled'

UNION ALL

SELECT
  cn.customer_id,
  cn.customer_name,
  CASE cn.type WHEN 'credit' THEN 'credit_note' ELSE 'debit_note' END,
  cn.note_number,
  cn.issue_date,
  NULL,
  CASE cn.type WHEN 'debit' THEN cn.amount ELSE 0 END,
  CASE cn.type WHEN 'credit' THEN cn.amount ELSE 0 END,
  0::NUMERIC(18,2),
  'EGP',
  cn.status
FROM credit_notes cn
WHERE cn.status != 'cancelled'

ORDER BY customer_id, txn_date;

GRANT SELECT ON customer_statement TO authenticated;

-- ── 10. SUPPLIER STATEMENT ───────────────────────────────────
CREATE OR REPLACE VIEW supplier_statement AS
SELECT
  e.supplier_id,
  COALESCE(s.name_en, s.name_ar)                  AS supplier_name,
  'expense'                                        AS txn_type,
  e.expense_number                                 AS reference,
  e.expense_date                                   AS txn_date,
  e.due_date,
  e.total_amount                                   AS credit,   -- we owe supplier
  0::NUMERIC(18,2)                                 AS debit,
  (e.total_amount - e.paid_amount)                 AS balance,
  e.currency,
  e.status
FROM nsp_expenses e
LEFT JOIN suppliers s ON s.id = e.supplier_id
WHERE e.status NOT IN ('draft','rejected')

ORDER BY supplier_id, txn_date;

GRANT SELECT ON supplier_statement TO authenticated;

-- ── 11. REVENUE REPORT ────────────────────────────────────────
CREATE OR REPLACE VIEW revenue_report AS
SELECT
  je.entry_date,
  DATE_TRUNC('month', je.entry_date)               AS month,
  a.code                                           AS account_code,
  a.name_ar,
  a.name_en,
  COALESCE(SUM(jel.credit - jel.debit), 0)        AS amount,
  cc.name_ar                                       AS cost_center_ar
FROM journal_entry_lines jel
JOIN journal_entries je ON je.id = jel.journal_entry_id
JOIN accounts a         ON a.id  = jel.account_id
LEFT JOIN cost_centers cc ON cc.id = jel.cost_center_id
WHERE je.status = 'posted'
  AND a.type = 'revenue'
GROUP BY je.entry_date, DATE_TRUNC('month', je.entry_date),
         a.code, a.name_ar, a.name_en, cc.name_ar
ORDER BY je.entry_date, a.code;

GRANT SELECT ON revenue_report TO authenticated;

-- ── 12. EXPENSE REPORT ────────────────────────────────────────
CREATE OR REPLACE VIEW expense_report AS
SELECT
  e.expense_date,
  DATE_TRUNC('month', e.expense_date)              AS month,
  ec.name_ar                                       AS category_ar,
  ec.name_en                                       AS category_en,
  a.code                                           AS account_code,
  a.name_ar                                        AS account_name_ar,
  COALESCE(s.name_en, s.name_ar)                  AS supplier_name,
  cc.name_ar                                       AS cost_center_ar,
  e.amount,
  e.tax_amount,
  e.total_amount,
  e.currency,
  e.exchange_rate,
  e.total_amount * e.exchange_rate                 AS base_amount_egp,
  e.status,
  e.expense_number
FROM nsp_expenses e
LEFT JOIN expense_categories ec ON ec.id = e.category_id
LEFT JOIN accounts a             ON a.id  = e.account_id
LEFT JOIN suppliers s            ON s.id  = e.supplier_id
LEFT JOIN cost_centers cc        ON cc.id = e.cost_center_id
WHERE e.status NOT IN ('draft','rejected')
ORDER BY e.expense_date DESC;

GRANT SELECT ON expense_report TO authenticated;

-- ── 13. PAYMENT COLLECTION REPORT ────────────────────────────
CREATE OR REPLACE VIEW payment_collection_report AS
SELECT
  p.payment_date,
  DATE_TRUNC('month', p.payment_date)              AS month,
  p.payment_number,
  p.customer_name,
  p.amount,
  p.currency,
  p.exchange_rate,
  p.amount * p.exchange_rate                       AS base_amount_egp,
  p.payment_method,
  ca.name_ar                                       AS cash_account_ar,
  ca.name_en                                       AS cash_account_en,
  ca.type                                          AS account_type,
  p.reference,
  p.status,
  p.created_by
FROM nsp_payments p
LEFT JOIN cash_accounts ca ON ca.id = p.cash_account_id
WHERE p.status != 'cancelled'
ORDER BY p.payment_date DESC;

GRANT SELECT ON payment_collection_report TO authenticated;

-- ── 14. CASH / BANK REPORT ────────────────────────────────────
CREATE OR REPLACE VIEW cash_bank_report AS
SELECT
  ca.id                                            AS account_id,
  ca.name_ar,
  ca.name_en,
  ca.type,
  ca.currency,
  ca.current_balance,
  -- Total inflows (payments received into this account)
  COALESCE((
    SELECT SUM(amount) FROM nsp_payments
    WHERE cash_account_id = ca.id AND status = 'received'
  ), 0)                                            AS total_inflows,
  -- Total outflows (expenses paid from this account)
  COALESCE((
    SELECT SUM(total_amount) FROM nsp_expenses
    WHERE payment_account_id = ca.id AND status = 'posted'
  ), 0)                                            AS total_outflows
FROM cash_accounts ca
WHERE ca.is_active = TRUE
ORDER BY ca.type, ca.name_ar;

GRANT SELECT ON cash_bank_report TO authenticated;

-- ── 15. PACKAGE PROFITABILITY ─────────────────────────────────
CREATE OR REPLACE VIEW package_profitability AS
SELECT
  p.id                                             AS package_id,
  p.title,
  p.category,
  COUNT(DISTINCT b.id)                             AS booking_count,
  COALESCE(SUM(b.total_price), 0)                  AS total_revenue,
  -- Direct costs from booking_costs table
  COALESCE(SUM(bc_agg.total_cost), 0)              AS total_direct_cost,
  COALESCE(SUM(b.total_price), 0)
    - COALESCE(SUM(bc_agg.total_cost), 0)          AS gross_profit,
  CASE WHEN COALESCE(SUM(b.total_price), 0) = 0 THEN 0
       ELSE ROUND(
         (COALESCE(SUM(b.total_price), 0)
          - COALESCE(SUM(bc_agg.total_cost), 0))
         / COALESCE(SUM(b.total_price), 0) * 100, 2)
  END                                              AS gross_margin_pct
FROM packages p
LEFT JOIN bookings b ON b.package_id = p.id
  AND b.status NOT IN ('cancelled')
LEFT JOIN LATERAL (
  SELECT booking_id, SUM(base_amount) AS total_cost
  FROM booking_costs
  WHERE booking_id = b.id
  GROUP BY booking_id
) bc_agg ON TRUE
GROUP BY p.id, p.title, p.category
ORDER BY gross_profit DESC;

GRANT SELECT ON package_profitability TO authenticated;

-- ── 16. BOOKING PROFITABILITY ─────────────────────────────────
CREATE OR REPLACE VIEW booking_profitability AS
SELECT
  b.id                                             AS booking_id,
  b.booking_number,
  b.customer_name,
  b.package_title,
  b.status,
  b.total_price                                    AS selling_price,
  b.paid_amount,
  b.remaining_amount,
  COALESCE(SUM(CASE bc.type WHEN 'hotel'     THEN bc.base_amount ELSE 0 END), 0) AS hotel_cost,
  COALESCE(SUM(CASE bc.type WHEN 'flight'    THEN bc.base_amount ELSE 0 END), 0) AS flight_cost,
  COALESCE(SUM(CASE bc.type WHEN 'visa'      THEN bc.base_amount ELSE 0 END), 0) AS visa_cost,
  COALESCE(SUM(CASE bc.type WHEN 'transport' THEN bc.base_amount ELSE 0 END), 0) AS transport_cost,
  COALESCE(SUM(CASE bc.type WHEN 'other'     THEN bc.base_amount ELSE 0 END), 0) AS other_cost,
  COALESCE(SUM(bc.base_amount), 0)                 AS total_direct_cost,
  b.total_price - COALESCE(SUM(bc.base_amount), 0) AS gross_profit,
  CASE WHEN b.total_price = 0 THEN 0
       ELSE ROUND(
         (b.total_price - COALESCE(SUM(bc.base_amount), 0))
         / b.total_price * 100, 2)
  END                                              AS gross_margin_pct
FROM bookings b
LEFT JOIN booking_costs bc ON bc.booking_id = b.id
WHERE b.status != 'cancelled'
GROUP BY b.id, b.booking_number, b.customer_name, b.package_title,
         b.status, b.total_price, b.paid_amount, b.remaining_amount
ORDER BY gross_profit DESC;

GRANT SELECT ON booking_profitability TO authenticated;

-- ── 17. COST CENTER PROFITABILITY ─────────────────────────────
CREATE OR REPLACE VIEW cost_center_profitability AS
SELECT
  cc.id                                            AS cost_center_id,
  cc.name_ar,
  cc.name_en,
  cc.code,
  COALESCE(SUM(CASE WHEN a.type = 'revenue'
               THEN jel.credit - jel.debit ELSE 0 END), 0) AS revenue,
  COALESCE(SUM(CASE WHEN a.type = 'direct_cost'
               THEN jel.debit - jel.credit ELSE 0 END), 0) AS direct_cost,
  COALESCE(SUM(CASE WHEN a.type = 'expense'
               THEN jel.debit - jel.credit ELSE 0 END), 0) AS operating_expense,
  COALESCE(SUM(CASE WHEN a.type = 'revenue'
               THEN jel.credit - jel.debit ELSE 0 END), 0)
  - COALESCE(SUM(CASE WHEN a.type IN ('direct_cost','expense')
               THEN jel.debit - jel.credit ELSE 0 END), 0) AS net_profit
FROM cost_centers cc
LEFT JOIN journal_entry_lines jel ON jel.cost_center_id = cc.id
LEFT JOIN journal_entries je      ON je.id = jel.journal_entry_id
  AND je.status = 'posted'
LEFT JOIN accounts a              ON a.id = jel.account_id
GROUP BY cc.id, cc.name_ar, cc.name_en, cc.code
ORDER BY net_profit DESC;

GRANT SELECT ON cost_center_profitability TO authenticated;

-- ── 18. INTEGRITY CHECK FUNCTION ─────────────────────────────
-- Assets = Liabilities + Equity. Returns diff; 0 = balanced.
CREATE OR REPLACE FUNCTION check_balance_sheet_integrity()
RETURNS TABLE(
  total_assets     NUMERIC(18,2),
  total_liabilities NUMERIC(18,2),
  total_equity     NUMERIC(18,2),
  difference       NUMERIC(18,2),
  is_balanced      BOOLEAN
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_assets      NUMERIC(18,2);
  v_liabilities NUMERIC(18,2);
  v_equity      NUMERIC(18,2);
BEGIN
  SELECT COALESCE(SUM(
    CASE WHEN a.normal_balance = 'debit'
         THEN jel.debit - jel.credit
         ELSE jel.credit - jel.debit END
  ), 0)
  INTO v_assets
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
  JOIN accounts a         ON a.id  = jel.account_id AND a.type = 'asset';

  SELECT COALESCE(SUM(
    CASE WHEN a.normal_balance = 'credit'
         THEN jel.credit - jel.debit
         ELSE jel.debit - jel.credit END
  ), 0)
  INTO v_liabilities
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
  JOIN accounts a         ON a.id  = jel.account_id AND a.type = 'liability';

  SELECT COALESCE(SUM(
    CASE WHEN a.normal_balance = 'credit'
         THEN jel.credit - jel.debit
         ELSE jel.debit - jel.credit END
  ), 0)
  INTO v_equity
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
  JOIN accounts a         ON a.id  = jel.account_id AND a.type = 'equity';

  RETURN QUERY SELECT
    v_assets,
    v_liabilities,
    v_equity,
    v_assets - (v_liabilities + v_equity),
    ABS(v_assets - (v_liabilities + v_equity)) < 0.01;
END;
$$;

-- ── 19. INDEXES FOR REPORT PERFORMANCE ───────────────────────
CREATE INDEX IF NOT EXISTS idx_jel_account_date ON journal_entry_lines(account_id)
  INCLUDE (debit, credit);
CREATE INDEX IF NOT EXISTS idx_je_status_date   ON journal_entries(status, entry_date);
CREATE INDEX IF NOT EXISTS idx_je_ref           ON journal_entries(reference_type, reference_id);
CREATE INDEX IF NOT EXISTS idx_bc_booking       ON booking_costs(booking_id);
CREATE INDEX IF NOT EXISTS idx_invoices_cust    ON nsp_invoices(customer_id, status);
CREATE INDEX IF NOT EXISTS idx_expenses_supp    ON nsp_expenses(supplier_id, status);

-- ============================================================
-- End of v12
-- ============================================================
SELECT 'Migration v12 (Reports) done' AS status;
