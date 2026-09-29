-- ============================================================
-- Migration 037 — Phase Q: Production Cleanup
--
-- M7: Deactivate demo seed package from migration 023.
--     DO NOT delete — migration 023 may already be applied
--     and the data is preserved. We simply mark it inactive
--     so it does not appear on the public storefront.
--     A super_admin can reactivate if needed via the admin panel.
--
-- M3: nsp-control-8x4k/admin.js duplicate — handled in filesystem
--     (file deleted from repo, not a DB migration concern).
--
-- M4: Root ai-assistant/ directory — handled in filesystem
--     (directory deleted from repo).
--
-- M8: Migration gap at 024 — documented here. Do NOT fill the gap
--     retroactively. The gap was created when pre-phase-1-hardening
--     (016) and CRM foundation (025) were numbered non-sequentially.
--     Adding a migration at 024 now would conflict with any Supabase
--     projects that already ran 025+. Gap is safe and intentional.
--
-- Safe: UPDATE only (no DROP, no DELETE of rows with potential data)
-- Run after: 202601036000000_phase_e_security_definer.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- M7: Deactivate demo package inserted by migration 023
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE packages
SET    is_active = FALSE
WHERE  title = 'برنامج العمرة المتميز — 14 ليلة (نموذج)'
  AND  is_active = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- PERMISSION_MATRIX: ensure AI permissions exist for all roles
-- (idempotent — uses WHERE NOT EXISTS; UNIQUE constraint added in 033)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_matrix (permission, roles)
SELECT p.permission, p.roles
FROM (VALUES
  ('use_ai_sales',       ARRAY['super_admin','admin','sales_agent','booking_agent','financial_manager']),
  ('use_ai_operations',  ARRAY['super_admin','admin','booking_agent','sales_agent','financial_manager']),
  ('use_ai_finance',     ARRAY['super_admin','admin','financial_manager','accountant']),
  ('view_ai_dashboard',  ARRAY['super_admin','admin','financial_manager']),
  ('use_ai_command_center', ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent']),
  ('manage_ai_config',   ARRAY['super_admin'])
) AS p(permission, roles)
WHERE NOT EXISTS (
  SELECT 1 FROM permission_matrix pm WHERE pm.permission = p.permission
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Scheduled housekeeping: purge expired AI cache entries
-- Creates a pg_cron job if pg_cron extension is available.
-- If not available (Supabase free tier), this block is silently skipped.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) THEN
    PERFORM cron.schedule(
      'purge-ai-cache',
      '0 3 * * *',   -- 03:00 UTC daily
      'SELECT purge_expired_cache()'
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  NULL; -- pg_cron not available, skip silently
END;
$$;


-- ══ END PHASE Q MIGRATION ══════════════════════════════════════════════════
-- Verification:
--   SELECT COUNT(*) FROM packages WHERE title = 'برنامج العمرة المتميز — 14 ليلة (نموذج)' AND is_active = TRUE;
--   → 0 (demo package deactivated)
--
--   SELECT permission FROM permission_matrix WHERE permission LIKE 'use_ai%' OR permission LIKE 'view_ai%' OR permission LIKE 'manage_ai%';
--   → 6 rows
