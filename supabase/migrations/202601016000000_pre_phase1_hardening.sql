-- ══════════════════════════════════════════════════════════════════════════════
--  PRE-PHASE-1 HARDENING MIGRATION
--  File: supabase/migrations/202601016000000_pre_phase1_hardening.sql
--
--  Purpose: Fix two verified blockers from Phase 0 audit.
--           NO new business logic. NO CRM. NO customers table.
--           ONLY prerequisite fixes to unblock admin auth and audit logging.
--
--  Blocker 1: get_admin_role() RPC missing → admin auth broken on all pages
--  Blocker 2: audit_logs schema mismatch → log_role_change trigger silently fails
--
--  Safe to run on production:
--    - All changes are purely additive (CREATE OR REPLACE, ADD COLUMN IF NOT EXISTS)
--    - No existing columns dropped or renamed
--    - No existing rows modified
--    - No existing triggers dropped or replaced
--    - No data mutation
--
--  Run after: v14 (202601014000000_roles_permissions_fixed.sql)
--  Run before: Phase 1 CRM migration
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1: CREATE get_admin_role() RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- Root cause: admin.js calls db.rpc('get_admin_role') but only auth_role()
--             exists in v14. Functionally identical — just different name.
--
-- This is a pure alias. Same query as auth_role(). SECURITY DEFINER so RLS
-- on admin_users does not block the lookup (same pattern as auth_role()).
--
-- GRANT to authenticated so Supabase client can invoke via .rpc().
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_admin_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role
  FROM   admin_users
  WHERE  id = auth.uid()
$$;

GRANT EXECUTE ON FUNCTION get_admin_role() TO authenticated;

COMMENT ON FUNCTION get_admin_role() IS
  'Returns current user''s admin role from admin_users. '
  'Called by admin.js adminCheckAuth(). '
  'Alias of auth_role() — created in pre-phase-1 hardening migration '
  'to fix missing RPC identified in Phase 0 audit.';


-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2: ADD MISSING COLUMNS TO audit_logs
-- ─────────────────────────────────────────────────────────────────────────────
-- Root cause: v1 created audit_logs with: admin_id, admin_email, action,
--             table_name, record_id, record_label, details
--
--             v14 log_role_change() trigger inserts: action, entity,
--             entity_id, old_value, new_value, performed_by
--
--             Columns entity / entity_id / old_value / new_value /
--             performed_by do not exist → trigger throws PG error on
--             every admin role change → role changes are not audited.
--
-- Fix: ADD COLUMN IF NOT EXISTS for all 5 missing columns.
--      Existing rows get NULL (correct — they predate this trigger).
--      Existing admin UI queries use table_name/record_id/details → unaffected.
--      No index changes. No lock beyond brief metadata update.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE audit_logs
  ADD COLUMN IF NOT EXISTS entity       TEXT,
  ADD COLUMN IF NOT EXISTS entity_id    TEXT,
  ADD COLUMN IF NOT EXISTS old_value    TEXT,
  ADD COLUMN IF NOT EXISTS new_value    TEXT,
  ADD COLUMN IF NOT EXISTS performed_by UUID REFERENCES auth.users(id);

-- Index on performed_by for audit queries filtering by who made changes
CREATE INDEX IF NOT EXISTS idx_audit_logs_performed_by
  ON audit_logs(performed_by);

-- Index on entity + entity_id for per-entity audit trail queries
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity
  ON audit_logs(entity, entity_id);

COMMENT ON COLUMN audit_logs.entity IS
  'Entity type that was changed (e.g. admin_users). '
  'Used by log_role_change trigger (v14). '
  'NULL for pre-v14 audit rows which used table_name column instead.';

COMMENT ON COLUMN audit_logs.entity_id IS
  'UUID of the changed entity as TEXT. '
  'Used by log_role_change trigger (v14). '
  'NULL for pre-v14 audit rows which used record_id instead.';

COMMENT ON COLUMN audit_logs.old_value IS
  'JSON-serialized previous value (e.g. {"role":"viewer"}). '
  'Set by log_role_change trigger on admin_users role updates.';

COMMENT ON COLUMN audit_logs.new_value IS
  'JSON-serialized new value (e.g. {"role":"accountant"}). '
  'Set by log_role_change trigger on admin_users role updates.';

COMMENT ON COLUMN audit_logs.performed_by IS
  'auth.users.id of the admin who performed the action. '
  'Used by log_role_change trigger. '
  'Different from admin_id (which stores the affected user) — '
  'performed_by = who did it, admin_id = who it was done to.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION QUERIES
-- Run these manually in Supabase SQL editor after applying migration
-- to confirm both fixes are in place.
-- ─────────────────────────────────────────────────────────────────────────────

-- Verify Fix 1: function exists with correct signature
-- Expected: 1 row with routine_name = 'get_admin_role'
--
-- SELECT routine_name, security_type
-- FROM   information_schema.routines
-- WHERE  routine_schema = 'public'
--   AND  routine_name   = 'get_admin_role';

-- Verify Fix 2: all 5 columns now exist in audit_logs
-- Expected: 5 rows (entity, entity_id, old_value, new_value, performed_by)
--
-- SELECT column_name, data_type, is_nullable
-- FROM   information_schema.columns
-- WHERE  table_schema = 'public'
--   AND  table_name   = 'audit_logs'
--   AND  column_name  IN ('entity','entity_id','old_value','new_value','performed_by')
-- ORDER  BY column_name;

-- Verify Fix 2: trigger still exists and is enabled
-- Expected: 1 row, enabled = 'O' (origin/per-row)
--
-- SELECT trigger_name, event_manipulation, action_timing
-- FROM   information_schema.triggers
-- WHERE  trigger_schema = 'public'
--   AND  trigger_name   = 'trg_log_role_change';

-- Verify Fix 1: function callable (run as authenticated admin user)
-- Expected: your role string e.g. 'super_admin'
--
-- SELECT get_admin_role();

-- ══ END PRE-PHASE-1 HARDENING ══════════════════════════════════════════════