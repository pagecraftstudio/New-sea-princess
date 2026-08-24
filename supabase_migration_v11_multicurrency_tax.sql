-- ============================================================
-- Migration v11: Multi-Currency & Tax (Section 11)
-- Safe additive. Run after v10.
-- ============================================================

-- ── 1. CURRENCIES REGISTRY ───────────────────────────────────
-- Supported currencies with display config
CREATE TABLE IF NOT EXISTS currencies (
  code         TEXT PRIMARY KEY,          -- ISO 4217: EGP, SAR, USD, EUR …
  name_ar      TEXT NOT NULL,
  name_en      TEXT NOT NULL,
  symbol       TEXT NOT NULL,
  decimal_places INT NOT NULL DEFAULT 2,
  is_base      BOOLEAN NOT NULL DEFAULT FALSE,  -- exactly one TRUE (EGP)
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ DEFAULT now()
);

-- Enforce single base currency
CREATE UNIQUE INDEX IF NOT EXISTS idx_currencies_single_base
  ON currencies (is_base) WHERE is_base = TRUE;

ALTER TABLE currencies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON currencies FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "public_read" ON currencies FOR SELECT USING (true);

-- Seed standard currencies
INSERT INTO currencies (code, name_ar, name_en, symbol, is_base) VALUES
  ('EGP', 'جنيه مصري',     'Egyptian Pound',  'ج.م', TRUE),
  ('SAR', 'ريال سعودي',    'Saudi Riyal',      'ر.س', FALSE),
  ('USD', 'دولار أمريكي',  'US Dollar',        '$',   FALSE),
  ('EUR', 'يورو',           'Euro',             '€',   FALSE)
ON CONFLICT (code) DO NOTHING;

-- ── 2. BASE-AMOUNT COLUMNS ────────────────────────────────────
-- Store EGP-equivalent at time of transaction on all transactional tables.
-- exchange_rate already exists; adding base_amount (original × rate).

ALTER TABLE nsp_invoices
  ADD COLUMN IF NOT EXISTS base_amount NUMERIC(18,2)
    GENERATED ALWAYS AS (total_amount * exchange_rate) STORED;

ALTER TABLE nsp_payments
  ADD COLUMN IF NOT EXISTS base_amount NUMERIC(18,2)
    GENERATED ALWAYS AS (amount * exchange_rate) STORED;

ALTER TABLE nsp_expenses
  ADD COLUMN IF NOT EXISTS base_amount NUMERIC(18,2)
    GENERATED ALWAYS AS (total_amount * exchange_rate) STORED;

-- ── 3. TAX_ID FK ON TRANSACTIONAL TABLES ─────────────────────
-- invoice_items: link to taxes table for per-line tax config
ALTER TABLE invoice_items
  ADD COLUMN IF NOT EXISTS tax_id UUID REFERENCES taxes(id) ON DELETE SET NULL;

-- nsp_expenses: link to taxes table
ALTER TABLE nsp_expenses
  ADD COLUMN IF NOT EXISTS tax_id UUID REFERENCES taxes(id) ON DELETE SET NULL;

-- ── 4. TAX TRANSACTIONS LEDGER ───────────────────────────────
-- Records tax collected/paid per transaction for tax reporting
CREATE TABLE IF NOT EXISTS tax_transactions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_id          UUID NOT NULL REFERENCES taxes(id),
  direction       TEXT NOT NULL CHECK (direction IN ('collected','paid')),
                  -- collected = sales tax, paid = purchase tax
  source_type     TEXT NOT NULL CHECK (source_type IN ('invoice','expense','credit_note','journal')),
  source_id       UUID NOT NULL,
  taxable_amount  NUMERIC(18,2) NOT NULL,
  tax_rate        NUMERIC(6,4)  NOT NULL,
  tax_amount      NUMERIC(18,2) NOT NULL,
  currency        TEXT NOT NULL DEFAULT 'EGP',
  exchange_rate   NUMERIC(18,6) NOT NULL DEFAULT 1,
  base_tax_amount NUMERIC(18,2) GENERATED ALWAYS AS (tax_amount * exchange_rate) STORED,
  fiscal_period_id UUID REFERENCES fiscal_periods(id),
  transaction_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_by      UUID REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tax_txn_tax_id   ON tax_transactions(tax_id);
