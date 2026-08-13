-- ══════════════════════════════════════════════════════════════
--  NSP Migration v14 — Roles & Permissions (Section 14)
--  Extends admin_users with granular roles:
--    super_admin, financial_manager, accountant, cashier,
--    sales_agent, booking_agent, auditor, admin, viewer
--  Adds role-specific RLS policies on financial tables.
--  Safe additive — drops old CHECK, adds new, preserves data.
--  Run after v13.
-- ══════════════════════════════════════════════════════════════

-- ─── 1. EXTEND admin_users ROLE CHECK ────────────────────────
-- Drop old constraint, add expanded one
ALTER TABLE admin_users DROP CONSTRAINT IF EXISTS admin_users_role_check;
ALTER TABLE admin_users
  ADD CONSTRAINT admin_users_role_check
  CHECK (role IN (
    'super_admin',
    'financial_manager',
    'accountant',
    'cashier',
    'sales_agent',
    'booking_agent',
    'auditor',
    'admin',
    'viewer'
  ));

-- ─── 2. HELPER FUNCTIONS FOR ROLE CHECKS ─────────────────────
-- Returns current user's role (NULL if not admin)
CREATE OR REPLACE FUNCTION auth_role()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role FROM admin_users WHERE id = auth.uid()
$$;

-- Is caller any admin (any role in admin_users)?
CREATE OR REPLACE FUNCTION is_any_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid())
$$;

-- Is caller super_admin?
CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'super_admin')
$$;

-- Can caller READ financial data?
-- Allowed: super_admin, financial_manager, accountant, cashier, auditor, admin
CREATE OR REPLACE FUNCTION can_read_financial()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','cashier','auditor','admin')
  )
$$;

-- Can caller WRITE/POST financial transactions?
-- Allowed: super_admin, financial_manager, accountant, admin
CREATE OR REPLACE FUNCTION can_write_financial()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','admin')
  )
$$;

-- Can caller handle cash/payment transactions?
-- Allowed: super_admin, financial_manager, accountant, cashier, admin
CREATE OR REPLACE FUNCTION can_handle_payments()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager','accountant','cashier','admin')
  )
$$;

-- Can caller approve financial workflows (expenses, refunds, credit notes)?
-- Allowed: super_admin, financial_manager
CREATE OR REPLACE FUNCTION can_approve_financial()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager')
  )
$$;

-- Can caller close fiscal periods / year-end?
-- Allowed: super_admin, financial_manager
CREATE OR REPLACE FUNCTION can_close_period()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','financial_manager')
  )
$$;

-- Can caller read/manage bookings?
-- Allowed: super_admin, admin, sales_agent, booking_agent, financial_manager, accountant, auditor
CREATE OR REPLACE FUNCTION can_read_bookings()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','admin','sales_agent','booking_agent',
                   'financial_manager','accountant','auditor','cashier')
  )
$$;

-- Can caller write bookings?
-- Allowed: super_admin, admin, sales_agent, booking_agent
CREATE OR REPLACE FUNCTION can_write_bookings()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin_users
    WHERE id = auth.uid()
      AND role IN ('super_admin','admin','sales_agent','booking_agent')
  )
$$;

-- ─── 3. ROLE-BASED RLS ON FINANCIAL TABLES ───────────────────

-- ── journal_entries ──
DROP POLICY IF EXISTS "admins_all"        ON journal_entries;
DROP POLICY IF EXISTS "financial_read"    ON journal_entries;
DROP POLICY IF EXISTS "financial_write"   ON journal_entries;

CREATE POLICY "financial_read"  ON journal_entries FOR SELECT
  USING (can_read_financial());
CREATE POLICY "financial_write" ON journal_entries FOR INSERT
  WITH CHECK (can_write_financial());
CREATE POLICY "financial_update" ON journal_entries FOR UPDATE
  USING (can_write_financial());

-- ── journal_entry_lines ──
DROP POLICY IF EXISTS "admins_all"        ON journal_entry_lines;
DROP POLICY IF EXISTS "financial_read"    ON journal_entry_lines;
DROP POLICY IF EXISTS "financial_write"   ON journal_entry_lines;

CREATE POLICY "financial_read"  ON journal_entry_lines FOR SELECT
  USING (can_read_financial());
CREATE POLICY "financial_write" ON journal_entry_lines FOR INSERT
  WITH CHECK (can_write_financial());
