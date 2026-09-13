-- ============================================================
-- Migration 202601061000000 — P1 Corrective: check_automation_cooldown fix
--
-- Root cause:
--   Migration 202601060000000_p1_security_hardening.sql attempted to
--   CREATE OR REPLACE check_automation_cooldown(UUID, UUID) with
--   renamed parameters (p_segment_id, p_rule_id) replacing the original
--   (p_rule_id, p_entity_id) from Phase 14.
--
--   PostgreSQL ERROR 42P13: cannot change name of input parameter
--   "p_rule_id" — you cannot rename parameters with CREATE OR REPLACE.
--
--   Additionally the P1 rewrite referenced table "automation_log"
--   which does not exist; the correct table is "automation_executions"
--   (created in 202601050000000_phase14_marketing_automation.sql).
--
-- Fix:
--   1. DROP the existing function signature
--   2. CREATE the corrected version with proper param names,
--      correct table reference, and P1 security guard
--
-- Semantics:
--   The P1 version changed the function's purpose: instead of checking
--   per-entity execution count (Phase 14 logic), it checks cooldown
--   per rule+segment (P1 logic). We preserve the P1 semantic since
--   it adds authorization and is the intended final form.
--
--   Callers: none found in frontend or edge functions (internal only).
--
-- Safe: DROP + CREATE is idempotent; no data loss.
-- Run after: 202601060000000_p1_security_hardening.sql
-- ============================================================

-- Step 1: Drop the existing overload to allow parameter rename
DROP FUNCTION IF EXISTS check_automation_cooldown(UUID, UUID);

-- Step 2: Recreate with correct parameter names, table reference, and auth guard
CREATE OR REPLACE FUNCTION check_automation_cooldown(
  p_rule_id    UUID,   -- automation rule to check
  p_segment_id UUID    -- segment context (NULL = any segment)
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cooldown_hours INT;
  v_last_run       TIMESTAMPTZ;
BEGIN
  -- Authorization: only admin or users with booking/sales access
  IF NOT (can_read_bookings() OR is_any_admin()) THEN
    RAISE EXCEPTION 'unauthorized: automation cooldown check requires marketing access';
  END IF;

  -- Get rule cooldown period (stored in hours per Phase 14 schema)
  SELECT COALESCE(cooldown_hours, 24) INTO v_cooldown_hours
  FROM automation_rules
  WHERE id = p_rule_id;

  IF NOT FOUND THEN RETURN FALSE; END IF;

  -- Check last successful execution using correct table name
  SELECT MAX(executed_at) INTO v_last_run
  FROM automation_executions
  WHERE rule_id   = p_rule_id
    AND (
      -- Match specific entity context if provided
      p_segment_id IS NULL
      OR entity_id = p_segment_id
    )
    AND status = 'completed';

  -- No prior execution → cooldown not active → allowed
  IF v_last_run IS NULL THEN RETURN TRUE; END IF;

  -- Return TRUE if enough time has passed since last run
  RETURN v_last_run < now() - (v_cooldown_hours || ' hours')::INTERVAL;
END;
$$;

REVOKE ALL ON FUNCTION check_automation_cooldown(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_automation_cooldown(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION check_automation_cooldown(UUID, UUID) IS
'Returns TRUE if the automation rule cooldown has expired and the rule may run again.
p_rule_id: the automation rule to check.
p_segment_id: optional entity/segment context (NULL = global check).
Authorization: requires can_read_bookings() or admin.
Corrective fix for P1 migration parameter rename error (42P13).
References automation_executions table (not automation_log).';

-- ══ END CORRECTIVE MIGRATION ══════════════════════════════════
-- Verify:
--   SELECT routine_name, parameter_name
--   FROM information_schema.parameters
--   WHERE specific_name LIKE '%check_automation_cooldown%'
--   ORDER BY ordinal_position;
--   → p_rule_id (pos 1), p_segment_id (pos 2)
--
--   SELECT check_automation_cooldown(gen_random_uuid(), NULL);
--   → FALSE (rule not found) or TRUE/FALSE based on cooldown
