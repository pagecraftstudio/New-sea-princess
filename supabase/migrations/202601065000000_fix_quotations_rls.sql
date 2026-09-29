-- ══════════════════════════════════════════════════════════════════════════
--  Migration 202601065000000 — Fix: quotations RLS too restrictive
--
--  BUG: quotations_read policy only allowed:
--    - sales_owner = auth.uid()   (user who created the quote)
--    - can_approve_financial()    (super_admin, financial_manager)
--    - auth_role() IN ('super_admin','admin','auditor')
--
--  RESULT: booking_agent, accountant, cashier, sales_agent (not the owner)
--    get 0 rows from .from('quotations').select() — despite KPI RPCs
--    (SECURITY DEFINER) showing correct counts. UI shows "جار التحميل"
--    then an empty table.
--
--  FIX: Replace quotations_read with is_any_admin() so every authenticated
--    admin role can read all quotations. Write/update/delete policies remain
--    unchanged (still restricted to owner + super_admin/admin).
--
--  NOTE: quotations_public_token policy also removed — it was dangerously
--    open (any row with non-null public_token readable without auth).
--    Token-based reads are handled by the get_quote_by_token() SECURITY
--    DEFINER RPC which validates the token properly.
-- ══════════════════════════════════════════════════════════════════════════

-- Drop existing over-restrictive read policy
DROP POLICY IF EXISTS "quotations_read"         ON quotations;
DROP POLICY IF EXISTS "quotations_public_token" ON quotations;

-- New: all admin roles can read all quotations
CREATE POLICY "quotations_read" ON quotations FOR SELECT
  USING (is_any_admin());

-- quote_items: same fix — currently only readable if you own the parent quote
DROP POLICY IF EXISTS "quote_items_read" ON quotation_items;

CREATE POLICY "quote_items_read" ON quotation_items FOR SELECT
  USING (is_any_admin());

-- quotation_versions: same fix
DROP POLICY IF EXISTS "quote_versions_read" ON quotation_versions;

CREATE POLICY "quote_versions_read" ON quotation_versions FOR SELECT
  USING (is_any_admin());