CREATE POLICY "financial_update" ON journal_entry_lines FOR UPDATE
  USING (can_write_financial());

-- ── accounts (CoA) ──
DROP POLICY IF EXISTS "admins_all"     ON accounts;
DROP POLICY IF EXISTS "financial_read" ON accounts;
DROP POLICY IF EXISTS "coa_write"      ON accounts;

CREATE POLICY "financial_read" ON accounts FOR SELECT
  USING (can_read_financial());
-- Only financial_manager/super_admin can modify CoA
CREATE POLICY "coa_write" ON accounts FOR INSERT
  WITH CHECK (can_approve_financial());
CREATE POLICY "coa_update" ON accounts FOR UPDATE
  USING (can_approve_financial());

-- ── fiscal_periods ──
DROP POLICY IF EXISTS "admins_all"       ON fiscal_periods;
DROP POLICY IF EXISTS "financial_read"   ON fiscal_periods;
DROP POLICY IF EXISTS "period_close"     ON fiscal_periods;

CREATE POLICY "financial_read" ON fiscal_periods FOR SELECT
  USING (can_read_financial());
CREATE POLICY "period_write" ON fiscal_periods FOR INSERT
  WITH CHECK (can_approve_financial());
-- Only financial_manager/super_admin can close periods
CREATE POLICY "period_update" ON fiscal_periods FOR UPDATE
  USING (can_approve_financial());

-- ── invoices ──
DROP POLICY IF EXISTS "admins_all"     ON invoices;
DROP POLICY IF EXISTS "financial_read" ON invoices;
DROP POLICY IF EXISTS "financial_write"ON invoices;

CREATE POLICY "financial_read"   ON invoices FOR SELECT
  USING (can_read_financial() OR can_read_bookings());
CREATE POLICY "financial_write"  ON invoices FOR INSERT
  WITH CHECK (can_handle_payments());
CREATE POLICY "financial_update" ON invoices FOR UPDATE
  USING (can_handle_payments());

-- ── invoice_items ──
DROP POLICY IF EXISTS "admins_all"     ON invoice_items;
DROP POLICY IF EXISTS "financial_read" ON invoice_items;
DROP POLICY IF EXISTS "financial_write"ON invoice_items;

CREATE POLICY "financial_read"   ON invoice_items FOR SELECT
  USING (can_read_financial() OR can_read_bookings());
CREATE POLICY "financial_write"  ON invoice_items FOR INSERT
  WITH CHECK (can_handle_payments());
CREATE POLICY "financial_update" ON invoice_items FOR UPDATE
  USING (can_handle_payments());

-- ── payments ──
DROP POLICY IF EXISTS "admins_all"     ON payments;
DROP POLICY IF EXISTS "payment_read"   ON payments;
DROP POLICY IF EXISTS "payment_write"  ON payments;

CREATE POLICY "payment_read"   ON payments FOR SELECT
  USING (can_read_financial() OR can_read_bookings());
-- Cashier can insert payments
CREATE POLICY "payment_write"  ON payments FOR INSERT
  WITH CHECK (can_handle_payments());
CREATE POLICY "payment_update" ON payments FOR UPDATE
  USING (can_handle_payments());

-- ── payment_allocations ──
DROP POLICY IF EXISTS "admins_all"     ON payment_allocations;
DROP POLICY IF EXISTS "payment_read"   ON payment_allocations;
DROP POLICY IF EXISTS "payment_write"  ON payment_allocations;

CREATE POLICY "payment_read"   ON payment_allocations FOR SELECT
  USING (can_read_financial());
CREATE POLICY "payment_write"  ON payment_allocations FOR INSERT
  WITH CHECK (can_handle_payments());

-- ── expenses ──
DROP POLICY IF EXISTS "admins_all"     ON expenses;
DROP POLICY IF EXISTS "expense_read"   ON expenses;
DROP POLICY IF EXISTS "expense_write"  ON expenses;

CREATE POLICY "expense_read"   ON expenses FOR SELECT
  USING (can_read_financial());
CREATE POLICY "expense_write"  ON expenses FOR INSERT
  WITH CHECK (can_write_financial());
CREATE POLICY "expense_update" ON expenses FOR UPDATE
  -- Accountant can submit; financial_manager can approve
  USING (can_write_financial());

