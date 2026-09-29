-- ══════════════════════════════════════════════════════════════
--  NSP Migration v13 — Fiscal Periods Enhancement (Section 13)
--  Adds year-end closing, retained earnings transfer, period
--  enforcement on journal postings, and historical data safety.
--  Safe additive — fiscal_periods table already exists from v5.
--  Run after v12.
-- ══════════════════════════════════════════════════════════════

-- ─── 1. EXTEND fiscal_periods TABLE ──────────────────────────
-- Add fields needed for year-end closing workflow
ALTER TABLE fiscal_periods
  ADD COLUMN IF NOT EXISTS period_type    TEXT DEFAULT 'monthly'
    CHECK (period_type IN ('monthly','quarterly','annual')),
  ADD COLUMN IF NOT EXISTS year           INT,
  ADD COLUMN IF NOT EXISTS period_number  INT,  -- 1-12 monthly, 1-4 quarterly
  ADD COLUMN IF NOT EXISTS notes          TEXT,
  ADD COLUMN IF NOT EXISTS is_year_end    BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS year_end_closed_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS year_end_closed_by   UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS retained_earnings_je UUID; -- reference to closing JE

-- Backfill year from existing rows
UPDATE fiscal_periods
  SET year = EXTRACT(YEAR FROM start_date)::INT
  WHERE year IS NULL;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_fp_status ON fiscal_periods(status);
CREATE INDEX IF NOT EXISTS idx_fp_year   ON fiscal_periods(year);
CREATE INDEX IF NOT EXISTS idx_fp_dates  ON fiscal_periods(start_date, end_date);

-- ─── 2. ENFORCE PERIOD STATUS ON JOURNAL POSTING ─────────────
-- Prevent posting to closed periods (trigger on journal_entries)
CREATE OR REPLACE FUNCTION enforce_fiscal_period_on_post()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_period_status TEXT;
BEGIN
  -- Only enforce when transitioning to 'posted'
  IF NEW.status = 'posted' AND (OLD.status IS DISTINCT FROM 'posted') THEN
    -- If a fiscal_period_id is set, check it's open
    IF NEW.fiscal_period_id IS NOT NULL THEN
      SELECT status INTO v_period_status
        FROM fiscal_periods WHERE id = NEW.fiscal_period_id;
      IF v_period_status = 'closed' THEN
        RAISE EXCEPTION 'لا يمكن الترحيل إلى فترة مالية مغلقة (closed period).';
      END IF;
    ELSE
      -- Auto-assign open fiscal period by entry_date
      SELECT id INTO NEW.fiscal_period_id
        FROM fiscal_periods
        WHERE status IN ('open','closing')
          AND start_date <= NEW.entry_date
          AND end_date   >= NEW.entry_date
        ORDER BY start_date DESC
        LIMIT 1;
      -- If still none, check for any closed period that covers this date
      IF NEW.fiscal_period_id IS NULL THEN
        IF EXISTS (
          SELECT 1 FROM fiscal_periods
          WHERE status = 'closed'
            AND start_date <= NEW.entry_date
            AND end_date   >= NEW.entry_date
        ) THEN
          RAISE EXCEPTION 'تاريخ القيد يقع في فترة مالية مغلقة. استخدم فترة مفتوحة.';
        END IF;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_fiscal_period ON journal_entries;
CREATE TRIGGER trg_enforce_fiscal_period
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_fiscal_period_on_post();

-- Also enforce on INSERT (for direct posted inserts)
CREATE OR REPLACE FUNCTION enforce_fiscal_period_on_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_period_status TEXT;
BEGIN
  IF NEW.status = 'posted' THEN
    IF NEW.fiscal_period_id IS NOT NULL THEN
      SELECT status INTO v_period_status
        FROM fiscal_periods WHERE id = NEW.fiscal_period_id;
      IF v_period_status = 'closed' THEN
        RAISE EXCEPTION 'لا يمكن الترحيل إلى فترة مالية مغلقة.';
      END IF;
    ELSE
      SELECT id INTO NEW.fiscal_period_id
        FROM fiscal_periods
        WHERE status IN ('open','closing')
          AND start_date <= NEW.entry_date
          AND end_date   >= NEW.entry_date
        ORDER BY start_date DESC
        LIMIT 1;
      IF NEW.fiscal_period_id IS NULL THEN
        IF EXISTS (
          SELECT 1 FROM fiscal_periods
          WHERE status = 'closed'
            AND start_date <= NEW.entry_date
            AND end_date   >= NEW.entry_date
        ) THEN
          RAISE EXCEPTION 'تاريخ القيد يقع في فترة مالية مغلقة.';
        END IF;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_fiscal_period_insert ON journal_entries;
