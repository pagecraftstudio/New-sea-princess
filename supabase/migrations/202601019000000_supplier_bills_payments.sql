-- ══════════════════════════════════════════════════════════════════
--  NSP Migration v19 — Supplier Bills & Supplier Payments Tables
--
--  These tables are referenced by nsp-control-8x4k/suppliers.html
--  but were missing from all previous migrations.
--
--  Adds:
--    1. supplier_bills   — AP bills from suppliers
--    2. supplier_payments — payments made to suppliers
--    3. RLS policies for both tables
--    4. Indexes for performance
--    5. journal_entry_id columns for accounting linkage
--    6. Auto-trigger: when a bill is inserted, create DR Cost / CR AP
--    7. Auto-trigger: when a payment is posted, create DR AP / CR Cash
--
--  Safe: idempotent, EXCEPTION blocks, ON CONFLICT DO NOTHING.
-- ══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
--  PART 1 — SUPPLIER BILLS TABLE
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supplier_bills (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bill_number       TEXT UNIQUE,
  supplier_id       UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
  bill_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  due_date          DATE,
  total_amount      NUMERIC(18,2) NOT NULL CHECK (total_amount > 0),
  paid_amount       NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  remaining_amount  NUMERIC(18,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED,
  currency          TEXT NOT NULL DEFAULT 'EGP',
  exchange_rate     NUMERIC(12,6) NOT NULL DEFAULT 1,
  base_amount       NUMERIC(18,2) GENERATED ALWAYS AS (total_amount * exchange_rate) STORED,
  reference         TEXT,
  description       TEXT,
  cost_account_id   UUID REFERENCES accounts(id),
  booking_id        UUID REFERENCES bookings(id) ON DELETE SET NULL,
  status            TEXT NOT NULL DEFAULT 'issued'
                    CHECK (status IN ('draft','issued','partial','paid','cancelled','overdue')),
  journal_entry_id  UUID REFERENCES journal_entries(id),
  fiscal_period_id  UUID REFERENCES fiscal_periods(id),
  cost_center_id    UUID REFERENCES cost_centers(id),
  created_by        UUID REFERENCES auth.users(id),
  approved_by       UUID REFERENCES auth.users(id),
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Generate bill numbers
CREATE OR REPLACE FUNCTION generate_bill_number()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_seq  INT;
  v_year TEXT;
BEGIN
  v_year := TO_CHAR(NOW(), 'YYYY');
  SELECT COALESCE(MAX(
    NULLIF(REGEXP_REPLACE(bill_number, '[^0-9]', '', 'g'), '')::INT
  ), 0) + 1
  INTO v_seq
  FROM supplier_bills
  WHERE bill_number LIKE 'SB-' || v_year || '-%';
  RETURN 'SB-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$;

-- Auto-set bill_number if not provided
CREATE OR REPLACE FUNCTION fn_set_bill_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.bill_number IS NULL OR NEW.bill_number = '' THEN
    NEW.bill_number := generate_bill_number();
  END IF;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_bill_number ON supplier_bills;
CREATE TRIGGER trg_set_bill_number
  BEFORE INSERT ON supplier_bills
  FOR EACH ROW EXECUTE FUNCTION fn_set_bill_number();

-- Updated_at trigger
CREATE OR REPLACE FUNCTION fn_supplier_bills_updated()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_bills_updated ON supplier_bills;
CREATE TRIGGER trg_supplier_bills_updated
  BEFORE UPDATE ON supplier_bills
  FOR EACH ROW EXECUTE FUNCTION fn_supplier_bills_updated();

CREATE INDEX IF NOT EXISTS idx_supplier_bills_supplier  ON supplier_bills(supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_bills_date      ON supplier_bills(bill_date);
CREATE INDEX IF NOT EXISTS idx_supplier_bills_due       ON supplier_bills(due_date);
CREATE INDEX IF NOT EXISTS idx_supplier_bills_status    ON supplier_bills(status);
CREATE INDEX IF NOT EXISTS idx_supplier_bills_booking   ON supplier_bills(booking_id);

ALTER TABLE supplier_bills ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_all_supplier_bills" ON supplier_bills;
CREATE POLICY "admins_all_supplier_bills" ON supplier_bills FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM admin_users
      WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','cashier','auditor','sales_agent','booking_agent')
    )
  );

-- ─────────────────────────────────────────────────────────────────
--  PART 2 — SUPPLIER PAYMENTS TABLE
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supplier_payments (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_number       TEXT UNIQUE,
  supplier_id          UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
  supplier_bill_id     UUID REFERENCES supplier_bills(id) ON DELETE SET NULL,
  payment_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  amount               NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  currency             TEXT NOT NULL DEFAULT 'EGP',
  exchange_rate        NUMERIC(12,6) NOT NULL DEFAULT 1,
  base_amount          NUMERIC(18,2) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  payment_method       TEXT NOT NULL DEFAULT 'cash'
                       CHECK (payment_method IN ('cash','bank_transfer','cheque','wallet','card','other')),
  cash_gl_account_id   UUID REFERENCES accounts(id),
  reference            TEXT,
  notes                TEXT,
  status               TEXT NOT NULL DEFAULT 'posted'
                       CHECK (status IN ('draft','posted','cancelled')),
  journal_entry_id     UUID REFERENCES journal_entries(id),
  created_by           UUID REFERENCES auth.users(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Auto-set payment_number
CREATE OR REPLACE FUNCTION fn_set_supplier_payment_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_seq  INT;
  v_year TEXT;
BEGIN
  IF NEW.payment_number IS NULL OR NEW.payment_number = '' THEN
    v_year := TO_CHAR(NOW(), 'YYYY');
    SELECT COALESCE(MAX(
      NULLIF(REGEXP_REPLACE(payment_number, '[^0-9]', '', 'g'), '')::INT
    ), 0) + 1
    INTO v_seq
    FROM supplier_payments
    WHERE payment_number LIKE 'SP-' || v_year || '-%';
    NEW.payment_number := 'SP-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
  END IF;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_supplier_payment_number ON supplier_payments;
CREATE TRIGGER trg_set_supplier_payment_number
  BEFORE INSERT ON supplier_payments
  FOR EACH ROW EXECUTE FUNCTION fn_set_supplier_payment_number();

CREATE INDEX IF NOT EXISTS idx_supplier_payments_supplier ON supplier_payments(supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_payments_bill     ON supplier_payments(supplier_bill_id);
CREATE INDEX IF NOT EXISTS idx_supplier_payments_date     ON supplier_payments(payment_date);

ALTER TABLE supplier_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_all_supplier_payments" ON supplier_payments;
CREATE POLICY "admins_all_supplier_payments" ON supplier_payments FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM admin_users
      WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','cashier','auditor')
    )
  );

-- ─────────────────────────────────────────────────────────────────
--  PART 3 — AUTO-JOURNAL TRIGGER: SUPPLIER BILL INSERTED
--  DR  cost_account_id (or mapping 'cost_other')
--  CR  ap_account (from accounting_mappings)
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_journal_supplier_bill()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_je_id     UUID;
  v_cost_acct UUID;
  v_ap_acct   UUID;
  v_fp_id     UUID;
BEGIN
  -- Only act on INSERT (new bills auto-journal immediately)
  IF NEW.journal_entry_id IS NOT NULL THEN RETURN NEW; END IF;

  -- Skip drafts
  IF NEW.status = 'draft' THEN RETURN NEW; END IF;

  -- Resolve cost account
  IF NEW.cost_account_id IS NOT NULL THEN
    v_cost_acct := NEW.cost_account_id;
  ELSE
    SELECT account_id INTO v_cost_acct
    FROM accounting_mappings WHERE mapping_key = 'cost_other' LIMIT 1;
  END IF;

  -- Resolve AP account
  SELECT account_id INTO v_ap_acct
  FROM accounting_mappings WHERE mapping_key = 'ap_account' LIMIT 1;

  IF v_cost_acct IS NULL OR v_ap_acct IS NULL THEN
    RAISE WARNING 'fn_auto_journal_supplier_bill: missing account mapping for bill %', NEW.id;
    RETURN NEW;
  END IF;

  -- Find fiscal period
  SELECT id INTO v_fp_id
  FROM fiscal_periods
  WHERE start_date <= NEW.bill_date
    AND end_date   >= NEW.bill_date
    AND status = 'open'
  LIMIT 1;

  BEGIN
    INSERT INTO journal_entries (
      entry_date, fiscal_period_id, description,
      reference_type, reference_id, status,
      total_debit, total_credit, posted_at
    ) VALUES (
      NEW.bill_date, v_fp_id,
      COALESCE(NEW.description, 'فاتورة مورد — ' || NEW.bill_number),
      'supplier_bill', NEW.id, 'posted',
      NEW.total_amount, NEW.total_amount, NOW()
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_je_id;

    IF v_je_id IS NULL THEN RETURN NEW; END IF;

    INSERT INTO journal_entry_lines
      (journal_entry_id, account_id, debit, credit, description, line_order)
    VALUES
      (v_je_id, v_cost_acct, NEW.total_amount, 0,               COALESCE(NEW.description,'تكلفة'), 0),
      (v_je_id, v_ap_acct,   0,                NEW.total_amount, 'ذمم دائنة - مورد',               1);

    UPDATE supplier_bills SET journal_entry_id = v_je_id WHERE id = NEW.id;
    NEW.journal_entry_id := v_je_id;

  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_auto_journal_supplier_bill: failed for bill %, error: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_journal_supplier_bill ON supplier_bills;
CREATE TRIGGER trg_auto_journal_supplier_bill
  AFTER INSERT ON supplier_bills
  FOR EACH ROW EXECUTE FUNCTION fn_auto_journal_supplier_bill();

-- ─────────────────────────────────────────────────────────────────
--  PART 4 — AUTO-JOURNAL TRIGGER: SUPPLIER PAYMENT POSTED
--  DR  ap_account
--  CR  cash_gl_account_id (or mapping 'cash_account')
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_journal_supplier_payment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_je_id     UUID;
  v_ap_acct   UUID;
  v_cash_acct UUID;
  v_fp_id     UUID;
  v_supplier  TEXT;
BEGIN
  IF NEW.journal_entry_id IS NOT NULL THEN RETURN NEW; END IF;
  IF NEW.status <> 'posted' THEN RETURN NEW; END IF;

  SELECT account_id INTO v_ap_acct
  FROM accounting_mappings WHERE mapping_key = 'ap_account' LIMIT 1;

  IF NEW.cash_gl_account_id IS NOT NULL THEN
    v_cash_acct := NEW.cash_gl_account_id;
  ELSE
    SELECT account_id INTO v_cash_acct
    FROM accounting_mappings WHERE mapping_key = 'cash_account' LIMIT 1;
  END IF;

  IF v_ap_acct IS NULL OR v_cash_acct IS NULL THEN
    RAISE WARNING 'fn_auto_journal_supplier_payment: missing mapping for payment %', NEW.id;
    RETURN NEW;
  END IF;

  SELECT id INTO v_fp_id
  FROM fiscal_periods
  WHERE start_date <= NEW.payment_date
    AND end_date   >= NEW.payment_date
    AND status = 'open'
  LIMIT 1;

  SELECT name_ar INTO v_supplier FROM suppliers WHERE id = NEW.supplier_id LIMIT 1;

  BEGIN
    INSERT INTO journal_entries (
      entry_date, fiscal_period_id, description,
      reference_type, reference_id, status,
      total_debit, total_credit, posted_at
    ) VALUES (
      NEW.payment_date, v_fp_id,
      'دفعة لمورد — ' || COALESCE(v_supplier, '') || ' — ' || COALESCE(NEW.payment_number,''),
      'supplier_payment', NEW.id, 'posted',
      NEW.amount, NEW.amount, NOW()
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_je_id;

    IF v_je_id IS NULL THEN RETURN NEW; END IF;

    INSERT INTO journal_entry_lines
      (journal_entry_id, account_id, debit, credit, description, line_order)
    VALUES
      (v_je_id, v_ap_acct,   NEW.amount, 0,          'تسوية ذمم دائنة', 0),
      (v_je_id, v_cash_acct, 0,          NEW.amount, 'صرف نقدي/بنكي',   1);

    UPDATE supplier_payments SET journal_entry_id = v_je_id WHERE id = NEW.id;
    NEW.journal_entry_id := v_je_id;

  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_auto_journal_supplier_payment: failed for payment %, error: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_journal_supplier_payment ON supplier_payments;
CREATE TRIGGER trg_auto_journal_supplier_payment
  AFTER INSERT ON supplier_payments
  FOR EACH ROW EXECUTE FUNCTION fn_auto_journal_supplier_payment();

-- ─────────────────────────────────────────────────────────────────
--  PART 5 — SUPPLIER STATEMENT VIEW (includes supplier_bills)
--  Must DROP first because column names differ from the v12 version.
--  Column names match the v12 schema: supplier_id, supplier_name,
--  txn_type, reference, txn_date, due_date, credit, debit,
--  balance, currency, status.
-- ─────────────────────────────────────────────────────────────────

DROP VIEW IF EXISTS supplier_statement;

CREATE VIEW supplier_statement AS
-- Bills: we owe the supplier (credit = amount owed)
SELECT
  s.id                                             AS supplier_id,
  COALESCE(s.name_en, s.name_ar)                  AS supplier_name,
  'bill'                                           AS txn_type,
  sb.bill_number                                   AS reference,
  sb.bill_date                                     AS txn_date,
  sb.due_date,
  sb.total_amount                                  AS credit,
  0::NUMERIC(18,2)                                 AS debit,
  sb.remaining_amount                              AS balance,
  sb.currency,
  sb.status
FROM suppliers s
JOIN supplier_bills sb ON sb.supplier_id = s.id
WHERE sb.status NOT IN ('draft','cancelled')

UNION ALL

-- Payments: we paid the supplier (debit = amount paid)
SELECT
  s.id,
  COALESCE(s.name_en, s.name_ar),
  'payment',
  sp.payment_number,
  sp.payment_date,
  NULL,
  0::NUMERIC(18,2),
  sp.amount,
  -sp.amount,
  sp.currency,
  sp.status
FROM suppliers s
JOIN supplier_payments sp ON sp.supplier_id = s.id
WHERE sp.status = 'posted'

UNION ALL

-- Legacy: expenses linked to suppliers (from v12 original)
SELECT
  e.supplier_id,
  COALESCE(s.name_en, s.name_ar),
  'expense',
  e.expense_number,
  e.expense_date,
  e.due_date,
  e.total_amount,
  0::NUMERIC(18,2),
  (e.total_amount - e.paid_amount),
  e.currency,
  e.status
FROM nsp_expenses e
LEFT JOIN suppliers s ON s.id = e.supplier_id
WHERE e.supplier_id IS NOT NULL
  AND e.status NOT IN ('draft','rejected')

ORDER BY txn_date DESC;

GRANT SELECT ON supplier_statement TO authenticated;

-- ══════════════════════════════════════════════════════════════════
-- END OF MIGRATION v19
-- ══════════════════════════════════════════════════════════════════
