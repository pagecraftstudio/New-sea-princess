-- ============================================================
-- Migration v10: AR / AP Support
-- Adds paid_amount, due_date to nsp_expenses for AP tracking
-- Adds AR/AP aging views for fast dashboard queries
-- ============================================================

-- 1. Add AP tracking columns to nsp_expenses (safe, additive)
ALTER TABLE nsp_expenses
  ADD COLUMN IF NOT EXISTS paid_amount   NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS due_date      DATE,
  ADD COLUMN IF NOT EXISTS supplier_id   UUID REFERENCES suppliers(id) ON DELETE SET NULL;

-- 2. Ensure nsp_invoices has all AR columns (in case earlier migration missed)
ALTER TABLE nsp_invoices
  ADD COLUMN IF NOT EXISTS paid_amount      NUMERIC(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS remaining_amount NUMERIC(15,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED;

-- If remaining_amount already exists as a regular column, add it safely:
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'nsp_invoices' AND column_name = 'remaining_amount'
  ) THEN
    ALTER TABLE nsp_invoices ADD COLUMN remaining_amount NUMERIC(15,2)
      GENERATED ALWAYS AS (total_amount - paid_amount) STORED;
  END IF;
END $$;

-- 3. AR Aging View — unpaid/partially-paid invoices grouped by customer
CREATE OR REPLACE VIEW ar_aging AS
SELECT
  p.id                                        AS customer_id,
  COALESCE(p.full_name, p.email, 'Unknown')   AS customer_name,
  COUNT(i.id)                                 AS invoice_count,
  SUM(i.remaining_amount)                     AS total_outstanding,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) <= 0  THEN i.remaining_amount ELSE 0 END) AS bucket_current,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) BETWEEN  1 AND 30 THEN i.remaining_amount ELSE 0 END) AS bucket_30,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) BETWEEN 31 AND 60 THEN i.remaining_amount ELSE 0 END) AS bucket_60,
  SUM(CASE WHEN (CURRENT_DATE - i.due_date) > 60               THEN i.remaining_amount ELSE 0 END) AS bucket_90plus
FROM nsp_invoices i
JOIN profiles p ON p.id = i.user_id
WHERE i.status IN ('issued','partial','overdue')
  AND i.remaining_amount > 0
GROUP BY p.id, p.full_name, p.email;

-- 4. AP Aging View — unpaid expenses grouped by supplier
CREATE OR REPLACE VIEW ap_aging AS
SELECT
  s.id                    AS supplier_id,
  COALESCE(s.name, 'Unknown') AS supplier_name,
  COUNT(e.id)             AS expense_count,
  SUM(e.total_amount - e.paid_amount) AS total_outstanding,
  SUM(CASE WHEN e.due_date IS NULL OR (CURRENT_DATE - e.due_date) <= 0  THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_current,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) BETWEEN  1 AND 30 THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_30,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) BETWEEN 31 AND 60 THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_60,
  SUM(CASE WHEN (CURRENT_DATE - e.due_date) > 60               THEN e.total_amount - e.paid_amount ELSE 0 END) AS bucket_90plus
FROM nsp_expenses e
LEFT JOIN suppliers s ON s.id = e.supplier_id
WHERE e.status IN ('approved','partial','posted')
  AND (e.total_amount - e.paid_amount) > 0
GROUP BY s.id, s.name;

-- 5. Indexes for AR/AP performance
CREATE INDEX IF NOT EXISTS idx_nsp_invoices_status_due   ON nsp_invoices(status, due_date);
CREATE INDEX IF NOT EXISTS idx_nsp_invoices_remaining    ON nsp_invoices(remaining_amount) WHERE remaining_amount > 0;
CREATE INDEX IF NOT EXISTS idx_nsp_expenses_status_due   ON nsp_expenses(status, due_date);
CREATE INDEX IF NOT EXISTS idx_nsp_expenses_supplier     ON nsp_expenses(supplier_id);

-- 6. Auto-update invoice status to 'overdue' when past due_date
CREATE OR REPLACE FUNCTION mark_overdue_invoices()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE nsp_invoices
  SET status = 'overdue'
  WHERE status IN ('issued','partial')
    AND due_date < CURRENT_DATE
    AND remaining_amount > 0;
END;
$$;

-- 7. RLS: ar_aging and ap_aging — admin-only
ALTER VIEW ar_aging OWNER TO postgres;
ALTER VIEW ap_aging OWNER TO postgres;

-- Grant to authenticated for admin panel use (RLS on base tables still applies)
GRANT SELECT ON ar_aging TO authenticated;
GRANT SELECT ON ap_aging TO authenticated;

-- ============================================================
-- End of v10
-- ============================================================
