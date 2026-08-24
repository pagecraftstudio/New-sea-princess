-- ══════════════════════════════════════════════════════════════════
--  NSP Migration v18 — Debit Notes + Expense Auto-Journal Trigger
--
--  Adds:
--    1. debit_notes table (counterpart to credit_notes)
--    2. DB-level AFTER-UPDATE trigger on nsp_expenses: when status
--       transitions to 'posted', auto-create a balanced journal:
--         DR  expense_account (from expense.gl_account_id or mapping)
--         CR  cash/bank account (from expense.payment_gl_account_id or mapping)
--    3. RLS policies for debit_notes
--    4. Index on debit_notes for performance
--
--  Safe: idempotent, uses ON CONFLICT DO NOTHING, EXCEPTION blocks.
-- ══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
--  PART 1 — DEBIT NOTES TABLE
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS debit_notes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  note_number       TEXT UNIQUE NOT NULL,
  note_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  customer_id       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  supplier_id       UUID REFERENCES suppliers(id) ON DELETE SET NULL,
  invoice_id        UUID REFERENCES nsp_invoices(id) ON DELETE SET NULL,
  booking_id        UUID REFERENCES bookings(id) ON DELETE SET NULL,
  amount            NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  currency          TEXT NOT NULL DEFAULT 'EGP',
  exchange_rate     NUMERIC(12,6) NOT NULL DEFAULT 1,
  base_amount       NUMERIC(18,2) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  reason            TEXT,
  notes             TEXT,
  status            TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','issued','applied','cancelled')),
  journal_entry_id  UUID REFERENCES journal_entries(id),
  cost_center_id    UUID REFERENCES cost_centers(id),
  created_by        UUID REFERENCES auth.users(id),
  approved_by       UUID REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_debit_notes_customer  ON debit_notes(customer_id);
CREATE INDEX IF NOT EXISTS idx_debit_notes_supplier  ON debit_notes(supplier_id);
CREATE INDEX IF NOT EXISTS idx_debit_notes_date      ON debit_notes(note_date);
CREATE INDEX IF NOT EXISTS idx_debit_notes_status    ON debit_notes(status);

ALTER TABLE debit_notes ENABLE ROW LEVEL SECURITY;

-- Admins full access
DROP POLICY IF EXISTS "admins_all_debit_notes" ON debit_notes;
CREATE POLICY "admins_all_debit_notes" ON debit_notes FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM admin_users
      WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','cashier','auditor')
    )
  );

