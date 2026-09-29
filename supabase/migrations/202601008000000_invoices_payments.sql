-- ══════════════════════════════════════════════════════
--  NSP Migration v8 — Invoices & Payments upgrade
--  Safe additive — runs after v5 (tables already exist,
--  this adds missing cols + sequences if needed)
-- ══════════════════════════════════════════════════════

-- Ensure sequences exist (idempotent)
CREATE SEQUENCE IF NOT EXISTS inv_seq START 1000;
CREATE SEQUENCE IF NOT EXISTS pay_seq START 1000;

-- Add attachment col to invoices if missing
ALTER TABLE nsp_invoices ADD COLUMN IF NOT EXISTS attachment_url TEXT;
ALTER TABLE nsp_invoices ADD COLUMN IF NOT EXISTS notes TEXT;

-- Add attachment col to payments if missing
ALTER TABLE nsp_payments ADD COLUMN IF NOT EXISTS attachment_url TEXT;

-- ── Auto-number trigger for invoices ──────────────────
CREATE OR REPLACE FUNCTION set_invoice_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.invoice_number IS NULL OR NEW.invoice_number = '' THEN
    NEW.invoice_number := 'INV-' || TO_CHAR(now(),'YYYY') || '-' || LPAD(nextval('inv_seq')::TEXT,5,'0');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_inv_number ON nsp_invoices;
CREATE TRIGGER trg_inv_number BEFORE INSERT ON nsp_invoices
  FOR EACH ROW EXECUTE FUNCTION set_invoice_number();

-- ── Auto-number trigger for payments ──────────────────
CREATE OR REPLACE FUNCTION set_payment_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.payment_number IS NULL OR NEW.payment_number = '' THEN
    NEW.payment_number := 'PAY-' || TO_CHAR(now(),'YYYY') || '-' || LPAD(nextval('pay_seq')::TEXT,5,'0');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_pay_number ON nsp_payments;
CREATE TRIGGER trg_pay_number BEFORE INSERT ON nsp_payments
  FOR EACH ROW EXECUTE FUNCTION set_payment_number();

-- ── Update invoice paid/remaining after payment allocation ──
CREATE OR REPLACE FUNCTION refresh_invoice_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_inv_id UUID;
  v_paid NUMERIC;
  v_total NUMERIC;
  v_status TEXT;
BEGIN
  v_inv_id := COALESCE(NEW.invoice_id, OLD.invoice_id);
  SELECT total_amount INTO v_total FROM nsp_invoices WHERE id = v_inv_id;
  SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payment_allocations WHERE invoice_id = v_inv_id;

  IF v_paid <= 0 THEN v_status := 'issued';
  ELSIF v_paid >= v_total THEN v_status := 'paid';
  ELSE v_status := 'partial';
  END IF;

  UPDATE nsp_invoices SET
    paid_amount = v_paid,
    remaining_amount = GREATEST(v_total - v_paid, 0),
    status = v_status
  WHERE id = v_inv_id;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_inv_balance ON payment_allocations;
CREATE TRIGGER trg_inv_balance
  AFTER INSERT OR UPDATE OR DELETE ON payment_allocations
  FOR EACH ROW EXECUTE FUNCTION refresh_invoice_balance();

-- ── Overdue status updater (call via cron or on load) ─
CREATE OR REPLACE FUNCTION mark_overdue_invoices()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE nsp_invoices
  SET status = 'overdue'
  WHERE status IN ('issued','partial')
    AND due_date < CURRENT_DATE;
END;
$$;

-- RLS: admins full access already set in v5
-- Ensure customer SELECT policy on payments
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename='nsp_payments' AND policyname='customer_own'
  ) THEN
    CREATE POLICY "customer_own" ON nsp_payments FOR SELECT USING (customer_id = auth.uid());
  END IF;
END $$;

SELECT 'Migration v8 done' AS status;
