-- ============================================================
-- P3.7 SECURITY ROLE/PERMISSION TEST SUITE
-- Flow Travel & Tourism / DMC Operating System
-- Run in Supabase SQL Editor (as super_admin first for baseline)
-- ============================================================

-- ── SECTION A: Permission matrix verification ─────────────────

-- A1: List all permissions and which roles have them
SELECT permission, roles, name_ar
FROM permission_matrix
ORDER BY permission;

-- A2: Verify viewer has zero permissions
SELECT COUNT(*) AS viewer_permission_count
FROM permission_matrix
WHERE 'viewer' = ANY(roles);
-- Expected: 0

-- A3: Verify cashier does NOT have financial write permissions
SELECT permission FROM permission_matrix
WHERE 'cashier' = ANY(roles)
  AND permission IN ('write_journal','write_coa','approve_expenses','close_period','write_expenses','write_suppliers')
ORDER BY permission;
-- Expected: 0 rows

-- A4: Verify sales_agent does NOT have finance read permissions
SELECT permission FROM permission_matrix
WHERE 'sales_agent' = ANY(roles)
  AND permission IN ('read_invoices','read_journal','read_payments','write_journal','write_invoices')
ORDER BY permission;
-- Expected: 0 rows  ← CRITICAL

-- A5: Verify admin does NOT have super_admin-only permissions
SELECT permission FROM permission_matrix
WHERE 'admin' = ANY(roles)
  AND permission IN ('manage_admins','manage_users','delete_bookings','system_settings','manage_ai_config','year_end_close')
ORDER BY permission;
-- Expected: 0 rows  ← CRITICAL

-- A6: Verify accountant cannot approve
SELECT permission FROM permission_matrix
WHERE 'accountant' = ANY(roles)
  AND permission IN ('approve_expenses','approve_credit_notes','approve_refunds','close_period')
ORDER BY permission;
-- Expected: 0 rows

-- ── SECTION B: Security-definer function authorization ────────

-- B1: Check all SECURITY DEFINER functions
SELECT routine_name, security_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND security_type = 'DEFINER'
ORDER BY routine_name;

-- B2: Check EXECUTE grants (functions that might be overly permissive)
SELECT grantee, routine_name, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND grantee IN ('anon', 'public', 'authenticated')
ORDER BY routine_name, grantee;
-- Verify: no sensitive functions granted to 'anon'

-- ── SECTION C: RLS verification ───────────────────────────────

-- C1: Confirm RLS enabled on all critical tables
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'bookings','nsp_invoices','nsp_payments','nsp_expenses',
    'journal_entries','journal_entry_lines','customers','leads',
    'opportunities','admin_users','accounting_audit_logs',
    'b2b_partners','supplier_bills','supplier_payments'
  )
ORDER BY tablename;
-- Expected: rowsecurity = true for ALL

-- C2: accounting_audit_logs: verify no INSERT policy for regular users
SELECT policyname, cmd, roles
FROM pg_policies
WHERE tablename = 'accounting_audit_logs'
  AND schemaname = 'public'
ORDER BY policyname;
-- Expected: no INSERT policy for 'authenticated' or 'anon'

-- C3: audit_logs RLS policies
SELECT policyname, cmd, roles, qual
FROM pg_policies
WHERE tablename = 'audit_logs'
  AND schemaname = 'public';

-- C4: leads RLS - verify ownership policy exists
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'leads'
  AND schemaname = 'public'
ORDER BY policyname;
-- Must include a SELECT policy filtering by assigned_to = auth.uid()

-- C5: Trigger guards on financial tables
SELECT trigger_name, event_object_table, action_timing, event_manipulation
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name IN (
    'trg_guard_expense','trg_guard_credit_note','trg_guard_refund',
    'trg_journal_balance','trg_fp_enforce'
  )
ORDER BY trigger_name;
-- Expected: all 5 present

-- ── SECTION D: Role-based function tests ──────────────────────
-- Run each block while authenticated as the corresponding role

-- D1: As any authenticated admin user:
SELECT get_admin_role();  -- should return their role string

-- D2: get_my_permissions() returns correct structure
SELECT
  (get_my_permissions()->>'role')::TEXT AS role,
  jsonb_array_length((get_my_permissions()->'permissions')::JSONB) AS permission_count;

-- D3: has_permission tests (run as specific roles)
SELECT
  has_permission('manage_admins')   AS can_manage_admins,   -- only super_admin
  has_permission('approve_expenses') AS can_approve_expenses, -- super_admin, financial_manager
  has_permission('read_bookings')   AS can_read_bookings,    -- most roles except viewer
  has_permission('write_journal')   AS can_write_journal,    -- super_admin, financial_manager, accountant, admin
  has_permission('delete_bookings') AS can_delete_bookings;  -- only super_admin

-- ── SECTION E: Data integrity checks ──────────────────────────

-- E1: No orphaned journal entries (should balance)
SELECT id, total_debit, total_credit,
  (total_debit - total_credit) AS imbalance
FROM journal_entries
WHERE status = 'posted'
  AND ABS(total_debit - total_credit) > 0.001
LIMIT 10;
-- Expected: 0 rows

-- E2: No posted expenses with future dates in closed periods
SELECT e.id, e.expense_date, fp.name, fp.status
FROM nsp_expenses e
JOIN fiscal_periods fp ON fp.start_date <= e.expense_date AND fp.end_date >= e.expense_date
WHERE e.status = 'posted'
  AND fp.status = 'closed'
LIMIT 5;

-- E3: Invoice balance integrity
SELECT id, invoice_number, total_amount, paid_amount, remaining_amount,
  (total_amount - paid_amount - remaining_amount) AS discrepancy
FROM nsp_invoices
WHERE ABS(total_amount - paid_amount - remaining_amount) > 0.01
LIMIT 10;
-- Expected: 0 rows (trigger should keep these consistent)

-- ── SECTION F: Admin users audit ──────────────────────────────

-- F1: All admin roles are valid enum values
SELECT id, email, role FROM admin_users
WHERE role NOT IN (
  'super_admin','admin','financial_manager','accountant',
  'cashier','sales_agent','booking_agent','auditor','viewer'
);
-- Expected: 0 rows

-- F2: No admin users with NULL role
SELECT COUNT(*) AS null_role_count FROM admin_users WHERE role IS NULL;
-- Expected: 0

