-- ══════════════════════════════════════════════════════════════
--  NSP Migration v8 — Invoice Number Auto-Generation
--  Safe additive. Run after v7.
-- ══════════════════════════════════════════════════════════════

-- Sequence already created in v5 as inv_seq.
-- This migration adds the trigger to auto-set invoice_number on insert.

CREATE OR REPLACE FUNCTION set_invoice_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.invoice_number IS NULL OR NEW.invoice_number = '' THEN
    NEW.invoice_number := 'INV-' || TO_CHAR(now(), 'YYYY') || '-' || LPAD(nextval('inv_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_number ON nsp_invoices;
CREATE TRIGGER trg_invoice_number
  BEFORE INSERT ON nsp_invoices
  FOR EACH ROW EXECUTE FUNCTION set_invoice_number();

-- Same for payments
CREATE OR REPLACE FUNCTION set_payment_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.payment_number IS NULL OR NEW.payment_number = '' THEN
    NEW.payment_number := 'PAY-' || TO_CHAR(now(), 'YYYY') || '-' || LPAD(nextval('pay_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_number ON nsp_payments;
CREATE TRIGGER trg_payment_number
  BEFORE INSERT ON nsp_payments
  FOR EACH ROW EXECUTE FUNCTION set_payment_number();

-- Verify
SELECT 'invoice trigger' AS check, COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'trg_invoice_number'
UNION ALL
SELECT 'payment trigger', COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'trg_payment_number';