CREATE INDEX IF NOT EXISTS idx_tax_txn_source   ON tax_transactions(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_tax_txn_date     ON tax_transactions(transaction_date);
CREATE INDEX IF NOT EXISTS idx_tax_txn_period   ON tax_transactions(fiscal_period_id);

ALTER TABLE tax_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON tax_transactions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ── 5. EXCHANGE GAIN/LOSS TRACKING ───────────────────────────
-- When a foreign-currency receivable/payable is settled at a different
-- rate than when it was recorded, the difference is realised gain/loss.
CREATE TABLE IF NOT EXISTS exchange_gain_loss (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type      TEXT NOT NULL CHECK (source_type IN ('invoice','expense','payment','journal')),
  source_id        UUID NOT NULL,
  currency         TEXT NOT NULL,
  original_rate    NUMERIC(18,6) NOT NULL,
  settlement_rate  NUMERIC(18,6) NOT NULL,
  original_amount  NUMERIC(18,2) NOT NULL,   -- in foreign currency
  gain_loss_base   NUMERIC(18,2) NOT NULL,   -- positive = gain, negative = loss (in EGP)
  journal_entry_id UUID REFERENCES journal_entries(id),
  transaction_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_exgl_source ON exchange_gain_loss(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_exgl_date   ON exchange_gain_loss(transaction_date);

ALTER TABLE exchange_gain_loss ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON exchange_gain_loss FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ── 6. ACCOUNTING MAPPINGS: FX GAIN/LOSS ACCOUNTS ────────────
-- Ensure FX gain/loss accounts are mappable without hard-coding IDs
INSERT INTO accounting_mappings (mapping_key, account_id, description)
SELECT 'fx_gain_account', id, 'Exchange Rate Gain account'
FROM accounts WHERE code = '4900' LIMIT 1  -- Other Revenue placeholder
ON CONFLICT (mapping_key) DO NOTHING;

INSERT INTO accounting_mappings (mapping_key, account_id, description)
SELECT 'fx_loss_account', id, 'Exchange Rate Loss account'
FROM accounts WHERE code = '6900' LIMIT 1  -- Other Expenses placeholder
ON CONFLICT (mapping_key) DO NOTHING;

-- ── 7. HELPER FUNCTION: get_rate ─────────────────────────────
-- Returns latest exchange rate for a currency pair on or before given date.
-- Falls back to 1 if same currency or no rate found.
CREATE OR REPLACE FUNCTION get_exchange_rate(
  p_from TEXT,
  p_to   TEXT DEFAULT 'EGP',
  p_date DATE DEFAULT CURRENT_DATE
) RETURNS NUMERIC(18,6) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_rate NUMERIC(18,6);
BEGIN
  IF p_from = p_to THEN RETURN 1; END IF;
  SELECT rate INTO v_rate
  FROM exchange_rates
  WHERE from_currency = p_from
    AND to_currency   = p_to
    AND rate_date    <= p_date
  ORDER BY rate_date DESC
  LIMIT 1;
  RETURN COALESCE(v_rate, 1);
END;
$$;

-- ── 8. TAX REPORT VIEW ───────────────────────────────────────
CREATE OR REPLACE VIEW tax_report AS
SELECT
  t.id                                           AS tax_id,
  t.name_ar,
  t.name_en,
  t.type,
  t.rate,
  tt.direction,
  DATE_TRUNC('month', tt.transaction_date)       AS month,
  SUM(tt.taxable_amount)                         AS taxable_amount,
  SUM(tt.tax_amount)                             AS tax_amount,
  SUM(tt.base_tax_amount)                        AS base_tax_amount_egp
FROM tax_transactions tt
JOIN taxes t ON t.id = tt.tax_id
GROUP BY t.id, t.name_ar, t.name_en, t.type, t.rate, tt.direction,
         DATE_TRUNC('month', tt.transaction_date);

GRANT SELECT ON tax_report TO authenticated;

-- ── 9. CURRENCY SUMMARY VIEW ──────────────────────────────────
-- AR and AP totals broken down by currency (for multi-currency dashboard)
CREATE OR REPLACE VIEW ar_by_currency AS
SELECT
  currency,
  COUNT(*)                   AS invoice_count,
  SUM(remaining_amount)      AS outstanding_native,
  SUM(remaining_amount * exchange_rate) AS outstanding_egp
FROM nsp_invoices
WHERE status IN ('issued','partial','overdue')
  AND remaining_amount > 0
GROUP BY currency;

GRANT SELECT ON ar_by_currency TO authenticated;

CREATE OR REPLACE VIEW ap_by_currency AS
SELECT
  e.currency,
  COUNT(*)                                  AS expense_count,
  SUM(e.total_amount - e.paid_amount)       AS outstanding_native,
  SUM((e.total_amount - e.paid_amount) * e.exchange_rate) AS outstanding_egp
FROM nsp_expenses e
WHERE e.status IN ('approved','partial','posted')
  AND (e.total_amount - e.paid_amount) > 0
GROUP BY e.currency;

GRANT SELECT ON ap_by_currency TO authenticated;

-- ── 10. INDEXES ───────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_invoices_currency  ON nsp_invoices(currency);
CREATE INDEX IF NOT EXISTS idx_payments_currency  ON nsp_payments(currency);
CREATE INDEX IF NOT EXISTS idx_expenses_currency  ON nsp_expenses(currency);

-- ============================================================
-- End of v11
-- ============================================================
SELECT 'Migration v11 (Multi-Currency & Tax) done' AS status;
