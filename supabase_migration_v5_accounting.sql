-- ══════════════════════════════════════════════════════════════
--  NSP Migration v5 — Double-Entry Accounting Engine
--  Run in Supabase SQL Editor
-- ══════════════════════════════════════════════════════════════

-- ─── 1. FISCAL PERIODS ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS fiscal_periods (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  start_date  DATE NOT NULL,
  end_date    DATE NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closing','closed')),
  closed_by   UUID REFERENCES auth.users(id),
  closed_at   TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE fiscal_periods ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON fiscal_periods FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 2. COST CENTERS ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cost_centers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT NOT NULL UNIQUE,
  name_ar     TEXT NOT NULL,
  name_en     TEXT,
  parent_id   UUID REFERENCES cost_centers(id),
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE cost_centers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON cost_centers FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 3. ACCOUNT CATEGORIES ───────────────────────────────────
CREATE TABLE IF NOT EXISTS account_categories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code          TEXT NOT NULL UNIQUE,
  name_ar       TEXT NOT NULL,
  name_en       TEXT,
  type          TEXT NOT NULL CHECK (type IN ('asset','liability','equity','revenue','expense','direct_cost')),
  normal_balance TEXT NOT NULL CHECK (normal_balance IN ('debit','credit')),
  display_order INT DEFAULT 0
);
ALTER TABLE account_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON account_categories FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 4. CHART OF ACCOUNTS ────────────────────────────────────
CREATE TABLE IF NOT EXISTS accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT NOT NULL UNIQUE,
  name_ar         TEXT NOT NULL,
  name_en         TEXT,
  category_id     UUID REFERENCES account_categories(id),
  parent_id       UUID REFERENCES accounts(id),
  type            TEXT NOT NULL CHECK (type IN ('asset','liability','equity','revenue','expense','direct_cost')),
  normal_balance  TEXT NOT NULL CHECK (normal_balance IN ('debit','credit')),
  currency        TEXT DEFAULT 'EGP',
  is_active       BOOLEAN DEFAULT TRUE,
  is_system       BOOLEAN DEFAULT FALSE,  -- protected, cannot delete
  description     TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_accounts_code ON accounts(code);
