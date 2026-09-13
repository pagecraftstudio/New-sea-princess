-- ══════════════════════════════════════════════════════════════
--  NSP Migration v5 — Expenses Module (idempotent, safe to re-run)
-- ══════════════════════════════════════════════════════════════

-- ─── 1. COST CENTERS ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cost_centers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT,
  name_ar     TEXT NOT NULL,
  name_en     TEXT,
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT now()
);
-- Patch missing columns if table existed with old schema
ALTER TABLE cost_centers ADD COLUMN IF NOT EXISTS code TEXT;
ALTER TABLE cost_centers ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE cost_centers ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;
DO $$ BEGIN
  ALTER TABLE cost_centers ADD CONSTRAINT cost_centers_code_key UNIQUE (code);
EXCEPTION WHEN duplicate_table THEN NULL; WHEN others THEN NULL; END $$;

INSERT INTO cost_centers (code, name_ar, name_en) VALUES
  ('CC-GEN', 'عام',          'General'),
  ('CC-UMR', 'عمرة',         'Umrah'),
  ('CC-HAJ', 'حج',           'Hajj'),
  ('CC-TRS', 'سياحة',        'Tourism'),
  ('CC-TKT', 'تذاكر طيران', 'Airline Tickets'),
  ('CC-VIS', 'تأشيرات',      'Visas')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE cost_centers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admins_all" ON cost_centers;
CREATE POLICY "admins_all" ON cost_centers FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 2. EXPENSE CATEGORIES ───────────────────────────────────
CREATE TABLE IF NOT EXISTS expense_categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT,
  name_ar     TEXT NOT NULL,
  name_en     TEXT,
  parent_id   UUID REFERENCES expense_categories(id),
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT now()
);
-- Patch missing columns if table existed with old schema
ALTER TABLE expense_categories ADD COLUMN IF NOT EXISTS code TEXT;
ALTER TABLE expense_categories ADD COLUMN IF NOT EXISTS name_en TEXT;
ALTER TABLE expense_categories ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;
ALTER TABLE expense_categories ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES expense_categories(id);
DO $$ BEGIN
  ALTER TABLE expense_categories ADD CONSTRAINT expense_categories_code_key UNIQUE (code);
EXCEPTION WHEN duplicate_table THEN NULL; WHEN others THEN NULL; END $$;

INSERT INTO expense_categories (code, name_ar, name_en) VALUES
  ('EXP-SAL', 'رواتب وأجور',        'Salaries & Wages'),
  ('EXP-RNT', 'إيجار',              'Rent'),
  ('EXP-UTL', 'مرافق',              'Utilities'),
  ('EXP-MKT', 'تسويق وإعلان',       'Marketing & Advertising'),
  ('EXP-COM', 'اتصالات',            'Communications'),
  ('EXP-SFT', 'برمجيات واشتراكات',  'Software & Subscriptions'),
  ('EXP-BNK', 'رسوم بنكية',         'Bank Fees'),
  ('EXP-CMM', 'عمولات',             'Commissions'),
  ('EXP-OFF', 'مستلزمات مكتبية',    'Office Supplies'),
  ('EXP-HTL', 'تكلفة فنادق',        'Hotel Costs'),
  ('EXP-AIR', 'تكلفة طيران',        'Airline Costs'),
  ('EXP-VIS', 'تكلفة تأشيرات',      'Visa Costs'),
  ('EXP-TRN', 'تكلفة نقل',          'Transport Costs'),
  ('EXP-PKG', 'تكلفة باقات موردين', 'Supplier Package Costs'),
  ('EXP-OTH', 'مصاريف أخرى',        'Other Expenses')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admins_all" ON expense_categories;
CREATE POLICY "admins_all" ON expense_categories FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 3. EXPENSES ─────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS expense_seq START 1;

CREATE TABLE IF NOT EXISTS expenses (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_number    TEXT UNIQUE,
  expense_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  category_id       UUID REFERENCES expense_categories(id),
  cost_center_id    UUID REFERENCES cost_centers(id),
  supplier_id       UUID,
  supplier_name     TEXT,
  payment_method    TEXT DEFAULT 'cash'
    CHECK (payment_method IN ('cash','bank','wallet','cheque','transfer')),
  payment_account   TEXT,
  amount            NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency          TEXT DEFAULT 'EGP',
  exchange_rate     NUMERIC(12,6) DEFAULT 1,
  amount_base       NUMERIC(12,2) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  tax_amount        NUMERIC(12,2) DEFAULT 0,
  total_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  description       TEXT,
  reference         TEXT,
  receipt_url       TEXT,
  booking_id        UUID REFERENCES bookings(id),
  status            TEXT DEFAULT 'draft'
    CHECK (status IN ('draft','submitted','approved','posted','rejected')),
  rejection_reason  TEXT,
  is_recurring      BOOLEAN DEFAULT FALSE,
  recurrence_rule   TEXT,
  next_recurrence   DATE,
  created_by        UUID REFERENCES auth.users(id),
  submitted_by      UUID REFERENCES auth.users(id),
  submitted_at      TIMESTAMPTZ,
  approved_by       UUID REFERENCES auth.users(id),
  approved_at       TIMESTAMPTZ,
  posted_at         TIMESTAMPTZ,
  journal_entry_id  UUID,
  notes             TEXT,
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION set_expense_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.expense_number IS NULL OR NEW.expense_number = '' THEN
    NEW.expense_number := 'EXP-' || TO_CHAR(now(), 'YYYY') || '-' ||
      LPAD(nextval('expense_seq')::TEXT, 5, '0');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_expense_number ON expenses;
CREATE TRIGGER trg_expense_number
  BEFORE INSERT ON expenses
  FOR EACH ROW EXECUTE FUNCTION set_expense_number();

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;
DROP TRIGGER IF EXISTS trg_expenses_updated ON expenses;
CREATE TRIGGER trg_expenses_updated
  BEFORE UPDATE ON expenses
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION guard_posted_expense()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'posted' AND NEW.status != 'posted' THEN
    RAISE EXCEPTION 'Cannot change status of a posted expense.';
  END IF;
  IF OLD.status = 'posted' AND (
    NEW.amount != OLD.amount OR NEW.expense_date != OLD.expense_date
  ) THEN
    RAISE EXCEPTION 'Posted expenses are immutable. Create a reversal instead.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_posted_expense ON expenses;
CREATE TRIGGER trg_guard_posted_expense
  BEFORE UPDATE ON expenses
  FOR EACH ROW EXECUTE FUNCTION guard_posted_expense();

CREATE INDEX IF NOT EXISTS idx_expenses_status      ON expenses(status);
CREATE INDEX IF NOT EXISTS idx_expenses_date        ON expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_expenses_category    ON expenses(category_id);
CREATE INDEX IF NOT EXISTS idx_expenses_cost_center ON expenses(cost_center_id);
CREATE INDEX IF NOT EXISTS idx_expenses_booking     ON expenses(booking_id);

ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admins_all" ON expenses;
CREATE POLICY "admins_all" ON expenses FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 4. VERIFY ───────────────────────────────────────────────
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('expense_categories','cost_centers','expenses')
ORDER BY table_name;