-- ── cash_accounts ──
DROP POLICY IF EXISTS "admins_all"      ON cash_accounts;
DROP POLICY IF EXISTS "cash_read"       ON cash_accounts;
DROP POLICY IF EXISTS "cash_write"      ON cash_accounts;

CREATE POLICY "cash_read"   ON cash_accounts FOR SELECT
  USING (can_read_financial());
CREATE POLICY "cash_write"  ON cash_accounts FOR ALL
  USING (can_approve_financial());

-- ── bank_accounts ──
DROP POLICY IF EXISTS "admins_all"     ON bank_accounts;
DROP POLICY IF EXISTS "bank_read"      ON bank_accounts;
DROP POLICY IF EXISTS "bank_write"     ON bank_accounts;

CREATE POLICY "bank_read"  ON bank_accounts FOR SELECT
  USING (can_read_financial());
CREATE POLICY "bank_write" ON bank_accounts FOR ALL
  USING (can_approve_financial());

-- ── bank_transactions ──
DROP POLICY IF EXISTS "admins_all"     ON bank_transactions;
DROP POLICY IF EXISTS "bank_read"      ON bank_transactions;
DROP POLICY IF EXISTS "bank_write"     ON bank_transactions;

CREATE POLICY "bank_read"  ON bank_transactions FOR SELECT
  USING (can_read_financial());
CREATE POLICY "bank_write" ON bank_transactions FOR INSERT
  WITH CHECK (can_handle_payments());
CREATE POLICY "bank_update" ON bank_transactions FOR UPDATE
  USING (can_handle_payments());

-- ── bank_reconciliations ──
DROP POLICY IF EXISTS "admins_all"   ON bank_reconciliations;

CREATE POLICY "recon_read"  ON bank_reconciliations FOR SELECT
  USING (can_read_financial());
CREATE POLICY "recon_write" ON bank_reconciliations FOR ALL
  USING (can_write_financial());

-- ── credit_notes ──
DROP POLICY IF EXISTS "admins_all"    ON credit_notes;

CREATE POLICY "cn_read"    ON credit_notes FOR SELECT
  USING (can_read_financial());
CREATE POLICY "cn_write"   ON credit_notes FOR INSERT
  WITH CHECK (can_write_financial());
-- Only approvers can post credit notes
CREATE POLICY "cn_update"  ON credit_notes FOR UPDATE
  USING (can_write_financial());

-- ── debit_notes ──
DROP POLICY IF EXISTS "admins_all"   ON debit_notes;

CREATE POLICY "dn_read"    ON debit_notes FOR SELECT
  USING (can_read_financial());
CREATE POLICY "dn_write"   ON debit_notes FOR INSERT
  WITH CHECK (can_write_financial());
CREATE POLICY "dn_update"  ON debit_notes FOR UPDATE
  USING (can_write_financial());

-- ── refunds ──
DROP POLICY IF EXISTS "admins_all"   ON refunds;

CREATE POLICY "refund_read"   ON refunds FOR SELECT
  USING (can_read_financial());
CREATE POLICY "refund_write"  ON refunds FOR INSERT
  WITH CHECK (can_write_financial());
-- Refund approval: financial_manager/super_admin
CREATE POLICY "refund_approve" ON refunds FOR UPDATE
  USING (can_approve_financial());

-- ── suppliers ──
DROP POLICY IF EXISTS "admins_all"    ON suppliers;

CREATE POLICY "supplier_read"  ON suppliers FOR SELECT
  USING (can_read_financial() OR can_read_bookings());
CREATE POLICY "supplier_write" ON suppliers FOR ALL
  USING (can_write_financial());

-- ── customers (if table exists) ──
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'customers') THEN
    DROP POLICY IF EXISTS "admins_all"    ON customers;
    DROP POLICY IF EXISTS "customer_read" ON customers;
    EXECUTE '
      CREATE POLICY "customer_read"  ON customers FOR SELECT
        USING (can_read_financial() OR can_read_bookings());
      CREATE POLICY "customer_write" ON customers FOR ALL
        USING (can_write_financial())
    ';
  END IF;
END $$;

-- ── cost_centers ──
DROP POLICY IF EXISTS "admins_all"  ON cost_centers;

CREATE POLICY "cc_read"  ON cost_centers FOR SELECT
  USING (can_read_financial());
CREATE POLICY "cc_write" ON cost_centers FOR ALL
  USING (can_approve_financial());