CREATE INDEX IF NOT EXISTS idx_accounts_type ON accounts(type);
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON accounts FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 5. ACCOUNTING MAPPINGS (configurable) ───────────────────
CREATE TABLE IF NOT EXISTS accounting_mappings (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mapping_key TEXT NOT NULL UNIQUE,
  account_id  UUID NOT NULL REFERENCES accounts(id),
  description TEXT,
  updated_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE accounting_mappings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON accounting_mappings FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 6. EXCHANGE RATES ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS exchange_rates (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency TEXT NOT NULL,
  to_currency   TEXT NOT NULL DEFAULT 'EGP',
  rate          NUMERIC(18,6) NOT NULL,
  rate_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  created_by    UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE (from_currency, to_currency, rate_date)
);
ALTER TABLE exchange_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON exchange_rates FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "public_read" ON exchange_rates FOR SELECT USING (true);

-- ─── 7. TAXES ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS taxes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar        TEXT NOT NULL,
  name_en        TEXT,
  type           TEXT DEFAULT 'vat' CHECK (type IN ('vat','withholding','stamp','other')),
  rate           NUMERIC(6,4) NOT NULL DEFAULT 0.14,
  applies_to     TEXT DEFAULT 'both' CHECK (applies_to IN ('sales','purchase','both')),
  is_inclusive   BOOLEAN DEFAULT FALSE,
  tax_account_id UUID REFERENCES accounts(id),
  is_active      BOOLEAN DEFAULT TRUE,
  created_at     TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE taxes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON taxes FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 8. SUPPLIERS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS suppliers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT UNIQUE,
  name_ar         TEXT NOT NULL,
  name_en         TEXT,
  type            TEXT DEFAULT 'hotel' CHECK (type IN ('hotel','airline','visa','transport','other')),
  phone           TEXT,
  email           TEXT,
  address         TEXT,
  tax_id          TEXT,
  currency        TEXT DEFAULT 'EGP',
  payment_terms   INT DEFAULT 30,  -- days
  ap_account_id   UUID REFERENCES accounts(id),
  cost_center_id  UUID REFERENCES cost_centers(id),
  notes           TEXT,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON suppliers FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 9. JOURNAL ENTRIES ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_entries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_number    TEXT NOT NULL UNIQUE,
  entry_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  fiscal_period_id UUID REFERENCES fiscal_periods(id),
  description     TEXT NOT NULL,
  reference_type  TEXT,  -- 'booking','payment','expense','manual','reversal'
  reference_id    UUID,
  status          TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','reversed')),
  total_debit     NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_credit    NUMERIC(18,2) NOT NULL DEFAULT 0,
  currency        TEXT DEFAULT 'EGP',
  exchange_rate   NUMERIC(18,6) DEFAULT 1,
  cost_center_id  UUID REFERENCES cost_centers(id),
  created_by      UUID REFERENCES auth.users(id),
  posted_by       UUID REFERENCES auth.users(id),
  posted_at       TIMESTAMPTZ,
  reversed_by     UUID,
  reversed_at     TIMESTAMPTZ,
  reversal_of     UUID REFERENCES journal_entries(id),
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_je_date ON journal_entries(entry_date);
CREATE INDEX IF NOT EXISTS idx_je_status ON journal_entries(status);
CREATE INDEX IF NOT EXISTS idx_je_ref ON journal_entries(reference_type, reference_id);
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON journal_entries FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 10. JOURNAL ENTRY LINES ─────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_entry_lines (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  account_id       UUID NOT NULL REFERENCES accounts(id),
  debit            NUMERIC(18,2) NOT NULL DEFAULT 0,
  credit           NUMERIC(18,2) NOT NULL DEFAULT 0,
  description      TEXT,
  cost_center_id   UUID REFERENCES cost_centers(id),
  currency         TEXT DEFAULT 'EGP',
  original_amount  NUMERIC(18,2),
  exchange_rate    NUMERIC(18,6) DEFAULT 1,
  line_order       INT DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT chk_debit_credit CHECK (
    (debit >= 0 AND credit = 0) OR (credit >= 0 AND debit = 0)
  )
);
CREATE INDEX IF NOT EXISTS idx_jel_entry ON journal_entry_lines(journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_jel_account ON journal_entry_lines(account_id);
ALTER TABLE journal_entry_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON journal_entry_lines FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 11. INVOICES (upgrade-safe additions) ───────────────────
CREATE TABLE IF NOT EXISTS nsp_invoices (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number  TEXT NOT NULL UNIQUE,
  booking_id      UUID REFERENCES bookings(id),
  customer_id     UUID REFERENCES auth.users(id),
  customer_name   TEXT NOT NULL,
  customer_phone  TEXT,
  issue_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  due_date        DATE,
  currency        TEXT DEFAULT 'EGP',
  exchange_rate   NUMERIC(18,6) DEFAULT 1,
  subtotal        NUMERIC(18,2) NOT NULL DEFAULT 0,
  discount_amount NUMERIC(18,2) DEFAULT 0,
  tax_amount      NUMERIC(18,2) DEFAULT 0,
  total_amount    NUMERIC(18,2) NOT NULL DEFAULT 0,
  paid_amount     NUMERIC(18,2) DEFAULT 0,
  remaining_amount NUMERIC(18,2) DEFAULT 0,
  status          TEXT DEFAULT 'draft' CHECK (status IN ('draft','issued','partial','paid','overdue','cancelled','refunded')),
  cost_center_id  UUID REFERENCES cost_centers(id),
  notes           TEXT,
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_by      UUID REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_invoices_booking ON nsp_invoices(booking_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON nsp_invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_due ON nsp_invoices(due_date);
ALTER TABLE nsp_invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON nsp_invoices FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "customer_own" ON nsp_invoices FOR SELECT
  USING (customer_id = auth.uid());

-- ─── 12. INVOICE ITEMS ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS invoice_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id   UUID NOT NULL REFERENCES nsp_invoices(id) ON DELETE CASCADE,
  description  TEXT NOT NULL,
  type         TEXT DEFAULT 'package' CHECK (type IN ('package','hotel','flight','visa','transport','other')),
  quantity     INT NOT NULL DEFAULT 1,
  unit_price   NUMERIC(18,2) NOT NULL,
  discount     NUMERIC(18,2) DEFAULT 0,
  tax_rate     NUMERIC(6,4) DEFAULT 0,
  total        NUMERIC(18,2) NOT NULL,
  account_id   UUID REFERENCES accounts(id),
  created_at   TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE invoice_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON invoice_items FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 13. CASH / BANK ACCOUNTS ────────────────────────────────
CREATE TABLE IF NOT EXISTS cash_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT NOT NULL UNIQUE,
  name_ar         TEXT NOT NULL,
  name_en         TEXT,
  type            TEXT NOT NULL CHECK (type IN ('cash','bank','wallet')),
  currency        TEXT DEFAULT 'EGP',
  bank_name       TEXT,
  account_number  TEXT,
  opening_balance NUMERIC(18,2) DEFAULT 0,
  current_balance NUMERIC(18,2) DEFAULT 0,
  gl_account_id   UUID REFERENCES accounts(id),
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE cash_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON cash_accounts FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 14. PAYMENTS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nsp_payments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_number   TEXT NOT NULL UNIQUE,
  payment_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  customer_id      UUID REFERENCES auth.users(id),
  customer_name    TEXT NOT NULL,
  booking_id       UUID REFERENCES bookings(id),
  amount           NUMERIC(18,2) NOT NULL,
  currency         TEXT DEFAULT 'EGP',
  exchange_rate    NUMERIC(18,6) DEFAULT 1,
  payment_method   TEXT DEFAULT 'cash' CHECK (payment_method IN ('cash','bank_transfer','vodafone_cash','instapay','card','cheque','other')),
  cash_account_id  UUID REFERENCES cash_accounts(id),
  reference        TEXT,
  notes            TEXT,
  status           TEXT DEFAULT 'received' CHECK (status IN ('received','cancelled','refunded')),
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payments_booking ON nsp_payments(booking_id);
CREATE INDEX IF NOT EXISTS idx_payments_date ON nsp_payments(payment_date);
ALTER TABLE nsp_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON nsp_payments FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "customer_own" ON nsp_payments FOR SELECT
  USING (customer_id = auth.uid());

-- ─── 15. PAYMENT ALLOCATIONS ─────────────────────────────────
CREATE TABLE IF NOT EXISTS payment_allocations (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id   UUID NOT NULL REFERENCES nsp_payments(id) ON DELETE CASCADE,
  invoice_id   UUID NOT NULL REFERENCES nsp_invoices(id),
  amount       NUMERIC(18,2) NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE payment_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON payment_allocations FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 16. EXPENSE CATEGORIES ──────────────────────────────────
CREATE TABLE IF NOT EXISTS expense_categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar     TEXT NOT NULL,
  name_en     TEXT,
  account_id  UUID REFERENCES accounts(id),
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON expense_categories FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 17. EXPENSES ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nsp_expenses (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_number   TEXT NOT NULL UNIQUE,
  expense_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  category_id      UUID REFERENCES expense_categories(id),
  account_id       UUID REFERENCES accounts(id),
  supplier_id      UUID REFERENCES suppliers(id),
  cost_center_id   UUID REFERENCES cost_centers(id),
  amount           NUMERIC(18,2) NOT NULL,
  tax_amount       NUMERIC(18,2) DEFAULT 0,
  total_amount     NUMERIC(18,2) NOT NULL,
  currency         TEXT DEFAULT 'EGP',
  exchange_rate    NUMERIC(18,6) DEFAULT 1,
  payment_account_id UUID REFERENCES cash_accounts(id),
  description      TEXT,
  receipt_url      TEXT,
  status           TEXT DEFAULT 'draft' CHECK (status IN ('draft','submitted','approved','posted','rejected')),
  is_recurring     BOOLEAN DEFAULT FALSE,
  recurrence_rule  TEXT,
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_by       UUID REFERENCES auth.users(id),
  approved_by      UUID REFERENCES auth.users(id),
  approved_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON nsp_expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_expenses_status ON nsp_expenses(status);
ALTER TABLE nsp_expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON nsp_expenses FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 18. BOOKING COSTS (for profitability) ───────────────────
CREATE TABLE IF NOT EXISTS booking_costs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('hotel','flight','visa','transport','other')),
  supplier_id  UUID REFERENCES suppliers(id),
  description  TEXT,
  amount       NUMERIC(18,2) NOT NULL DEFAULT 0,
  currency     TEXT DEFAULT 'EGP',
  exchange_rate NUMERIC(18,6) DEFAULT 1,
  base_amount  NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by   UUID REFERENCES auth.users(id),
  created_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_booking_costs_booking ON booking_costs(booking_id);
ALTER TABLE booking_costs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON booking_costs FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 19. CREDIT / DEBIT NOTES ────────────────────────────────
CREATE TABLE IF NOT EXISTS credit_notes (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  note_number      TEXT NOT NULL UNIQUE,
  type             TEXT NOT NULL DEFAULT 'credit' CHECK (type IN ('credit','debit')),
  invoice_id       UUID REFERENCES nsp_invoices(id),
  booking_id       UUID REFERENCES bookings(id),
  customer_id      UUID REFERENCES auth.users(id),
  customer_name    TEXT NOT NULL,
  issue_date       DATE NOT NULL DEFAULT CURRENT_DATE,
  amount           NUMERIC(18,2) NOT NULL,
  reason           TEXT,
  status           TEXT DEFAULT 'draft' CHECK (status IN ('draft','approved','applied','cancelled')),
  journal_entry_id UUID REFERENCES journal_entries(id),
  approved_by      UUID REFERENCES auth.users(id),
  approved_at      TIMESTAMPTZ,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE credit_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON credit_notes FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 20. BANK RECONCILIATIONS ────────────────────────────────
CREATE TABLE IF NOT EXISTS bank_reconciliations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cash_account_id   UUID NOT NULL REFERENCES cash_accounts(id),
  period_start      DATE NOT NULL,
  period_end        DATE NOT NULL,
  book_balance      NUMERIC(18,2) NOT NULL DEFAULT 0,
  statement_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
  difference        NUMERIC(18,2) GENERATED ALWAYS AS (statement_balance - book_balance) STORED,
  status            TEXT DEFAULT 'in_progress' CHECK (status IN ('in_progress','reconciled')),
  notes             TEXT,
  reconciled_by     UUID REFERENCES auth.users(id),
  reconciled_at     TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE bank_reconciliations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON bank_reconciliations FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 21. ACCOUNTING AUDIT LOG ────────────────────────────────
CREATE TABLE IF NOT EXISTS accounting_audit_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID REFERENCES auth.users(id),
  action       TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    UUID,
  before_data  JSONB,
  after_data   JSONB,
  reason       TEXT,
  created_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aal_entity ON accounting_audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_aal_user ON accounting_audit_logs(user_id);
ALTER TABLE accounting_audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON accounting_audit_logs FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 22. SEQUENCE HELPERS ─────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS je_seq START 1;
CREATE SEQUENCE IF NOT EXISTS inv_seq START 1;
CREATE SEQUENCE IF NOT EXISTS pay_seq START 1;
CREATE SEQUENCE IF NOT EXISTS exp_seq START 1;
CREATE SEQUENCE IF NOT EXISTS cn_seq START 1;

-- ─── 23. POSTING INTEGRITY CHECK ─────────────────────────────
-- Prevent posting unbalanced journal entries
CREATE OR REPLACE FUNCTION check_journal_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_debit  NUMERIC;
  v_credit NUMERIC;
BEGIN
  IF NEW.status = 'posted' THEN
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
    INTO v_debit, v_credit
    FROM journal_entry_lines
    WHERE journal_entry_id = NEW.id;

    IF ABS(v_debit - v_credit) > 0.01 THEN
      RAISE EXCEPTION 'Unbalanced journal entry: debit=% credit=%', v_debit, v_credit;
    END IF;

    -- Prevent editing posted entries
    IF OLD.status = 'posted' THEN
      RAISE EXCEPTION 'Cannot modify posted journal entry';
    END IF;
  END IF;

  -- Update totals
  NEW.total_debit  := (SELECT COALESCE(SUM(debit),0)  FROM journal_entry_lines WHERE journal_entry_id = NEW.id);
  NEW.total_credit := (SELECT COALESCE(SUM(credit),0) FROM journal_entry_lines WHERE journal_entry_id = NEW.id);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journal_balance ON journal_entries;
CREATE TRIGGER trg_journal_balance
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION check_journal_balance();

-- ─── 24. AUTO ENTRY NUMBER ───────────────────────────────────
CREATE OR REPLACE FUNCTION set_entry_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.entry_number IS NULL OR NEW.entry_number = '' THEN
    NEW.entry_number := 'JE-' || TO_CHAR(now(), 'YYYY') || '-' || LPAD(nextval('je_seq')::TEXT, 6, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entry_number ON journal_entries;
CREATE TRIGGER trg_entry_number
  BEFORE INSERT ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION set_entry_number();

-- ─── 25. GENERAL LEDGER VIEW ─────────────────────────────────
CREATE OR REPLACE VIEW general_ledger AS
SELECT
  jel.id,
  je.entry_date,
  je.entry_number,
  je.description,
  je.reference_type,
  je.reference_id,
  jel.account_id,
  a.code  AS account_code,
  a.name_ar AS account_name,
  a.type  AS account_type,
  jel.debit,
  jel.credit,
  jel.description AS line_description,
  jel.cost_center_id,
  cc.name_ar AS cost_center_name,
  je.status,
  je.created_by
FROM journal_entry_lines jel
JOIN journal_entries je ON je.id = jel.journal_entry_id
JOIN accounts a ON a.id = jel.account_id
LEFT JOIN cost_centers cc ON cc.id = jel.cost_center_id
WHERE je.status = 'posted';

-- ─── 26. ACCOUNT BALANCE FUNCTION ────────────────────────────
CREATE OR REPLACE FUNCTION get_account_balance(
  p_account_id UUID,
  p_from_date  DATE DEFAULT NULL,
  p_to_date    DATE DEFAULT NULL
)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
  v_debit  NUMERIC := 0;
  v_credit NUMERIC := 0;
  v_normal TEXT;
BEGIN
  SELECT normal_balance INTO v_normal FROM accounts WHERE id = p_account_id;

  SELECT COALESCE(SUM(jel.debit),0), COALESCE(SUM(jel.credit),0)
  INTO v_debit, v_credit
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  WHERE jel.account_id = p_account_id
    AND je.status = 'posted'
    AND (p_from_date IS NULL OR je.entry_date >= p_from_date)
    AND (p_to_date   IS NULL OR je.entry_date <= p_to_date);

  IF v_normal = 'debit' THEN
    RETURN v_debit - v_credit;
  ELSE
    RETURN v_credit - v_debit;
  END IF;
END;
$$;

-- ─── 27. TRIAL BALANCE VIEW ──────────────────────────────────
CREATE OR REPLACE VIEW trial_balance AS
SELECT
  a.code,
  a.name_ar,
  a.name_en,
  a.type,
  a.normal_balance,
  COALESCE(SUM(jel.debit),0)  AS total_debit,
  COALESCE(SUM(jel.credit),0) AS total_credit,
  CASE WHEN a.normal_balance = 'debit'
    THEN COALESCE(SUM(jel.debit),0) - COALESCE(SUM(jel.credit),0)
    ELSE COALESCE(SUM(jel.credit),0) - COALESCE(SUM(jel.debit),0)
  END AS balance
FROM accounts a
LEFT JOIN journal_entry_lines jel ON jel.account_id = a.id
LEFT JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
WHERE a.is_active = TRUE
GROUP BY a.id, a.code, a.name_ar, a.name_en, a.type, a.normal_balance
ORDER BY a.code;

-- ─── 28. BOOKING PROFITABILITY VIEW ──────────────────────────
CREATE OR REPLACE VIEW booking_profitability AS
SELECT
  b.id AS booking_id,
  b.booking_number,
  b.customer_name,
  b.package_id,
  p.title AS package_name,
  b.total_price AS selling_price,
  b.paid_amount,
  b.remaining_amount,
  COALESCE(SUM(CASE WHEN bc.type = 'hotel'     THEN bc.base_amount ELSE 0 END), 0) AS hotel_cost,
  COALESCE(SUM(CASE WHEN bc.type = 'flight'    THEN bc.base_amount ELSE 0 END), 0) AS flight_cost,
  COALESCE(SUM(CASE WHEN bc.type = 'visa'      THEN bc.base_amount ELSE 0 END), 0) AS visa_cost,
  COALESCE(SUM(CASE WHEN bc.type = 'transport' THEN bc.base_amount ELSE 0 END), 0) AS transport_cost,
  COALESCE(SUM(CASE WHEN bc.type = 'other'     THEN bc.base_amount ELSE 0 END), 0) AS other_cost,
  COALESCE(SUM(bc.base_amount), 0) AS total_cost,
  b.total_price - COALESCE(SUM(bc.base_amount), 0) AS gross_profit,
  CASE WHEN b.total_price > 0
    THEN ROUND((b.total_price - COALESCE(SUM(bc.base_amount), 0)) / b.total_price * 100, 2)
    ELSE 0
  END AS gross_margin_pct
FROM bookings b
LEFT JOIN packages p ON p.id = b.package_id
LEFT JOIN booking_costs bc ON bc.booking_id = b.id
GROUP BY b.id, b.booking_number, b.customer_name, b.package_id, p.title,
         b.total_price, b.paid_amount, b.remaining_amount;

-- ─── 29. FINANCIAL SUMMARY FUNCTION ─────────────────────────
CREATE OR REPLACE FUNCTION get_financial_summary(
  p_from_date DATE DEFAULT NULL,
  p_to_date   DATE DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_revenue        NUMERIC := 0;
  v_direct_costs   NUMERIC := 0;
  v_op_expenses    NUMERIC := 0;
  v_ar             NUMERIC := 0;
  v_ap             NUMERIC := 0;
  v_cash           NUMERIC := 0;
  result           JSONB;
BEGIN
  -- Revenue (credit balance on revenue accounts)
  SELECT COALESCE(SUM(jel.credit - jel.debit), 0) INTO v_revenue
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a ON a.id = jel.account_id
  WHERE je.status = 'posted' AND a.type = 'revenue'
    AND (p_from_date IS NULL OR je.entry_date >= p_from_date)
    AND (p_to_date   IS NULL OR je.entry_date <= p_to_date);

  -- Direct costs
  SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_direct_costs
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a ON a.id = jel.account_id
  WHERE je.status = 'posted' AND a.type = 'direct_cost'
    AND (p_from_date IS NULL OR je.entry_date >= p_from_date)
    AND (p_to_date   IS NULL OR je.entry_date <= p_to_date);

  -- Operating expenses
  SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_op_expenses
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a ON a.id = jel.account_id
  WHERE je.status = 'posted' AND a.type = 'expense'
    AND (p_from_date IS NULL OR je.entry_date >= p_from_date)
    AND (p_to_date   IS NULL OR je.entry_date <= p_to_date);

  -- AR balance
  SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_ar
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a ON a.id = jel.account_id
  WHERE je.status = 'posted' AND a.code LIKE '1200%';

  -- Cash balance
  SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_cash
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a ON a.id = jel.account_id
  WHERE je.status = 'posted' AND a.type = 'asset' AND a.code LIKE '11%';

  result := jsonb_build_object(
    'revenue',        v_revenue,
    'direct_costs',   v_direct_costs,
    'gross_profit',   v_revenue - v_direct_costs,
    'op_expenses',    v_op_expenses,
    'net_profit',     v_revenue - v_direct_costs - v_op_expenses,
    'gross_margin',   CASE WHEN v_revenue > 0 THEN ROUND((v_revenue - v_direct_costs)/v_revenue*100,2) ELSE 0 END,
    'net_margin',     CASE WHEN v_revenue > 0 THEN ROUND((v_revenue - v_direct_costs - v_op_expenses)/v_revenue*100,2) ELSE 0 END,
    'accounts_receivable', v_ar,
    'cash',           v_cash
  );

  RETURN result;
END;
$$;