-- Customers see their own debit notes
DROP POLICY IF EXISTS "customers_own_debit_notes" ON debit_notes;
CREATE POLICY "customers_own_debit_notes" ON debit_notes FOR SELECT
  USING (customer_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────
--  PART 2 — DEBIT NOTE NUMBER SEQUENCE FUNCTION
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION generate_debit_note_number()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_seq INT;
  v_year TEXT;
BEGIN
  v_year := TO_CHAR(NOW(), 'YYYY');
  SELECT COALESCE(MAX(
    NULLIF(REGEXP_REPLACE(note_number, '[^0-9]', '', 'g'), '')::INT
  ), 0) + 1
  INTO v_seq
  FROM debit_notes
  WHERE note_number LIKE 'DN-' || v_year || '-%';
  RETURN 'DN-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$;

-- ─────────────────────────────────────────────────────────────────
--  PART 3 — EXPENSE AUTO-JOURNAL TRIGGER
--  When nsp_expenses.status transitions to 'posted':
--    DR  gl_account_id (or fallback mapping 'expense_general')
--    CR  payment_gl_account_id (or fallback mapping 'cash_account')
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_journal_expense()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_je_id        UUID;
  v_exp_acct     UUID;
  v_cash_acct    UUID;
  v_fp_id        UUID;
  v_amount       NUMERIC(18,2);
  v_desc         TEXT;
BEGIN
  -- Only act when status transitions TO 'posted'
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status <> 'posted' THEN RETURN NEW; END IF;
    IF OLD.status = 'posted' THEN RETURN NEW; END IF; -- already processed
  ELSE
    IF NEW.status <> 'posted' THEN RETURN NEW; END IF;
  END IF;

  -- Skip if journal already exists
  IF NEW.journal_entry_id IS NOT NULL THEN RETURN NEW; END IF;

  v_amount := NEW.total_amount;
  IF v_amount IS NULL OR v_amount <= 0 THEN RETURN NEW; END IF;

  -- Resolve expense account
  IF NEW.gl_account_id IS NOT NULL THEN
    v_exp_acct := NEW.gl_account_id;
  ELSE
    SELECT account_id INTO v_exp_acct
    FROM accounting_mappings WHERE mapping_key = 'expense_general' LIMIT 1;
  END IF;

  -- Resolve cash/bank/payment account
  IF NEW.payment_gl_account_id IS NOT NULL THEN
    v_cash_acct := NEW.payment_gl_account_id;
  ELSE
    SELECT account_id INTO v_cash_acct
    FROM accounting_mappings WHERE mapping_key = 'cash_account' LIMIT 1;
  END IF;

  IF v_exp_acct IS NULL OR v_cash_acct IS NULL THEN
    -- Missing mapping — log and skip, don't block the update
    RAISE WARNING 'fn_auto_journal_expense: missing account mapping for expense %', NEW.id;
    RETURN NEW;
  END IF;

  -- Find open fiscal period
  SELECT id INTO v_fp_id
  FROM fiscal_periods
  WHERE start_date <= NEW.expense_date
    AND end_date   >= NEW.expense_date
    AND status = 'open'
  LIMIT 1;

  v_desc := COALESCE(NEW.description, 'مصروف');

  BEGIN
    -- Insert journal entry header
    INSERT INTO journal_entries (
      entry_date, fiscal_period_id, description,
      reference_type, reference_id, status,
      total_debit, total_credit,
      cost_center_id, posted_at
    ) VALUES (
      NEW.expense_date, v_fp_id, v_desc,
      'expense', NEW.id, 'posted',
      v_amount, v_amount,
      NEW.cost_center_id, NOW()
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_je_id;

    IF v_je_id IS NULL THEN RETURN NEW; END IF;

    -- Journal lines: DR expense / CR cash
    INSERT INTO journal_entry_lines
      (journal_entry_id, account_id, debit, credit, description, cost_center_id, line_order)
    VALUES
      (v_je_id, v_exp_acct,  v_amount, 0,        v_desc, NEW.cost_center_id, 0),
      (v_je_id, v_cash_acct, 0,        v_amount, v_desc, NEW.cost_center_id, 1);

    -- Link back to expense
    UPDATE nsp_expenses SET journal_entry_id = v_je_id WHERE id = NEW.id;
    NEW.journal_entry_id := v_je_id;

  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_auto_journal_expense: failed for expense %, error: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_journal_expense ON nsp_expenses;
CREATE TRIGGER trg_auto_journal_expense
  AFTER INSERT OR UPDATE OF status ON nsp_expenses
  FOR EACH ROW EXECUTE FUNCTION fn_auto_journal_expense();

-- ─────────────────────────────────────────────────────────────────
--  PART 4 — ADD journal_entry_id + payment_gl_account_id to
--           nsp_expenses if not already present
-- ─────────────────────────────────────────────════════════════════

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='nsp_expenses' AND column_name='journal_entry_id'
  ) THEN
    ALTER TABLE nsp_expenses ADD COLUMN journal_entry_id UUID REFERENCES journal_entries(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='nsp_expenses' AND column_name='payment_gl_account_id'
  ) THEN
    ALTER TABLE nsp_expenses ADD COLUMN payment_gl_account_id UUID REFERENCES accounts(id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='nsp_expenses' AND column_name='gl_account_id'
  ) THEN
    ALTER TABLE nsp_expenses ADD COLUMN gl_account_id UUID REFERENCES accounts(id);
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
--  PART 5 — ADD gl_account_id to cash_accounts if missing
--  (needed for transfer JE resolution in the front-end)
-- ─────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='cash_accounts' AND column_name='gl_account_id'
  ) THEN
    ALTER TABLE cash_accounts ADD COLUMN gl_account_id UUID REFERENCES accounts(id);
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
--  PART 6 — accounting_mappings: ensure 'expense_general' key
--  exists (insert only if not already present).
-- ─────────────────────────────────────────────────────────────────

INSERT INTO accounting_mappings (mapping_key, account_id, description)
SELECT
  'expense_general',
  id,
  'مصاريف عمومية — الحساب الافتراضي للمصاريف'
FROM accounts
WHERE code ILIKE '6%' OR type = 'expense'
ORDER BY code
LIMIT 1
ON CONFLICT (mapping_key) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════
-- END OF MIGRATION v18
-- ══════════════════════════════════════════════════════════════════
