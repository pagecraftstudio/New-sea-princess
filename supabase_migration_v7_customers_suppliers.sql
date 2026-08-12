-- ══════════════════════════════════════════════════════════════
--  NSP Migration v7 — Customers & Suppliers (Section 6)
--  Additive only. Safe to run on top of v1–v6.
-- ══════════════════════════════════════════════════════════════

-- ─── credit_notes: ensure customer_name column exists ─────────
ALTER TABLE credit_notes
  ADD COLUMN IF NOT EXISTS customer_name TEXT;

-- ─── booking_costs: ensure cost_amount alias works ─────────────
-- booking_costs already has amount; add alias view for UI
CREATE OR REPLACE VIEW booking_costs_view AS
  SELECT
    bc.*,
    bc.amount AS cost_amount,
    b.booking_number,
    b.customer_name,
    b.package_title,
    b.status AS booking_status,
    s.name_ar AS supplier_name_ar,
    s.name_en AS supplier_name_en,
    s.type AS supplier_type
  FROM booking_costs bc
  LEFT JOIN bookings b ON b.id = bc.booking_id
  LEFT JOIN suppliers s ON s.id = bc.supplier_id;

-- ─── customer_ledger view ──────────────────────────────────────
CREATE OR REPLACE VIEW customer_ledger AS
  SELECT
    b.customer_name,
    b.customer_phone,
    b.customer_email,
    b.user_id,
    COUNT(DISTINCT b.id)             AS booking_count,
    SUM(b.total_price)               AS total_invoiced,
    SUM(b.paid_amount)               AS total_paid,
    SUM(b.remaining_amount)          AS total_remaining,
    MAX(b.created_at)                AS last_booking_date
  FROM bookings b
  GROUP BY b.customer_name, b.customer_phone, b.customer_email, b.user_id;

-- Allow admins to read this view
GRANT SELECT ON customer_ledger TO authenticated;

-- ─── supplier_ledger view ──────────────────────────────────────
CREATE OR REPLACE VIEW supplier_ledger AS
  SELECT
    s.id AS supplier_id,
    s.name_ar,
    s.name_en,
    s.type,
    s.currency,
    COALESCE(SUM(e.total_amount) FILTER (WHERE e.status = 'posted'), 0) AS total_expenses_posted,
    COALESCE(SUM(bc.amount), 0) AS total_booking_costs,
    COALESCE(SUM(e.total_amount) FILTER (WHERE e.status = 'posted'), 0)
      + COALESCE(SUM(bc.amount), 0) AS grand_total_payable
  FROM suppliers s
  LEFT JOIN nsp_expenses e ON e.supplier_id = s.id
  LEFT JOIN booking_costs bc ON bc.supplier_id = s.id
  GROUP BY s.id, s.name_ar, s.name_en, s.type, s.currency;

GRANT SELECT ON supplier_ledger TO authenticated;

-- ─── Index improvements ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_bookings_customer_name ON bookings(customer_name);
CREATE INDEX IF NOT EXISTS idx_bookings_customer_email ON bookings(customer_email);
CREATE INDEX IF NOT EXISTS idx_bookings_customer_phone ON bookings(customer_phone);
CREATE INDEX IF NOT EXISTS idx_expenses_supplier ON nsp_expenses(supplier_id);
CREATE INDEX IF NOT EXISTS idx_booking_costs_supplier ON booking_costs(supplier_id);