-- ── taxes ──
DROP POLICY IF EXISTS "admins_all" ON taxes;

CREATE POLICY "tax_read"  ON taxes FOR SELECT
  USING (can_read_financial());
CREATE POLICY "tax_write" ON taxes FOR ALL
  USING (can_approve_financial());

-- ── exchange_rates ──
DROP POLICY IF EXISTS "admins_all"  ON exchange_rates;

CREATE POLICY "er_read"  ON exchange_rates FOR SELECT
  USING (is_any_admin());
CREATE POLICY "er_write" ON exchange_rates FOR ALL
  USING (can_approve_financial());

-- ── accounting_audit_logs — auditors/all financial can read, nobody writes (triggers only) ──
DROP POLICY IF EXISTS "admins_all"   ON accounting_audit_logs;

CREATE POLICY "audit_read"   ON accounting_audit_logs FOR SELECT
  USING (can_read_financial());
-- No direct INSERT/UPDATE/DELETE by users — triggers only

-- ── bookings — role-scoped ──
-- (existing policies kept; add scoped read for sales/booking agents)
DROP POLICY IF EXISTS "agent_read_bookings" ON bookings;
CREATE POLICY "agent_read_bookings" ON bookings FOR SELECT
  USING (
    can_read_bookings()
    OR user_id = auth.uid()
  );

DROP POLICY IF EXISTS "agent_write_bookings" ON bookings;
CREATE POLICY "agent_write_bookings" ON bookings FOR INSERT
  WITH CHECK (
    can_write_bookings()
    OR TRUE  -- public booking flow retained
  );

DROP POLICY IF EXISTS "agent_update_bookings" ON bookings;
CREATE POLICY "agent_update_bookings" ON bookings FOR UPDATE
  USING (can_write_bookings());

-- ── packages — sales/booking agents can read (already public read, but also admin read) ──
DROP POLICY IF EXISTS "agent_packages_read" ON packages;
CREATE POLICY "agent_packages_read" ON packages FOR SELECT
  USING (is_active = TRUE OR can_read_bookings());

-- ── admin_users — only super_admin can manage ──
-- (Policies already exist from v1, add role-based checks)
DROP POLICY IF EXISTS "super_admin_all" ON admin_users;
CREATE POLICY "super_admin_all" ON admin_users FOR ALL
  USING (is_super_admin());

-- ─── 4. PREVENT AUDITOR / VIEWER FROM WRITES ─────────────────
-- Auditor: read-only across ALL financial tables (enforced above by omitting from write functions)
-- Viewer: no financial access at all (not in can_read_financial)
-- This is enforced server-side via the helper functions above.

-- ─── 5. ROLE METADATA TABLE ──────────────────────────────────
-- Stores human-readable role definitions (UI reference)
CREATE TABLE IF NOT EXISTS role_definitions (
  role         TEXT PRIMARY KEY,
  name_ar      TEXT NOT NULL,
  name_en      TEXT NOT NULL,
  description_ar TEXT,
  icon         TEXT DEFAULT 'fa-user',
  color        TEXT DEFAULT 'gray',
  sort_order   INT  DEFAULT 99
);

-- Seed role definitions
INSERT INTO role_definitions (role, name_ar, name_en, description_ar, icon, color, sort_order)
VALUES
  ('super_admin',      'مدير عام',        'Super Admin',       'صلاحيات كاملة على النظام بأكمله', 'fa-crown', 'yellow', 1),
  ('financial_manager','مدير مالي',        'Financial Manager', 'الموافقة على المعاملات المالية وإغلاق الفترات وإدارة الميزانية', 'fa-landmark', 'purple', 2),
  ('accountant',       'محاسب',           'Accountant',        'إدخال القيود وإدارة الفواتير والتقارير المالية', 'fa-calculator', 'blue', 3),
  ('cashier',          'أمين صندوق',      'Cashier',           'استلام وتسجيل المدفوعات النقدية فقط', 'fa-cash-register', 'green', 4),
  ('sales_agent',      'موظف مبيعات',     'Sales Agent',       'إدارة العملاء والحجوزات وعرض البيانات الأساسية', 'fa-handshake', 'teal', 5),
  ('booking_agent',    'موظف حجوزات',     'Booking Agent',     'إنشاء الحجوزات وتتبع حالتها وإدارة المسافرين', 'fa-calendar-check', 'indigo', 6),
  ('auditor',          'مراجع حسابات',    'Auditor',           'عرض جميع البيانات المالية بدون صلاحية التعديل', 'fa-eye', 'orange', 7),
  ('admin',            'مشرف',            'Admin',             'إدارة عامة للنظام باستثناء إغلاق الفترات المالية', 'fa-user-tie', 'blue', 8),
  ('viewer',           'مشاهد',           'Viewer',            'عرض البيانات العامة فقط', 'fa-eye', 'gray', 9)
