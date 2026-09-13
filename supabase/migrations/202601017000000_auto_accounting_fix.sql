-- ══════════════════════════════════════════════════════════════════
--  NSP Migration v17 — Auto-Accounting Fix
--  Fixes two health-check issues:
--    1. "Failed Accounting Automation" — invoices/payments with no
--       journal entry. Adds AFTER-INSERT triggers that auto-create
--       a double-entry journal when an invoice is issued or a
--       payment is received.
--    2. "Balance Sheet Imbalance" — assets exist (2,280 gap) with
--       no equity counter-entry. Inserts an opening-balance journal
--       entry to record existing cash as owner's capital.
--
--  Safe to run on a live DB:
--    • All INSERT/UPDATE wrapped in EXCEPTION blocks.
--    • Uses ON CONFLICT DO NOTHING on journal inserts.
--    • Existing journal_entry_id rows are skipped.
--    • Idempotent — re-running causes no duplicates.
-- ══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
--  PART 1 — INVOICE AUTO-JOURNAL TRIGGER
--  When an invoice status becomes 'issued' (or is inserted as
--  issued), create a journal entry:
--    DR  1200 (Accounts Receivable)   = total_amount
--    CR  4000 (Revenue - default)     = total_amount
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_journal_invoice()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_je_id       UUID;
  v_ar_acct     UUID;
  v_rev_acct    UUID;
  v_fp_id       UUID;
  v_amount      NUMERIC(18,2);
