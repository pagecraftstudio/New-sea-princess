-- ══════════════════════════════════════════════════════════════
--  NSP Migration v9 — Cash / Bank / Wallet Transactions
--  Additive only — does NOT touch existing tables
--  Run in Supabase SQL Editor
-- ══════════════════════════════════════════════════════════════

-- ─── CASH TRANSACTIONS LOG ───────────────────────────────────
-- Records every deposit / withdrawal / transfer against a cash_account.
-- Transfers create TWO rows: one debit (source), one credit (dest).
CREATE TABLE IF NOT EXISTS cash_transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  txn_number       TEXT NOT NULL UNIQUE,
  txn_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  cash_account_id  UUID NOT NULL REFERENCES cash_accounts(id),
  type             TEXT NOT NULL CHECK (type IN ('deposit','withdrawal','transfer_in','transfer_out','opening','adjustment')),
  amount           NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  balance_after    NUMERIC(18,2),           -- snapshot after txn
  currency         TEXT DEFAULT 'EGP',
  exchange_rate    NUMERIC(18,6) DEFAULT 1,
  reference        TEXT,                    -- cheque #, transfer ref, etc.
  description      TEXT,
  counterpart_id   UUID REFERENCES cash_accounts(id),  -- for transfers
  journal_entry_id UUID REFERENCES journal_entries(id),
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cash_txns_account ON cash_transactions(cash_account_id);
CREATE INDEX IF NOT EXISTS idx_cash_txns_date    ON cash_transactions(txn_date);
ALTER TABLE cash_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON cash_transactions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── BANK RECONCILIATION LINES ───────────────────────────────
-- Each line links a book entry to a bank-statement line.
CREATE TABLE IF NOT EXISTS bank_recon_lines (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reconciliation_id     UUID NOT NULL REFERENCES bank_reconciliations(id) ON DELETE CASCADE,
  cash_transaction_id   UUID REFERENCES cash_transactions(id),
  statement_date        DATE,
  statement_description TEXT,
  statement_amount      NUMERIC(18,2),
  is_matched            BOOLEAN DEFAULT FALSE,
  created_at            TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE bank_recon_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON bank_recon_lines FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── FUNCTION: auto-update cash_accounts.current_balance ─────
CREATE OR REPLACE FUNCTION update_cash_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  delta NUMERIC(18,2);
BEGIN
  -- deposits / transfer_in / opening / adjustment increase balance
  IF NEW.type IN ('deposit','transfer_in','opening','adjustment') THEN
    delta := NEW.amount;
  ELSE
    delta := -NEW.amount;   -- withdrawal / transfer_out
  END IF;

  UPDATE cash_accounts
  SET current_balance = current_balance + delta
  WHERE id = NEW.cash_account_id;

  -- snapshot balance_after
  SELECT current_balance INTO NEW.balance_after
  FROM cash_accounts WHERE id = NEW.cash_account_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cash_balance ON cash_transactions;
CREATE TRIGGER trg_cash_balance
  BEFORE INSERT ON cash_transactions
  FOR EACH ROW EXECUTE FUNCTION update_cash_balance();

-- ─── FUNCTION: generate txn_number ───────────────────────────
CREATE OR REPLACE FUNCTION next_txn_number()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  seq INT;
BEGIN
  SELECT COALESCE(MAX(CAST(SUBSTRING(txn_number FROM 4) AS INT)), 0) + 1
  INTO seq FROM cash_transactions;
  RETURN 'TXN' || LPAD(seq::TEXT, 6, '0');
END;
$$;

-- ─── FUNCTION: atomic transfer between two accounts ──────────
CREATE OR REPLACE FUNCTION transfer_between_accounts(
  p_from_account  UUID,
  p_to_account    UUID,
  p_amount        NUMERIC,
  p_date          DATE,
  p_reference     TEXT,
  p_description   TEXT,
  p_created_by    UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from_bal NUMERIC;
  v_txn_out  TEXT;
  v_txn_in   TEXT;
BEGIN
  SELECT current_balance INTO v_from_bal FROM cash_accounts WHERE id = p_from_account FOR UPDATE;
  IF v_from_bal < p_amount THEN
    RAISE EXCEPTION 'رصيد غير كافٍ في الحساب المصدر';
  END IF;

  v_txn_out := next_txn_number();
  INSERT INTO cash_transactions
    (txn_number, txn_date, cash_account_id, type, amount, currency, reference, description, counterpart_id, created_by)
  VALUES
    (v_txn_out, p_date, p_from_account, 'transfer_out', p_amount, 'EGP', p_reference, p_description, p_to_account, p_created_by);

  v_txn_in := next_txn_number();
  INSERT INTO cash_transactions
    (txn_number, txn_date, cash_account_id, type, amount, currency, reference, description, counterpart_id, created_by)
  VALUES
    (v_txn_in, p_date, p_to_account, 'transfer_in', p_amount, 'EGP', p_reference, p_description, p_from_account, p_created_by);
END;
$$;

-- RLS grant for the functions (security definer not needed; called by admins)
GRANT EXECUTE ON FUNCTION transfer_between_accounts TO authenticated;
GRANT EXECUTE ON FUNCTION next_txn_number TO authenticated;