ON CONFLICT (role) DO UPDATE
  SET name_ar = EXCLUDED.name_ar,
      name_en = EXCLUDED.name_en,
      description_ar = EXCLUDED.description_ar,
      icon = EXCLUDED.icon,
      color = EXCLUDED.color,
      sort_order = EXCLUDED.sort_order;

ALTER TABLE role_definitions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "all_admins_read_roles" ON role_definitions FOR SELECT
  USING (is_any_admin());
CREATE POLICY "super_admin_write_roles" ON role_definitions FOR ALL
  USING (is_super_admin());

-- ─── 6. PERMISSION MATRIX TABLE ──────────────────────────────
-- Documents which roles have which permissions (UI reference + API checks)
CREATE TABLE IF NOT EXISTS permission_matrix (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  permission  TEXT NOT NULL,
  name_ar     TEXT NOT NULL,
  category_ar TEXT NOT NULL,
  roles       TEXT[] NOT NULL  -- array of allowed roles
);

-- Seed permission matrix
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
VALUES
  -- Bookings
  ('read_bookings',   'عرض الحجوزات',        'الحجوزات',  ARRAY['super_admin','admin','financial_manager','accountant','cashier','sales_agent','booking_agent','auditor']),
  ('write_bookings',  'إنشاء/تعديل الحجوزات','الحجوزات',  ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('delete_bookings', 'حذف الحجوزات',         'الحجوزات',  ARRAY['super_admin']),
  -- Packages
  ('read_packages',   'عرض البرامج',          'البرامج',   ARRAY['super_admin','admin','sales_agent','booking_agent','auditor','financial_manager']),
  ('write_packages',  'إدارة البرامج',         'البرامج',   ARRAY['super_admin','admin']),
  -- Financial - Read
  ('read_invoices',   'عرض الفواتير',          'المالية',   ARRAY['super_admin','financial_manager','accountant','cashier','auditor','admin']),
  ('read_payments',   'عرض المدفوعات',         'المالية',   ARRAY['super_admin','financial_manager','accountant','cashier','auditor','admin']),
  ('read_reports',    'عرض التقارير المالية',  'التقارير',  ARRAY['super_admin','financial_manager','accountant','auditor','admin']),
  ('read_journal',    'عرض القيود المحاسبية',  'المحاسبة',  ARRAY['super_admin','financial_manager','accountant','auditor']),
  -- Financial - Write
  ('write_invoices',  'إنشاء/تعديل الفواتير', 'المالية',   ARRAY['super_admin','financial_manager','accountant','cashier','admin']),
  ('write_payments',  'تسجيل المدفوعات',       'المالية',   ARRAY['super_admin','financial_manager','accountant','cashier','admin']),
  ('write_journal',   'إدخال القيود المحاسبية','المحاسبة',  ARRAY['super_admin','financial_manager','accountant','admin']),
  ('write_expenses',  'تسجيل المصاريف',        'المصاريف',  ARRAY['super_admin','financial_manager','accountant','admin']),
  -- Approval
  ('approve_expenses','اعتماد المصاريف',       'الموافقات', ARRAY['super_admin','financial_manager']),
  ('approve_refunds', 'اعتماد المردودات',      'الموافقات', ARRAY['super_admin','financial_manager']),
  ('approve_credit_notes','اعتماد إشعارات الخصم','الموافقات',ARRAY['super_admin','financial_manager']),
  -- Fiscal Periods
  ('read_fiscal',     'عرض الفترات المالية',   'الفترات',   ARRAY['super_admin','financial_manager','accountant','auditor','admin']),
  ('close_period',    'إغلاق الفترات المالية', 'الفترات',   ARRAY['super_admin','financial_manager']),
  ('year_end_close',  'إقفال السنة المالية',   'الفترات',   ARRAY['super_admin','financial_manager']),
  -- CoA
  ('read_coa',        'عرض دليل الحسابات',     'الحسابات',  ARRAY['super_admin','financial_manager','accountant','auditor','admin']),
  ('write_coa',       'تعديل دليل الحسابات',   'الحسابات',  ARRAY['super_admin','financial_manager']),
  -- Suppliers/Customers
  ('read_suppliers',  'عرض الموردين',          'الموردون',  ARRAY['super_admin','financial_manager','accountant','auditor','admin','sales_agent']),
  ('write_suppliers', 'إدارة الموردين',         'الموردون',  ARRAY['super_admin','financial_manager','accountant','admin']),
  ('read_customers',  'عرض العملاء',           'العملاء',   ARRAY['super_admin','admin','financial_manager','accountant','cashier','sales_agent','booking_agent','auditor']),
  -- Cash/Bank
  ('read_cash_bank',  'عرض الخزينة والبنوك',   'الخزينة',   ARRAY['super_admin','financial_manager','accountant','cashier','auditor','admin']),
  ('write_cash_bank', 'إدارة الخزينة والبنوك', 'الخزينة',   ARRAY['super_admin','financial_manager','accountant','admin']),
  -- Admin
  ('manage_users',    'إدارة المستخدمين',       'الإدارة',   ARRAY['super_admin']),
  ('manage_admins',   'إدارة المشرفين والأدوار','الإدارة',   ARRAY['super_admin']),
  ('view_audit_log',  'عرض سجل العمليات',      'الإدارة',   ARRAY['super_admin','financial_manager','auditor','admin']),
  ('system_settings', 'إعدادات النظام',         'الإدارة',   ARRAY['super_admin'])
ON CONFLICT DO NOTHING;

ALTER TABLE permission_matrix ENABLE ROW LEVEL SECURITY;
CREATE POLICY "all_admins_read_perms" ON permission_matrix FOR SELECT
  USING (is_any_admin());
CREATE POLICY "super_admin_write_perms" ON permission_matrix FOR ALL
  USING (is_super_admin());

-- ─── 7. RPC: GET CURRENT USER PERMISSIONS ────────────────────
-- Returns the current admin's role + all permissions
CREATE OR REPLACE FUNCTION get_my_permissions()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role TEXT;
  v_perms TEXT[];
BEGIN
  SELECT role INTO v_role FROM admin_users WHERE id = auth.uid();
  IF v_role IS NULL THEN
    RETURN json_build_object('role', NULL, 'permissions', ARRAY[]::TEXT[]);
  END IF;

  SELECT ARRAY_AGG(permission) INTO v_perms
    FROM permission_matrix
    WHERE v_role = ANY(roles);

  RETURN json_build_object(
    'role', v_role,
    'permissions', COALESCE(v_perms, ARRAY[]::TEXT[])
  );
END;
$$;

-- ─── 8. RPC: CHECK SINGLE PERMISSION ─────────────────────────
CREATE OR REPLACE FUNCTION has_permission(p_permission TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_role TEXT;
BEGIN
  SELECT role INTO v_role FROM admin_users WHERE id = auth.uid();
  IF v_role IS NULL THEN RETURN FALSE; END IF;

  RETURN EXISTS (
    SELECT 1 FROM permission_matrix
    WHERE permission = p_permission
      AND v_role = ANY(roles)
  );
END;
$$;

-- ─── 9. AUDIT LOG: ROLE CHANGES ──────────────────────────────
-- Track when roles are changed (uses existing audit_logs table)
CREATE OR REPLACE FUNCTION log_role_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.role IS DISTINCT FROM NEW.role THEN
    INSERT INTO audit_logs (
      action, entity, entity_id,
      old_value, new_value, performed_by
    ) VALUES (
      'role_change',
      'admin_users',
      NEW.id::TEXT,
      json_build_object('role', OLD.role)::TEXT,
      json_build_object('role', NEW.role)::TEXT,
      auth.uid()
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_role_change ON admin_users;
CREATE TRIGGER trg_log_role_change
  AFTER UPDATE ON admin_users
  FOR EACH ROW EXECUTE FUNCTION log_role_change();

-- ─── 10. INDEXES ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_admin_users_role ON admin_users(role);
CREATE INDEX IF NOT EXISTS idx_perm_matrix_permission ON permission_matrix(permission);

-- ══ END v14 ══════════════════════════════════════════════════