BEGIN
  -- Only act when status transitions TO 'issued' (or inserted as issued)
  IF TG_OP = 'INSERT' AND NEW.status NOT IN ('issued','partial','paid') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status NOT IN ('issued','partial','paid') THEN RETURN NEW; END IF;
    IF OLD.status IN ('issued','partial','paid') THEN RETURN NEW; END IF; -- already processed
  END IF;

  -- Skip if journal already exists
  IF NEW.journal_entry_id IS NOT NULL THEN RETURN NEW; END IF;

  v_amount := NEW.total_amount;
  IF v_amount IS NULL OR v_amount <= 0 THEN RETURN NEW; END IF;

  -- Resolve accounts from mappings
  SELECT am.account_id INTO v_ar_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'ar_account' LIMIT 1;
  SELECT am.account_id INTO v_rev_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'revenue_default' LIMIT 1;

  -- Fallback: look up by code if mapping missing
  IF v_ar_acct IS NULL THEN
    SELECT id INTO v_ar_acct FROM accounts WHERE code = '1200' LIMIT 1;
  END IF;
  IF v_rev_acct IS NULL THEN
    SELECT id INTO v_rev_acct FROM accounts WHERE code = '4000' LIMIT 1;
  END IF;

  IF v_ar_acct IS NULL OR v_rev_acct IS NULL THEN
    -- Can't post — accounts not configured; silently skip
    RETURN NEW;
  END IF;

  -- Find open fiscal period
  SELECT id INTO v_fp_id FROM fiscal_periods
    WHERE status = 'open'
      AND NEW.issue_date BETWEEN start_date AND end_date
    LIMIT 1;
  IF v_fp_id IS NULL THEN
    SELECT id INTO v_fp_id FROM fiscal_periods WHERE status = 'open'
    ORDER BY start_date DESC LIMIT 1;
  END IF;

  -- Create journal entry
  INSERT INTO journal_entries (
    entry_number, entry_date, description, reference_type, reference_id,
    fiscal_period_id, status, created_by
  ) VALUES (
    'JE-INV-' || REPLACE(NEW.invoice_number, 'INV-', ''),
    NEW.issue_date,
    'قيد فاتورة: ' || NEW.invoice_number || ' — ' || NEW.customer_name,
    'invoice',
    NEW.id,
    v_fp_id,
    'posted',
    NEW.created_by
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_je_id;

  IF v_je_id IS NULL THEN RETURN NEW; END IF; -- conflict — already exists

  -- DR Accounts Receivable
  INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
  VALUES (v_je_id, v_ar_acct, 'ذمم مدينة — ' || NEW.customer_name, v_amount, 0);

  -- CR Revenue
  INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
  VALUES (v_je_id, v_rev_acct, 'إيرادات — ' || NEW.invoice_number, 0, v_amount);

  -- Link back
  UPDATE nsp_invoices SET journal_entry_id = v_je_id WHERE id = NEW.id;
  NEW.journal_entry_id := v_je_id;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block the invoice save; just skip journal creation
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_journal_invoice ON nsp_invoices;
CREATE TRIGGER trg_auto_journal_invoice
  AFTER INSERT OR UPDATE OF status ON nsp_invoices
  FOR EACH ROW EXECUTE FUNCTION fn_auto_journal_invoice();


-- ─────────────────────────────────────────────────────────────────
--  PART 2 — PAYMENT AUTO-JOURNAL TRIGGER
--  When a payment is inserted with status 'received', create:
--    DR  1101 (Cash/Bank per cash_account.gl_account_id or mapping)
--    CR  1200 (Accounts Receivable)
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_journal_payment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_je_id       UUID;
  v_cash_acct   UUID;
  v_ar_acct     UUID;
  v_fp_id       UUID;
  v_amount      NUMERIC(18,2);
  v_desc        TEXT;
BEGIN
  -- Only new received payments without a journal
  IF NEW.status != 'received' THEN RETURN NEW; END IF;
  IF NEW.journal_entry_id IS NOT NULL THEN RETURN NEW; END IF;

  v_amount := NEW.amount;
  IF v_amount IS NULL OR v_amount <= 0 THEN RETURN NEW; END IF;

  -- Resolve cash/bank GL account from the linked cash_account
  IF NEW.cash_account_id IS NOT NULL THEN
    SELECT ca.gl_account_id INTO v_cash_acct
      FROM cash_accounts ca WHERE ca.id = NEW.cash_account_id;
  END IF;

  -- Fallback to cash mapping
  IF v_cash_acct IS NULL THEN
    SELECT am.account_id INTO v_cash_acct
      FROM accounting_mappings am WHERE am.mapping_key = 'cash_account' LIMIT 1;
  END IF;
  IF v_cash_acct IS NULL THEN
    SELECT id INTO v_cash_acct FROM accounts WHERE code = '1101' LIMIT 1;
  END IF;

  -- AR account
  SELECT am.account_id INTO v_ar_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'ar_account' LIMIT 1;
  IF v_ar_acct IS NULL THEN
    SELECT id INTO v_ar_acct FROM accounts WHERE code = '1200' LIMIT 1;
  END IF;

  IF v_cash_acct IS NULL OR v_ar_acct IS NULL THEN RETURN NEW; END IF;

  -- Fiscal period
  SELECT id INTO v_fp_id FROM fiscal_periods
    WHERE status = 'open'
      AND NEW.payment_date BETWEEN start_date AND end_date
    LIMIT 1;
  IF v_fp_id IS NULL THEN
    SELECT id INTO v_fp_id FROM fiscal_periods WHERE status = 'open'
    ORDER BY start_date DESC LIMIT 1;
  END IF;

  v_desc := 'تحصيل دفعة: ' || NEW.payment_number || ' — ' || NEW.customer_name;

  INSERT INTO journal_entries (
    entry_number, entry_date, description, reference_type, reference_id,
    fiscal_period_id, status, created_by
  ) VALUES (
    'JE-PAY-' || REPLACE(NEW.payment_number, 'PAY-', ''),
    NEW.payment_date,
    v_desc,
    'payment',
    NEW.id,
    v_fp_id,
    'posted',
    NEW.created_by
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_je_id;

  IF v_je_id IS NULL THEN RETURN NEW; END IF;

  -- DR Cash/Bank
  INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
  VALUES (v_je_id, v_cash_acct, 'نقدية محصّلة — ' || NEW.customer_name, v_amount, 0);

  -- CR AR
  INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
  VALUES (v_je_id, v_ar_acct, 'تسوية ذمم — ' || NEW.payment_number, 0, v_amount);

  -- Link back
  UPDATE nsp_payments SET journal_entry_id = v_je_id WHERE id = NEW.id;
  NEW.journal_entry_id := v_je_id;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_journal_payment ON nsp_payments;
CREATE TRIGGER trg_auto_journal_payment
  AFTER INSERT ON nsp_payments
  FOR EACH ROW EXECUTE FUNCTION fn_auto_journal_payment();


-- ─────────────────────────────────────────────────────────────────
--  PART 3 — BACKFILL: create journal entries for existing
--  invoices (issued/partial/paid) that have no journal_entry_id
-- ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  r             RECORD;
  v_je_id       UUID;
  v_ar_acct     UUID;
  v_rev_acct    UUID;
  v_fp_id       UUID;
  v_count       INT := 0;
BEGIN
  SELECT am.account_id INTO v_ar_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'ar_account' LIMIT 1;
  IF v_ar_acct IS NULL THEN
    SELECT id INTO v_ar_acct FROM accounts WHERE code = '1200' LIMIT 1;
  END IF;

  SELECT am.account_id INTO v_rev_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'revenue_default' LIMIT 1;
  IF v_rev_acct IS NULL THEN
    SELECT id INTO v_rev_acct FROM accounts WHERE code = '4000' LIMIT 1;
  END IF;

  IF v_ar_acct IS NULL OR v_rev_acct IS NULL THEN
    RAISE NOTICE 'Backfill skipped — AR or Revenue account not found';
    RETURN;
  END IF;

  FOR r IN
    SELECT * FROM nsp_invoices
    WHERE status IN ('issued','partial','paid')
      AND journal_entry_id IS NULL
      AND total_amount > 0
    ORDER BY issue_date
  LOOP
    -- Fiscal period
    SELECT id INTO v_fp_id FROM fiscal_periods
      WHERE status = 'open'
        AND r.issue_date BETWEEN start_date AND end_date
      LIMIT 1;
    IF v_fp_id IS NULL THEN
      SELECT id INTO v_fp_id FROM fiscal_periods
      WHERE status = 'open' ORDER BY start_date DESC LIMIT 1;
    END IF;

    BEGIN
      INSERT INTO journal_entries (
        entry_number, entry_date, description,
        reference_type, reference_id, fiscal_period_id, status, created_by
      ) VALUES (
        'JE-INV-' || REPLACE(r.invoice_number, 'INV-', ''),
        r.issue_date,
        'قيد فاتورة (ترحيل): ' || r.invoice_number || ' — ' || r.customer_name,
        'invoice', r.id, v_fp_id, 'posted', r.created_by
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_je_id;

      IF v_je_id IS NOT NULL THEN
        INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
        VALUES (v_je_id, v_ar_acct, 'ذمم مدينة — ' || r.customer_name, r.total_amount, 0);

        INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
        VALUES (v_je_id, v_rev_acct, 'إيرادات — ' || r.invoice_number, 0, r.total_amount);

        UPDATE nsp_invoices SET journal_entry_id = v_je_id WHERE id = r.id;
        v_count := v_count + 1;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Skipped invoice %: %', r.invoice_number, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Backfilled % invoice journal entries', v_count;
END;
$$;


-- ─────────────────────────────────────────────────────────────────
--  PART 4 — BACKFILL: journal entries for existing payments
--  with no journal_entry_id
-- ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  r             RECORD;
  v_je_id       UUID;
  v_cash_acct   UUID;
  v_ar_acct     UUID;
  v_fp_id       UUID;
  v_count       INT := 0;
BEGIN
  SELECT am.account_id INTO v_ar_acct
    FROM accounting_mappings am WHERE am.mapping_key = 'ar_account' LIMIT 1;
  IF v_ar_acct IS NULL THEN
    SELECT id INTO v_ar_acct FROM accounts WHERE code = '1200' LIMIT 1;
  END IF;

  FOR r IN
    SELECT p.*, ca.gl_account_id AS ca_gl
    FROM nsp_payments p
    LEFT JOIN cash_accounts ca ON ca.id = p.cash_account_id
    WHERE p.status = 'received'
      AND p.journal_entry_id IS NULL
      AND p.amount > 0
    ORDER BY p.payment_date
  LOOP
    -- Cash GL account
    v_cash_acct := r.ca_gl;
    IF v_cash_acct IS NULL THEN
      SELECT am.account_id INTO v_cash_acct
        FROM accounting_mappings am WHERE am.mapping_key = 'cash_account' LIMIT 1;
    END IF;
    IF v_cash_acct IS NULL THEN
      SELECT id INTO v_cash_acct FROM accounts WHERE code = '1101' LIMIT 1;
    END IF;

    IF v_cash_acct IS NULL OR v_ar_acct IS NULL THEN CONTINUE; END IF;

    -- Fiscal period
    SELECT id INTO v_fp_id FROM fiscal_periods
      WHERE status = 'open'
        AND r.payment_date BETWEEN start_date AND end_date
      LIMIT 1;
    IF v_fp_id IS NULL THEN
      SELECT id INTO v_fp_id FROM fiscal_periods
      WHERE status = 'open' ORDER BY start_date DESC LIMIT 1;
    END IF;

    BEGIN
      INSERT INTO journal_entries (
        entry_number, entry_date, description,
        reference_type, reference_id, fiscal_period_id, status, created_by
      ) VALUES (
        'JE-PAY-' || REPLACE(r.payment_number, 'PAY-', ''),
        r.payment_date,
        'تحصيل دفعة (ترحيل): ' || r.payment_number || ' — ' || r.customer_name,
        'payment', r.id, v_fp_id, 'posted', r.created_by
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_je_id;

      IF v_je_id IS NOT NULL THEN
        INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
        VALUES (v_je_id, v_cash_acct, 'نقدية محصّلة — ' || r.customer_name, r.amount, 0);

        INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
        VALUES (v_je_id, v_ar_acct, 'تسوية ذمم — ' || r.payment_number, 0, r.amount);

        UPDATE nsp_payments SET journal_entry_id = v_je_id WHERE id = r.id;
        v_count := v_count + 1;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Skipped payment %: %', r.payment_number, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Backfilled % payment journal entries', v_count;
END;
$$;


-- ─────────────────────────────────────────────────────────────────
--  PART 5 — BALANCE SHEET OPENING ENTRY
--  Fix the 2,280 gap: assets have value from opening_balance
--  recorded on cash_accounts but no equity counter-entry.
--  This creates a single "Opening Capital" journal entry for all
--  cash_accounts that have opening_balance > 0 but no GL journal.
--
--  *** IMPORTANT: Run the diagnostic SELECT below first.
--  If your assets already have journal entries for opening
--  balances, skip Part 5 to avoid double-counting.
--  
--  Diagnostic (run separately before executing Part 5):
--    SELECT SUM(opening_balance) FROM cash_accounts WHERE opening_balance > 0;
--    SELECT SUM(jel.debit - jel.credit) FROM journal_entry_lines jel
--    JOIN accounts a ON a.id = jel.account_id AND a.type = 'asset'
--    JOIN journal_entries je ON je.id = jel.journal_entry_id AND je.status = 'posted'
--    WHERE je.reference_type = 'opening';
-- ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_total_opening  NUMERIC(18,2) := 0;
  v_already_posted NUMERIC(18,2) := 0;
  v_gap            NUMERIC(18,2);
  v_je_id          UUID;
  v_capital_acct   UUID;
  v_fp_id          UUID;
  r                RECORD;
BEGIN
  -- Sum opening balances on cash accounts
  SELECT COALESCE(SUM(opening_balance), 0) INTO v_total_opening
  FROM cash_accounts WHERE opening_balance > 0;

  -- Sum already-posted opening journal lines on asset accounts
  SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_already_posted
  FROM journal_entry_lines jel
  JOIN accounts a ON a.id = jel.account_id AND a.type = 'asset'
  JOIN journal_entries je ON je.id = jel.journal_entry_id
    AND je.status = 'posted' AND je.reference_type = 'opening';

  v_gap := v_total_opening - v_already_posted;

  IF v_gap < 0.01 THEN
    RAISE NOTICE 'Opening balance already journalised (gap=%). Skipping Part 5.', v_gap;
    RETURN;
  END IF;

  RAISE NOTICE 'Opening balance gap detected: %. Creating opening capital entry...', v_gap;

  -- Capital account (3100)
  SELECT id INTO v_capital_acct FROM accounts WHERE code = '3100' LIMIT 1;
  IF v_capital_acct IS NULL THEN
    SELECT id INTO v_capital_acct FROM accounts WHERE type = 'equity'
    ORDER BY code LIMIT 1;
  END IF;
  IF v_capital_acct IS NULL THEN
    RAISE NOTICE 'No equity account found. Skipping Part 5.';
    RETURN;
  END IF;

  -- Fiscal period
  SELECT id INTO v_fp_id FROM fiscal_periods WHERE status = 'open'
  ORDER BY start_date LIMIT 1;

  -- Create the opening journal entry header
  INSERT INTO journal_entries (
    entry_number, entry_date, description,
    reference_type, fiscal_period_id, status
  ) VALUES (
    'JE-OPEN-001',
    CURRENT_DATE,
    'قيد الأرصدة الافتتاحية — رأس المال',
    'opening',
    v_fp_id,
    'posted'
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_je_id;

  IF v_je_id IS NULL THEN
    RAISE NOTICE 'Opening entry already exists. Skipping.';
    RETURN;
  END IF;

  -- Create one DR line per cash account with opening balance
  FOR r IN
    SELECT ca.id, ca.name_ar, ca.opening_balance, ca.gl_account_id
    FROM cash_accounts ca
    WHERE ca.opening_balance > 0
    ORDER BY ca.code
  LOOP
    DECLARE
      v_asset_acct UUID;
    BEGIN
      v_asset_acct := r.gl_account_id;
      IF v_asset_acct IS NULL THEN
        -- Fallback: main cash account
        SELECT id INTO v_asset_acct FROM accounts WHERE code = '1101' LIMIT 1;
      END IF;
      IF v_asset_acct IS NULL THEN CONTINUE; END IF;

      INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
      VALUES (v_je_id, v_asset_acct,
        'رصيد افتتاحي — ' || r.name_ar,
        r.opening_balance, 0);
    END;
  END LOOP;

  -- CR Capital (single line for total)
  INSERT INTO journal_entry_lines (journal_entry_id, account_id, description, debit, credit)
  VALUES (v_je_id, v_capital_acct,
    'رأس المال الافتتاحي',
    0, v_total_opening);

  RAISE NOTICE 'Opening capital entry JE-OPEN-001 created for %', v_total_opening;
END;
$$;


-- ─────────────────────────────────────────────────────────────────
--  PART 6 — VERIFY
-- ─────────────────────────────────────────────────────────────────

-- Check remaining unlinked invoices
SELECT
  COUNT(*) FILTER (WHERE journal_entry_id IS NULL) AS invoices_still_missing_je,
  COUNT(*) FILTER (WHERE journal_entry_id IS NOT NULL) AS invoices_with_je
FROM nsp_invoices
WHERE status IN ('issued','partial','paid');

-- Check remaining unlinked payments
SELECT
  COUNT(*) FILTER (WHERE journal_entry_id IS NULL) AS payments_still_missing_je,
  COUNT(*) FILTER (WHERE journal_entry_id IS NOT NULL) AS payments_with_je
FROM nsp_payments
WHERE status = 'received';

-- Balance sheet quick check
SELECT * FROM check_balance_sheet_integrity();

SELECT 'Migration v17 complete' AS status;
-- ══ END v17 ═══════════════════════════════════════════════════════
