-- ══════════════════════════════════════════════════════════════
--  NSP Migration v15 — Audit Trail & Approval Workflows
--  Implements Section 15 of the ERP spec:
--    • accounting_settings (incl. high-value threshold)
--    • refunds table (was missing from all prior migrations)
--    • Auto-audit triggers on all financial tables
--    • Approval RPCs: submit/approve/reject for expenses,
--      credit_notes, refunds
--    • Immutability guards on posted/approved records
--    • High-value approval flag + RPC
--  Safe additive — run after v14.
-- ══════════════════════════════════════════════════════════════

-- ─── 1. ACCOUNTING SETTINGS ───────────────────────────────────
-- Central config table for accounting behaviour flags.
CREATE TABLE IF NOT EXISTS accounting_settings (
  key         TEXT PRIMARY KEY,
  value       JSONB NOT NULL DEFAULT 'null',
  description TEXT,
  updated_by  UUID REFERENCES auth.users(id),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE accounting_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "fin_read_settings"  ON accounting_settings;
DROP POLICY IF EXISTS "fin_write_settings" ON accounting_settings;

CREATE POLICY "fin_read_settings" ON accounting_settings FOR SELECT
  USING (can_read_financial());
CREATE POLICY "fin_write_settings" ON accounting_settings FOR ALL
  USING (can_approve_financial());

-- Seed defaults
INSERT INTO accounting_settings (key, value, description) VALUES
  ('high_value_threshold',    '10000',         'Transactions above this amount (base currency) require financial_manager approval'),
  ('base_currency',           '"EGP"',         'Base reporting currency'),
  ('require_expense_approval','true',           'Expenses must be approved before posting'),
  ('require_refund_approval', 'true',           'Refunds must be approved before posting'),
  ('require_cn_approval',     'true',           'Credit/debit notes must be approved before posting'),
  ('auto_post_payments',      'false',          'Auto-post journal entries when payments are recorded'),
  ('fiscal_year_start_month', '1',             'Month number (1=Jan) when fiscal year starts'),
  ('default_payment_terms',   '30',            'Default payment terms in days')
ON CONFLICT (key) DO NOTHING;

-- ─── 2. REFUNDS TABLE ─────────────────────────────────────────
-- Was referenced in v14 RLS policies but never created.
CREATE TABLE IF NOT EXISTS refunds (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_number    TEXT NOT NULL UNIQUE,
  invoice_id       UUID REFERENCES nsp_invoices(id),
  payment_id       UUID REFERENCES nsp_payments(id),
  booking_id       UUID REFERENCES bookings(id),
  customer_id      UUID REFERENCES auth.users(id),
  customer_name    TEXT NOT NULL,
  amount           NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  currency         TEXT NOT NULL DEFAULT 'EGP',
  exchange_rate    NUMERIC(18,6) NOT NULL DEFAULT 1,
  base_amount      NUMERIC(18,2) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  refund_method    TEXT DEFAULT 'cash' CHECK (refund_method IN ('cash','bank','wallet','reversal')),
  payment_account_id UUID REFERENCES cash_accounts(id),
  reason           TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','submitted','approved','posted','rejected','cancelled')),
  journal_entry_id UUID REFERENCES journal_entries(id),
  submitted_by     UUID REFERENCES auth.users(id),
  submitted_at     TIMESTAMPTZ,
  approved_by      UUID REFERENCES auth.users(id),
  approved_at      TIMESTAMPTZ,
  rejected_by      UUID REFERENCES auth.users(id),
  rejected_at      TIMESTAMPTZ,
  rejection_reason TEXT,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_refunds_invoice   ON refunds(invoice_id);
CREATE INDEX IF NOT EXISTS idx_refunds_customer  ON refunds(customer_id);
CREATE INDEX IF NOT EXISTS idx_refunds_status    ON refunds(status);
CREATE INDEX IF NOT EXISTS idx_refunds_created   ON refunds(created_at);

ALTER TABLE refunds ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "refund_read"    ON refunds;
DROP POLICY IF EXISTS "refund_write"   ON refunds;
DROP POLICY IF EXISTS "refund_approve" ON refunds;

CREATE POLICY "refund_read"    ON refunds FOR SELECT
  USING (can_read_financial() OR can_read_bookings());
CREATE POLICY "refund_write"   ON refunds FOR INSERT
  WITH CHECK (can_write_financial());
CREATE POLICY "refund_approve" ON refunds FOR UPDATE
  USING (can_write_financial());  -- approve RPC enforces can_approve_financial internally

-- Auto refund number
CREATE SEQUENCE IF NOT EXISTS ref_seq START 1;

CREATE OR REPLACE FUNCTION set_refund_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.refund_number IS NULL OR NEW.refund_number = '' THEN
    NEW.refund_number := 'REF-' || TO_CHAR(now(), 'YYYY') || '-'
                         || LPAD(nextval('ref_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_refund_number ON refunds;
CREATE TRIGGER trg_refund_number
  BEFORE INSERT ON refunds
  FOR EACH ROW EXECUTE FUNCTION set_refund_number();

-- ─── 3. ENHANCE accounting_audit_logs ────────────────────────
-- Add missing columns if not present (safe additive).
ALTER TABLE accounting_audit_logs
  ADD COLUMN IF NOT EXISTS ip_address   TEXT,
  ADD COLUMN IF NOT EXISTS user_agent   TEXT,
  ADD COLUMN IF NOT EXISTS entity_ref   TEXT;  -- human-readable ref (e.g. EXP-2025-0012)

-- ─── 4. GENERIC AUDIT LOGGER FUNCTION ────────────────────────
-- Called by triggers on all financial tables.
CREATE OR REPLACE FUNCTION fn_audit_financial()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_action TEXT;
  v_before JSONB;
  v_after  JSONB;
  v_ref    TEXT;
BEGIN
  v_action := TG_OP;                          -- INSERT / UPDATE / DELETE

  IF TG_OP = 'DELETE' THEN
    v_before := to_jsonb(OLD);
    v_after  := NULL;
    -- Try to get a human ref from common columns
    v_ref := COALESCE(
      OLD.entry_number, OLD.invoice_number, OLD.expense_number,
      OLD.payment_number, OLD.note_number, OLD.refund_number,
      OLD.id::TEXT
    );
  ELSIF TG_OP = 'INSERT' THEN
    v_before := NULL;
    v_after  := to_jsonb(NEW);
    v_ref := COALESCE(
      NEW.entry_number, NEW.invoice_number, NEW.expense_number,
      NEW.payment_number, NEW.note_number, NEW.refund_number,
      NEW.id::TEXT
    );
  ELSE -- UPDATE
    v_before := to_jsonb(OLD);
    v_after  := to_jsonb(NEW);
    v_ref := COALESCE(
      NEW.entry_number, NEW.invoice_number, NEW.expense_number,
      NEW.payment_number, NEW.note_number, NEW.refund_number,
      NEW.id::TEXT
    );
  END IF;

  INSERT INTO accounting_audit_logs
    (user_id, action, entity_type, entity_id, before_data, after_data, entity_ref)
  VALUES
    (auth.uid(), v_action, TG_TABLE_NAME,
     COALESCE(NEW.id, OLD.id), v_before, v_after, v_ref);

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach audit trigger to all key financial tables
DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'journal_entries','nsp_invoices','nsp_payments','nsp_expenses',
    'credit_notes','refunds','payment_allocations','bank_reconciliations'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%I ON %I', tbl, tbl);
    EXECUTE format(
      'CREATE TRIGGER trg_audit_%I
       AFTER INSERT OR UPDATE OR DELETE ON %I
       FOR EACH ROW EXECUTE FUNCTION fn_audit_financial()',
      tbl, tbl
    );
  END LOOP;
END $$;

-- ─── 5. IMMUTABILITY GUARDS ───────────────────────────────────

-- 5a. Prevent editing posted nsp_expenses
CREATE OR REPLACE FUNCTION guard_expense_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'posted' AND NEW.status != 'posted' THEN
    RAISE EXCEPTION 'Cannot change status of a posted expense (%). Create a reversal entry.', OLD.expense_number;
  END IF;
  IF OLD.status = 'posted' AND (
    NEW.amount        != OLD.amount OR
    NEW.account_id    IS DISTINCT FROM OLD.account_id OR
    NEW.expense_date  != OLD.expense_date
  ) THEN
    RAISE EXCEPTION 'Cannot modify posted expense (%). Create a reversal entry.', OLD.expense_number;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_expense ON nsp_expenses;
CREATE TRIGGER trg_guard_expense
  BEFORE UPDATE ON nsp_expenses
  FOR EACH ROW EXECUTE FUNCTION guard_expense_immutability();

-- 5b. Prevent editing approved/posted credit_notes
CREATE OR REPLACE FUNCTION guard_credit_note_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('approved','applied') AND NEW.status NOT IN ('applied','cancelled') THEN
    RAISE EXCEPTION 'Cannot modify approved credit/debit note (%). Reverse it instead.', OLD.note_number;
  END IF;
  IF OLD.status IN ('approved','applied') AND NEW.amount != OLD.amount THEN
    RAISE EXCEPTION 'Cannot change amount of approved credit/debit note (%).', OLD.note_number;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_credit_note ON credit_notes;
CREATE TRIGGER trg_guard_credit_note
  BEFORE UPDATE ON credit_notes
  FOR EACH ROW EXECUTE FUNCTION guard_credit_note_immutability();

-- 5c. Prevent editing approved/posted refunds
CREATE OR REPLACE FUNCTION guard_refund_immutability()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IN ('approved','posted') AND NEW.amount != OLD.amount THEN
    RAISE EXCEPTION 'Cannot modify amount of % refund (%).', OLD.status, OLD.refund_number;
  END IF;
  IF OLD.status = 'posted' AND NEW.status NOT IN ('posted','cancelled') THEN
    RAISE EXCEPTION 'Cannot change status of posted refund (%). Create a correction entry.', OLD.refund_number;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_refund ON refunds;
CREATE TRIGGER trg_guard_refund
  BEFORE UPDATE ON refunds
  FOR EACH ROW EXECUTE FUNCTION guard_refund_immutability();

-- ─── 6. HIGH-VALUE FLAG ───────────────────────────────────────
-- Adds requires_approval column to flag transactions exceeding threshold.
ALTER TABLE nsp_expenses   ADD COLUMN IF NOT EXISTS requires_approval BOOLEAN DEFAULT FALSE;
ALTER TABLE credit_notes   ADD COLUMN IF NOT EXISTS requires_approval BOOLEAN DEFAULT FALSE;
ALTER TABLE refunds        ADD COLUMN IF NOT EXISTS requires_approval BOOLEAN DEFAULT FALSE;

CREATE OR REPLACE FUNCTION fn_flag_high_value()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_threshold NUMERIC;
BEGIN
  SELECT (value #>> '{}')::NUMERIC
    INTO v_threshold
    FROM accounting_settings
   WHERE key = 'high_value_threshold';

  v_threshold := COALESCE(v_threshold, 10000);

  NEW.requires_approval := (NEW.total_amount * COALESCE(NEW.exchange_rate, 1)) >= v_threshold
                            OR NEW.requires_approval;
  RETURN NEW;
END;
$$;

-- High-value trigger for expenses
DROP TRIGGER IF EXISTS trg_hv_expense ON nsp_expenses;
CREATE TRIGGER trg_hv_expense
  BEFORE INSERT OR UPDATE ON nsp_expenses
  FOR EACH ROW EXECUTE FUNCTION fn_flag_high_value();

-- High-value for refunds (uses amount not total_amount — adapt fn)
CREATE OR REPLACE FUNCTION fn_flag_high_value_refund()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_threshold NUMERIC;
BEGIN
  SELECT (value #>> '{}')::NUMERIC INTO v_threshold
    FROM accounting_settings WHERE key = 'high_value_threshold';
  v_threshold := COALESCE(v_threshold, 10000);
  NEW.requires_approval := (NEW.amount * COALESCE(NEW.exchange_rate, 1)) >= v_threshold;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hv_refund ON refunds;
CREATE TRIGGER trg_hv_refund
  BEFORE INSERT OR UPDATE ON refunds
  FOR EACH ROW EXECUTE FUNCTION fn_flag_high_value_refund();

-- High-value for credit_notes
CREATE OR REPLACE FUNCTION fn_flag_high_value_cn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_threshold NUMERIC;
BEGIN
  SELECT (value #>> '{}')::NUMERIC INTO v_threshold
    FROM accounting_settings WHERE key = 'high_value_threshold';
  v_threshold := COALESCE(v_threshold, 10000);
  NEW.requires_approval := NEW.amount >= v_threshold;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hv_cn ON credit_notes;
CREATE TRIGGER trg_hv_cn
  BEFORE INSERT OR UPDATE ON credit_notes
  FOR EACH ROW EXECUTE FUNCTION fn_flag_high_value_cn();

-- ─── 7. APPROVAL RPCs ─────────────────────────────────────────

-- Ensure submitted_by / submitted_at exist before RPCs reference them
ALTER TABLE nsp_expenses ADD COLUMN IF NOT EXISTS submitted_by UUID REFERENCES auth.users(id);
ALTER TABLE nsp_expenses ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ;

-- 7a. EXPENSE: submit
CREATE OR REPLACE FUNCTION submit_expense(p_expense_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_exp nsp_expenses%ROWTYPE;
BEGIN
  SELECT * INTO v_exp FROM nsp_expenses WHERE id = p_expense_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Expense not found');
  END IF;
  IF v_exp.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error', 'Only draft expenses can be submitted. Current status: ' || v_exp.status);
  END IF;

  UPDATE nsp_expenses
     SET status = 'submitted', submitted_by = auth.uid(), submitted_at = now()
   WHERE id = p_expense_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, after_data)
  VALUES (auth.uid(), 'SUBMIT', 'nsp_expenses', p_expense_id, v_exp.expense_number,
          json_build_object('status','submitted')::jsonb);

  RETURN json_build_object('ok', true, 'expense_number', v_exp.expense_number);
END;
$$;

-- 7b. EXPENSE: approve
CREATE OR REPLACE FUNCTION approve_expense(p_expense_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_exp nsp_expenses%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions — financial_manager or super_admin required');
  END IF;

  SELECT * INTO v_exp FROM nsp_expenses WHERE id = p_expense_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Expense not found');
  END IF;
  IF v_exp.status NOT IN ('submitted','draft') THEN
    RETURN json_build_object('ok', false, 'error', 'Expense cannot be approved in status: ' || v_exp.status);
  END IF;

  UPDATE nsp_expenses
     SET status = 'approved', approved_by = auth.uid(), approved_at = now()
   WHERE id = p_expense_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, before_data, after_data)
  VALUES (auth.uid(), 'APPROVE', 'nsp_expenses', p_expense_id, v_exp.expense_number,
          json_build_object('status', v_exp.status)::jsonb,
          json_build_object('status','approved')::jsonb);

  RETURN json_build_object('ok', true, 'expense_number', v_exp.expense_number);
END;
$$;

-- 7c. EXPENSE: reject
CREATE OR REPLACE FUNCTION reject_expense(p_expense_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_exp nsp_expenses%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT * INTO v_exp FROM nsp_expenses WHERE id = p_expense_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Expense not found');
  END IF;
  IF v_exp.status NOT IN ('submitted','draft') THEN
    RETURN json_build_object('ok', false, 'error', 'Cannot reject expense in status: ' || v_exp.status);
  END IF;

  UPDATE nsp_expenses
     SET status = 'rejected'
   WHERE id = p_expense_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, before_data, after_data, reason)
  VALUES (auth.uid(), 'REJECT', 'nsp_expenses', p_expense_id, v_exp.expense_number,
          json_build_object('status', v_exp.status)::jsonb,
          json_build_object('status','rejected')::jsonb,
          p_reason);

  RETURN json_build_object('ok', true);
END;
$$;

-- 7d. CREDIT NOTE: approve
CREATE OR REPLACE FUNCTION approve_credit_note(p_note_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cn credit_notes%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT * INTO v_cn FROM credit_notes WHERE id = p_note_id;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Credit/debit note not found');
  END IF;
  IF v_cn.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error', 'Note is not in draft status: ' || v_cn.status);
  END IF;

  UPDATE credit_notes
     SET status = 'approved', approved_by = auth.uid(), approved_at = now()
   WHERE id = p_note_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, before_data, after_data)
  VALUES (auth.uid(), 'APPROVE', 'credit_notes', p_note_id, v_cn.note_number,
          json_build_object('status','draft')::jsonb,
          json_build_object('status','approved')::jsonb);

  RETURN json_build_object('ok', true, 'note_number', v_cn.note_number);
END;
$$;

-- 7e. CREDIT NOTE: reject
CREATE OR REPLACE FUNCTION reject_credit_note(p_note_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cn credit_notes%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT * INTO v_cn FROM credit_notes WHERE id = p_note_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Not found'); END IF;
  IF v_cn.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error', 'Cannot reject in status: ' || v_cn.status);
  END IF;

  -- credit_notes has no rejected status — cancel it
  UPDATE credit_notes SET status = 'cancelled' WHERE id = p_note_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, reason)
  VALUES (auth.uid(), 'REJECT', 'credit_notes', p_note_id, v_cn.note_number, p_reason);

  RETURN json_build_object('ok', true);
END;
$$;

-- 7f. REFUND: submit
CREATE OR REPLACE FUNCTION submit_refund(p_refund_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ref refunds%ROWTYPE;
BEGIN
  SELECT * INTO v_ref FROM refunds WHERE id = p_refund_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Refund not found'); END IF;
  IF v_ref.status != 'draft' THEN
    RETURN json_build_object('ok', false, 'error', 'Only draft refunds can be submitted');
  END IF;

  UPDATE refunds
     SET status = 'submitted', submitted_by = auth.uid(), submitted_at = now()
   WHERE id = p_refund_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, after_data)
  VALUES (auth.uid(), 'SUBMIT', 'refunds', p_refund_id, v_ref.refund_number,
          json_build_object('status','submitted')::jsonb);

  RETURN json_build_object('ok', true, 'refund_number', v_ref.refund_number);
END;
$$;

-- 7g. REFUND: approve
CREATE OR REPLACE FUNCTION approve_refund(p_refund_id UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ref refunds%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT * INTO v_ref FROM refunds WHERE id = p_refund_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Refund not found'); END IF;
  IF v_ref.status NOT IN ('draft','submitted') THEN
    RETURN json_build_object('ok', false, 'error', 'Cannot approve refund in status: ' || v_ref.status);
  END IF;

  -- Validate the refund amount doesn't exceed original payment
  IF v_ref.payment_id IS NOT NULL THEN
    PERFORM 1 FROM nsp_payments
     WHERE id = v_ref.payment_id
       AND amount >= v_ref.amount;
    IF NOT FOUND THEN
      RETURN json_build_object('ok', false, 'error', 'Refund amount exceeds original payment amount');
    END IF;
  END IF;

  UPDATE refunds
     SET status = 'approved', approved_by = auth.uid(), approved_at = now()
   WHERE id = p_refund_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, before_data, after_data)
  VALUES (auth.uid(), 'APPROVE', 'refunds', p_refund_id, v_ref.refund_number,
          json_build_object('status', v_ref.status)::jsonb,
          json_build_object('status','approved')::jsonb);

  RETURN json_build_object('ok', true, 'refund_number', v_ref.refund_number);
END;
$$;

-- 7h. REFUND: reject
CREATE OR REPLACE FUNCTION reject_refund(p_refund_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ref refunds%ROWTYPE;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT * INTO v_ref FROM refunds WHERE id = p_refund_id;
  IF NOT FOUND THEN RETURN json_build_object('ok', false, 'error', 'Refund not found'); END IF;
  IF v_ref.status NOT IN ('draft','submitted') THEN
    RETURN json_build_object('ok', false, 'error', 'Cannot reject refund in status: ' || v_ref.status);
  END IF;

  UPDATE refunds
     SET status       = 'rejected',
         rejected_by  = auth.uid(),
         rejected_at  = now(),
         rejection_reason = p_reason
   WHERE id = p_refund_id;

  INSERT INTO accounting_audit_logs (user_id, action, entity_type, entity_id, entity_ref, reason)
  VALUES (auth.uid(), 'REJECT', 'refunds', p_refund_id, v_ref.refund_number, p_reason);

  RETURN json_build_object('ok', true);
END;
$$;

-- ─── 8. AUDIT LOG QUERY RPC ───────────────────────────────────
-- Paginated audit trail for a given entity or all entities.
CREATE OR REPLACE FUNCTION get_audit_trail(
  p_entity_type TEXT    DEFAULT NULL,
  p_entity_id   UUID    DEFAULT NULL,
  p_from        DATE    DEFAULT NULL,
  p_to          DATE    DEFAULT NULL,
  p_limit       INT     DEFAULT 50,
  p_offset      INT     DEFAULT 0
)
RETURNS TABLE (
  id          UUID,
  user_id     UUID,
  user_email  TEXT,
  action      TEXT,
  entity_type TEXT,
  entity_id   UUID,
  entity_ref  TEXT,
  before_data JSONB,
  after_data  JSONB,
  reason      TEXT,
  created_at  TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    al.id, al.user_id,
    au.email AS user_email,
    al.action, al.entity_type, al.entity_id, al.entity_ref,
    al.before_data, al.after_data, al.reason, al.created_at
  FROM accounting_audit_logs al
  LEFT JOIN auth.users au ON au.id = al.user_id
  WHERE (p_entity_type IS NULL OR al.entity_type = p_entity_type)
    AND (p_entity_id   IS NULL OR al.entity_id   = p_entity_id)
    AND (p_from        IS NULL OR al.created_at  >= p_from::TIMESTAMPTZ)
    AND (p_to          IS NULL OR al.created_at  <  (p_to + 1)::TIMESTAMPTZ)
  ORDER BY al.created_at DESC
  LIMIT  COALESCE(p_limit,  50)
  OFFSET COALESCE(p_offset,  0);
$$;

-- ─── 9. PENDING APPROVALS RPC ─────────────────────────────────
-- Returns all items awaiting approval for the dashboard widget.
CREATE OR REPLACE FUNCTION get_pending_approvals()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_expenses     JSON;
  v_refunds      JSON;
  v_credit_notes JSON;
BEGIN
  IF NOT can_approve_financial() THEN
    RETURN json_build_object('ok', false, 'error', 'Insufficient permissions');
  END IF;

  SELECT json_agg(json_build_object(
    'id',              e.id,
    'ref',             e.expense_number,
    'type',            'expense',
    'amount',          e.total_amount,
    'currency',        e.currency,
    'status',          e.status,
    'requires_approval', e.requires_approval,
    'created_at',      e.created_at,
    'description',     e.description
  ))
  INTO v_expenses
  FROM nsp_expenses e
  WHERE e.status IN ('submitted') OR (e.status = 'draft' AND e.requires_approval = TRUE);

  SELECT json_agg(json_build_object(
    'id',       r.id,
    'ref',      r.refund_number,
    'type',     'refund',
    'amount',   r.amount,
    'currency', r.currency,
    'status',   r.status,
    'requires_approval', r.requires_approval,
    'created_at', r.created_at,
    'reason',   r.reason
  ))
  INTO v_refunds
  FROM refunds r
  WHERE r.status IN ('submitted') OR (r.status = 'draft' AND r.requires_approval = TRUE);

  SELECT json_agg(json_build_object(
    'id',       cn.id,
    'ref',      cn.note_number,
    'type',     cn.type,
    'amount',   cn.amount,
    'status',   cn.status,
    'requires_approval', cn.requires_approval,
    'created_at', cn.created_at,
    'reason',   cn.reason
  ))
  INTO v_credit_notes
  FROM credit_notes cn
  WHERE cn.status = 'draft' AND cn.requires_approval = TRUE;

  RETURN json_build_object(
    'ok',          true,
    'expenses',    COALESCE(v_expenses,     '[]'::json),
    'refunds',     COALESCE(v_refunds,      '[]'::json),
    'credit_notes',COALESCE(v_credit_notes, '[]'::json),
    'total',       (
      SELECT COUNT(*) FROM (
        SELECT id FROM nsp_expenses WHERE status = 'submitted'
        UNION ALL
        SELECT id FROM refunds       WHERE status = 'submitted'
        UNION ALL
        SELECT id FROM credit_notes  WHERE status = 'draft' AND requires_approval = TRUE
      ) sub
    )
  );
END;
$$;

-- ─── 10. INDEXES ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_aal_action      ON accounting_audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_aal_created_at  ON accounting_audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_expenses_status_approval ON nsp_expenses(status, requires_approval);
CREATE INDEX IF NOT EXISTS idx_refunds_status_approval  ON refunds(status, requires_approval);
CREATE INDEX IF NOT EXISTS idx_cn_status_approval       ON credit_notes(status, requires_approval);

-- ══ END v15 ═══════════════════════════════════════════════════