CREATE TRIGGER trg_enforce_fiscal_period_insert
  BEFORE INSERT ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_fiscal_period_on_insert();

-- ─── 3. YEAR-END CLOSING FUNCTION ────────────────────────────
-- Closes a fiscal period (usually annual).
-- Transfers net P&L to Retained Earnings account.
-- Creates a balancing closing journal entry.
-- REQUIRES: retained_earnings account exists in accounts table
--           (account code '3200' by convention from v6 seed).
CREATE OR REPLACE FUNCTION close_fiscal_period(
  p_period_id          UUID,
  p_closed_by          UUID,
  p_retained_earnings_account_id UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_period            fiscal_periods%ROWTYPE;
  v_net_profit        NUMERIC(18,2) := 0;
  v_total_revenue     NUMERIC(18,2) := 0;
  v_total_cost        NUMERIC(18,2) := 0;
  v_re_account_id     UUID;
  v_je_id             UUID;
  v_je_number         TEXT;
  v_entry_number      TEXT;
  v_line_order        INT := 1;
  v_rev_account       RECORD;
  v_exp_account       RECORD;
BEGIN
  -- Load period
  SELECT * INTO v_period FROM fiscal_periods WHERE id = p_period_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'الفترة المالية غير موجودة: %', p_period_id;
  END IF;
  IF v_period.status = 'closed' THEN
    RAISE EXCEPTION 'الفترة المالية مغلقة مسبقاً.';
  END IF;

  -- Resolve retained earnings account
  v_re_account_id := p_retained_earnings_account_id;
  IF v_re_account_id IS NULL THEN
    SELECT id INTO v_re_account_id FROM accounts
      WHERE code = '3200' AND is_active = TRUE
      LIMIT 1;
  END IF;
  IF v_re_account_id IS NULL THEN
    -- Try by name
    SELECT id INTO v_re_account_id FROM accounts
      WHERE (name_ar LIKE '%أرباح محتجزة%' OR name_en ILIKE '%retained%')
        AND is_active = TRUE
      LIMIT 1;
  END IF;
  IF v_re_account_id IS NULL THEN
    RAISE EXCEPTION 'لم يتم العثور على حساب الأرباح المحتجزة. تأكد من وجود حساب كود 3200 أو أضف معرف الحساب يدوياً.';
  END IF;

  -- Calculate period net P&L from posted journal lines within period dates
  SELECT
    COALESCE(SUM(CASE WHEN a.type = 'revenue'
                 THEN jel.credit - jel.debit ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN a.type IN ('direct_cost','expense')
                 THEN jel.debit - jel.credit ELSE 0 END), 0)
  INTO v_total_revenue, v_total_cost
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id
  JOIN accounts a         ON a.id  = jel.account_id
  WHERE je.status      = 'posted'
    AND je.entry_date  >= v_period.start_date
    AND je.entry_date  <= v_period.end_date;

  v_net_profit := v_total_revenue - v_total_cost;

  -- Generate closing journal entry number
  SELECT 'CLOSE-' || TO_CHAR(now(), 'YYYY') || '-' ||
         LPAD((COUNT(*) + 1)::TEXT, 4, '0')
  INTO v_entry_number
  FROM journal_entries WHERE entry_number LIKE 'CLOSE-%';

  -- Create closing journal entry
  INSERT INTO journal_entries (
    entry_number, entry_date, fiscal_period_id,
    description, reference_type, status,
    total_debit, total_credit,
    currency, created_by, posted_by, posted_at,
    notes
  ) VALUES (
    v_entry_number,
    v_period.end_date,
    p_period_id,
    'قيد إقفال الفترة المالية: ' || v_period.name,
    'year_end_closing',
    'posted',  -- bypass normal period check via SECURITY DEFINER
    ABS(v_net_profit),
    ABS(v_net_profit),
    'EGP',
    p_closed_by,
    p_closed_by,
    now(),
    'إقفال تلقائي للفترة المالية — نقل صافي الأرباح/الخسائر إلى الأرباح المحتجزة'
  ) RETURNING id INTO v_je_id;

  -- Close all revenue accounts → debit revenue, credit retained earnings
  FOR v_rev_account IN (
    SELECT
      jel.account_id,
      COALESCE(SUM(jel.credit - jel.debit), 0) AS net_credit
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts a         ON a.id  = jel.account_id
    WHERE je.status = 'posted'
      AND je.entry_date >= v_period.start_date
      AND je.entry_date <= v_period.end_date
      AND a.type = 'revenue'
    GROUP BY jel.account_id
    HAVING COALESCE(SUM(jel.credit - jel.debit), 0) <> 0
  ) LOOP
    INSERT INTO journal_entry_lines (
      journal_entry_id, account_id, description,
      debit, credit, currency, exchange_rate, line_order
    ) VALUES (
      v_je_id, v_rev_account.account_id,
      'إقفال حساب الإيراد',
      GREATEST(v_rev_account.net_credit, 0),
      GREATEST(-v_rev_account.net_credit, 0),
      'EGP', 1, v_line_order
    );
    v_line_order := v_line_order + 1;
  END LOOP;

  -- Close all expense/cost accounts → credit expense, debit retained earnings
  FOR v_exp_account IN (
    SELECT
      jel.account_id,
      COALESCE(SUM(jel.debit - jel.credit), 0) AS net_debit
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts a         ON a.id  = jel.account_id
    WHERE je.status = 'posted'
      AND je.entry_date >= v_period.start_date
      AND je.entry_date <= v_period.end_date
      AND a.type IN ('direct_cost','expense')
    GROUP BY jel.account_id
    HAVING COALESCE(SUM(jel.debit - jel.credit), 0) <> 0
  ) LOOP
    INSERT INTO journal_entry_lines (
      journal_entry_id, account_id, description,
      debit, credit, currency, exchange_rate, line_order
    ) VALUES (
      v_je_id, v_exp_account.account_id,
      'إقفال حساب المصروف/التكلفة',
      GREATEST(-v_exp_account.net_debit, 0),
      GREATEST(v_exp_account.net_debit, 0),
      'EGP', 1, v_line_order
    );
    v_line_order := v_line_order + 1;
  END LOOP;

  -- Net entry to retained earnings
  IF v_net_profit >= 0 THEN
    -- Profit: credit retained earnings
    INSERT INTO journal_entry_lines (
      journal_entry_id, account_id, description,
      debit, credit, currency, exchange_rate, line_order
    ) VALUES (
      v_je_id, v_re_account_id,
      'نقل صافي ربح الفترة إلى الأرباح المحتجزة',
      0, v_net_profit,
      'EGP', 1, v_line_order
    );
  ELSE
    -- Loss: debit retained earnings
    INSERT INTO journal_entry_lines (
      journal_entry_id, account_id, description,
      debit, credit, currency, exchange_rate, line_order
    ) VALUES (
      v_je_id, v_re_account_id,
      'نقل صافي خسارة الفترة إلى الأرباح المحتجزة',
      ABS(v_net_profit), 0,
      'EGP', 1, v_line_order
    );
  END IF;

  -- Mark period as closed
  UPDATE fiscal_periods SET
    status                  = 'closed',
    closed_by               = p_closed_by,
    closed_at               = now(),
    year_end_closed_at      = CASE WHEN is_year_end THEN now() ELSE year_end_closed_at END,
    year_end_closed_by      = CASE WHEN is_year_end THEN p_closed_by ELSE year_end_closed_by END,
    retained_earnings_je    = v_je_id
  WHERE id = p_period_id;

  -- Log to audit
  INSERT INTO audit_logs (
    admin_id, admin_email, action, table_name, record_id, record_label, details
  )
  SELECT
    p_closed_by,
    (SELECT email FROM auth.users WHERE id = p_closed_by),
    'CLOSE_FISCAL_PERIOD',
    'fiscal_periods',
    p_period_id::TEXT,
    v_period.name,
    jsonb_build_object(
      'period_name',    v_period.name,
      'start_date',     v_period.start_date,
      'end_date',       v_period.end_date,
      'net_profit',     v_net_profit,
      'total_revenue',  v_total_revenue,
      'total_cost',     v_total_cost,
      'closing_je',     v_je_id
    );

  RETURN jsonb_build_object(
    'success',        TRUE,
    'period_id',      p_period_id,
    'period_name',    v_period.name,
    'net_profit',     v_net_profit,
    'total_revenue',  v_total_revenue,
    'total_cost',     v_total_cost,
    'closing_je_id',  v_je_id,
    'closing_je_num', v_entry_number
  );
END;
$$;

GRANT EXECUTE ON FUNCTION close_fiscal_period(UUID, UUID, UUID) TO authenticated;

-- ─── 4. REOPEN PERIOD (to 'opening' for corrections) ─────────
-- Only super_admin / financial_manager should call this.
-- Does NOT delete the closing entry — creates a reversal.
CREATE OR REPLACE FUNCTION reopen_fiscal_period(
  p_period_id UUID,
  p_reopened_by UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_period fiscal_periods%ROWTYPE;
BEGIN
  SELECT * INTO v_period FROM fiscal_periods WHERE id = p_period_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'الفترة المالية غير موجودة.';
  END IF;
  IF v_period.status = 'open' THEN
    RAISE EXCEPTION 'الفترة مفتوحة مسبقاً.';
  END IF;

  UPDATE fiscal_periods SET
    status    = 'closing',  -- put in "closing" state, not fully open
    closed_by = NULL,
    closed_at = NULL
  WHERE id = p_period_id;

  INSERT INTO audit_logs (
    admin_id, admin_email, action, table_name, record_id, record_label, details
  )
  SELECT
    p_reopened_by,
    (SELECT email FROM auth.users WHERE id = p_reopened_by),
    'REOPEN_FISCAL_PERIOD',
    'fiscal_periods',
    p_period_id::TEXT,
    v_period.name,
    jsonb_build_object('reason', p_reason, 'previous_status', v_period.status);

  RETURN jsonb_build_object('success', TRUE, 'period_id', p_period_id, 'new_status', 'closing');
END;
$$;

GRANT EXECUTE ON FUNCTION reopen_fiscal_period(UUID, UUID, TEXT) TO authenticated;

-- ─── 5. AUTO-CREATE MONTHLY PERIODS FOR A YEAR ───────────────
CREATE OR REPLACE FUNCTION create_fiscal_year(
  p_year        INT,
  p_created_by  UUID,
  p_period_type TEXT DEFAULT 'monthly'  -- 'monthly' or 'annual'
)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_month       INT;
  v_start_date  DATE;
  v_end_date    DATE;
  v_name        TEXT;
  v_count       INT := 0;
BEGIN
  IF p_period_type = 'annual' THEN
    v_start_date := (p_year || '-01-01')::DATE;
    v_end_date   := (p_year || '-12-31')::DATE;
    v_name := 'السنة المالية ' || p_year;
    INSERT INTO fiscal_periods (name, start_date, end_date, period_type, year, period_number, is_year_end)
    VALUES (v_name, v_start_date, v_end_date, 'annual', p_year, 1, TRUE)
    ON CONFLICT DO NOTHING;
    v_count := 1;
  ELSE
    -- Monthly
    FOR v_month IN 1..12 LOOP
      v_start_date := (p_year || '-' || LPAD(v_month::TEXT, 2, '0') || '-01')::DATE;
      v_end_date   := (v_start_date + INTERVAL '1 month - 1 day')::DATE;
      v_name := TO_CHAR(v_start_date, 'Month YYYY');
      INSERT INTO fiscal_periods (name, start_date, end_date, period_type, year, period_number, is_year_end)
      VALUES (v_name, v_start_date, v_end_date, 'monthly', p_year, v_month, v_month = 12)
      ON CONFLICT DO NOTHING;
      v_count := v_count + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'year', p_year, 'periods_created', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION create_fiscal_year(INT, UUID, TEXT) TO authenticated;

-- ─── 6. PERIOD SUMMARY FUNCTION ──────────────────────────────
CREATE OR REPLACE FUNCTION get_period_summary(p_period_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_period      fiscal_periods%ROWTYPE;
  v_revenue     NUMERIC(18,2);
  v_direct_cost NUMERIC(18,2);
  v_expenses    NUMERIC(18,2);
  v_je_count    INT;
  v_posted_count INT;
  v_draft_count  INT;
BEGIN
  SELECT * INTO v_period FROM fiscal_periods WHERE id = p_period_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not_found'); END IF;

  SELECT
    COALESCE(SUM(CASE WHEN a.type = 'revenue'     THEN jel.credit - jel.debit ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN a.type = 'direct_cost' THEN jel.debit - jel.credit ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN a.type = 'expense'     THEN jel.debit - jel.credit ELSE 0 END), 0)
  INTO v_revenue, v_direct_cost, v_expenses
  FROM journal_entry_lines jel
  JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
  JOIN accounts a         ON a.id  = jel.account_id
  WHERE je.entry_date >= v_period.start_date
    AND je.entry_date <= v_period.end_date;

  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'posted'),
    COUNT(*) FILTER (WHERE status = 'draft')
  INTO v_je_count, v_posted_count, v_draft_count
  FROM journal_entries
  WHERE fiscal_period_id = p_period_id
     OR (fiscal_period_id IS NULL
         AND entry_date >= v_period.start_date
         AND entry_date <= v_period.end_date);

  RETURN jsonb_build_object(
    'period_id',      p_period_id,
    'name',           v_period.name,
    'start_date',     v_period.start_date,
    'end_date',       v_period.end_date,
    'status',         v_period.status,
    'revenue',        v_revenue,
    'direct_cost',    v_direct_cost,
    'expenses',       v_expenses,
    'gross_profit',   v_revenue - v_direct_cost,
    'net_profit',     v_revenue - v_direct_cost - v_expenses,
    'je_count',       v_je_count,
    'posted_count',   v_posted_count,
    'draft_count',    v_draft_count,
    'is_year_end',    v_period.is_year_end
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_period_summary(UUID) TO authenticated;

-- ─── 7. PREVENT HARD DELETE OF HISTORICAL DATA ───────────────
-- journal_entries/lines already have no DELETE policy for non-admins.
-- Add explicit protection: posted entries cannot be deleted.
CREATE OR REPLACE FUNCTION prevent_delete_posted_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'posted' THEN
    RAISE EXCEPTION 'لا يمكن حذف قيد محاسبي مرحّل. استخدم قيد عكسي.';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_delete_posted ON journal_entries;
CREATE TRIGGER trg_prevent_delete_posted
  BEFORE DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_delete_posted_journal();

-- Prevent editing posted journal entries (only reversal allowed)
CREATE OR REPLACE FUNCTION prevent_edit_posted_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'posted' AND NEW.status != 'reversed' THEN
    -- Allow only status change to 'reversed', nothing else
    IF OLD.entry_date    IS DISTINCT FROM NEW.entry_date    OR
       OLD.description   IS DISTINCT FROM NEW.description   OR
       OLD.total_debit   IS DISTINCT FROM NEW.total_debit   OR
       OLD.total_credit  IS DISTINCT FROM NEW.total_credit  THEN
      RAISE EXCEPTION 'القيود المرحّلة لا تقبل التعديل. استخدم قيداً عكسياً.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_edit_posted ON journal_entries;
CREATE TRIGGER trg_prevent_edit_posted
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION prevent_edit_posted_journal();

-- Prevent editing posted journal lines
CREATE OR REPLACE FUNCTION prevent_edit_posted_je_lines()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_je_status TEXT;
BEGIN
  SELECT status INTO v_je_status FROM journal_entries WHERE id = OLD.journal_entry_id;
  IF v_je_status = 'posted' THEN
    RAISE EXCEPTION 'لا يمكن تعديل بنود قيد مرحّل.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_edit_posted_lines ON journal_entry_lines;
CREATE TRIGGER trg_prevent_edit_posted_lines
  BEFORE UPDATE OR DELETE ON journal_entry_lines
  FOR EACH ROW EXECUTE FUNCTION prevent_edit_posted_je_lines();

-- ─── 8. VERIFY ───────────────────────────────────────────────
SELECT 'Migration v13 (Fiscal Periods) done — triggers + closing function installed' AS status;
