-- ═══════════════════════════════════════════════════════════════════════════
-- PHASE 8 — B2B Partner Portal
-- Migration: 202601041000000_phase8_b2b_portal.sql
-- Additive. Extends b2b_partners with auth link + adds partner_inquiries table.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 1. Link b2b_partners to Supabase Auth user ──────────────────────────
-- A partner contact can be invited and gets a Supabase auth.users row.
-- Multiple contacts from same partner share partner_id via partner_users table.

ALTER TABLE b2b_partners
  ADD COLUMN IF NOT EXISTS portal_enabled BOOLEAN NOT NULL DEFAULT FALSE;

-- One Supabase user can belong to one partner (or be a staff member)
CREATE TABLE IF NOT EXISTS partner_users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  partner_id  UUID NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  role        TEXT NOT NULL DEFAULT 'viewer'
              CHECK (role IN ('owner','manager','viewer')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  invited_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_partner_users_user    ON partner_users(user_id);
CREATE INDEX IF NOT EXISTS idx_partner_users_partner ON partner_users(partner_id);

ALTER TABLE partner_users ENABLE ROW LEVEL SECURITY;
-- Admins manage all; partners see only their own row
CREATE POLICY "partner_users_admin_all" ON partner_users FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "partner_users_self_read" ON partner_users FOR SELECT
  USING (user_id = auth.uid());

-- ─── 2. Helper: get partner_id for current auth user ─────────────────────
CREATE OR REPLACE FUNCTION get_my_partner_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT partner_id FROM partner_users
  WHERE user_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION get_my_partner_id() TO authenticated;

-- ─── 3. Partner Inquiries ─────────────────────────────────────────────────
-- Partners submit inquiries from the portal; these become leads internally.
CREATE TABLE IF NOT EXISTS partner_inquiries (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  inquiry_number  TEXT        UNIQUE,
  partner_id      UUID        NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  submitted_by    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Trip details
  title           TEXT        NOT NULL,
  destination     TEXT        NOT NULL,
  travel_date_from DATE,
  travel_date_to  DATE,
  dates_flexible  BOOLEAN     NOT NULL DEFAULT FALSE,
  adults_count    INT         NOT NULL DEFAULT 1,
  children_count  INT         NOT NULL DEFAULT 0,
  infants_count   INT         NOT NULL DEFAULT 0,
  rooming_details TEXT,       -- freetext or JSON
  hotel_class     TEXT,
  transport       TEXT,
  guide_language  TEXT,
  activities      TEXT,
  budget          NUMERIC(14,2),
  currency        TEXT        NOT NULL DEFAULT 'EGP',
  special_requests TEXT,

  -- Lifecycle
  status          TEXT        NOT NULL DEFAULT 'submitted'
                  CHECK (status IN ('submitted','acknowledged','in_progress','quoted','confirmed','rejected','cancelled')),
  assigned_to     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,  -- internal sales agent
  lead_id         UUID        REFERENCES leads(id) ON DELETE SET NULL,        -- created from this inquiry
  quotation_id    UUID        REFERENCES quotations(id) ON DELETE SET NULL,   -- quote sent for this inquiry

  internal_notes  TEXT,       -- staff only, never shown to partner

  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS partner_inquiry_seq START 1;

CREATE OR REPLACE FUNCTION fn_set_inquiry_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.inquiry_number IS NULL THEN
    NEW.inquiry_number := 'INQ-' || TO_CHAR(NOW(),'YYYY') || '-' || LPAD(NEXTVAL('partner_inquiry_seq')::TEXT,5,'0');
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_inquiry_number
  BEFORE INSERT ON partner_inquiries
  FOR EACH ROW EXECUTE FUNCTION fn_set_inquiry_number();

CREATE TRIGGER trg_partner_inquiries_updated_at
  BEFORE UPDATE ON partner_inquiries
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE INDEX IF NOT EXISTS idx_partner_inquiries_partner  ON partner_inquiries(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_inquiries_status   ON partner_inquiries(status);
CREATE INDEX IF NOT EXISTS idx_partner_inquiries_assigned ON partner_inquiries(assigned_to);

ALTER TABLE partner_inquiries ENABLE ROW LEVEL SECURITY;

-- Admin: full access
CREATE POLICY "partner_inquiries_admin" ON partner_inquiries FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- Partner: see only their own partner's inquiries
CREATE POLICY "partner_inquiries_own_read" ON partner_inquiries FOR SELECT
  USING (partner_id = get_my_partner_id());

CREATE POLICY "partner_inquiries_own_insert" ON partner_inquiries FOR INSERT
  WITH CHECK (partner_id = get_my_partner_id());

CREATE POLICY "partner_inquiries_own_update" ON partner_inquiries FOR UPDATE
  USING (partner_id = get_my_partner_id() AND status IN ('submitted'));

-- ─── 4. Partner Quote Actions (partner comments/approvals on quotations) ──
CREATE TABLE IF NOT EXISTS partner_quote_actions (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id  UUID        NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  partner_id    UUID        NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  action        TEXT        NOT NULL
                CHECK (action IN ('viewed','comment','revision_requested','approved','rejected')),
  comment       TEXT,
  created_by    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_partner_quote_actions_quote   ON partner_quote_actions(quotation_id);
CREATE INDEX IF NOT EXISTS idx_partner_quote_actions_partner ON partner_quote_actions(partner_id);

ALTER TABLE partner_quote_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pqa_admin" ON partner_quote_actions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE POLICY "pqa_partner_read" ON partner_quote_actions FOR SELECT
  USING (partner_id = get_my_partner_id());

CREATE POLICY "pqa_partner_insert" ON partner_quote_actions FOR INSERT
  WITH CHECK (partner_id = get_my_partner_id());

-- ─── 5. Extend quotations with b2b_partner_id ────────────────────────────
ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS b2b_partner_id UUID REFERENCES b2b_partners(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS partner_token  TEXT UNIQUE;  -- secure shareable link token

CREATE INDEX IF NOT EXISTS idx_quotations_b2b_partner ON quotations(b2b_partner_id) WHERE b2b_partner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quotations_token       ON quotations(partner_token)   WHERE partner_token IS NOT NULL;

-- RLS: partner can read their own quotes
CREATE POLICY "quotations_partner_read" ON quotations FOR SELECT
  USING (b2b_partner_id = get_my_partner_id() AND status NOT IN ('draft','internal_review'));

-- ─── 6. Extend bookings with b2b_partner_id ──────────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS b2b_partner_id UUID REFERENCES b2b_partners(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_b2b_partner ON bookings(b2b_partner_id) WHERE b2b_partner_id IS NOT NULL;

-- RLS: partner can read their own bookings
CREATE POLICY "bookings_partner_read" ON bookings FOR SELECT
  USING (b2b_partner_id = get_my_partner_id());

-- ─── 7. Partner Statements (finance view) ────────────────────────────────
-- View combining invoices + payments for a partner — partners see no internal cost
CREATE OR REPLACE VIEW partner_statement AS
SELECT
  p.id            AS partner_id,
  p.legal_name,
  p.currency,
  p.credit_limit,
  COALESCE(SUM(CASE WHEN i.status != 'cancelled' THEN i.total_amount END), 0) AS total_invoiced,
  COALESCE(SUM(CASE WHEN i.status = 'paid' THEN i.total_amount
                    WHEN i.status = 'partial' THEN i.paid_amount END), 0)      AS total_paid,
  COALESCE(SUM(CASE WHEN i.status IN ('sent','partial','overdue') THEN i.remaining_amount END), 0) AS outstanding
FROM b2b_partners p
LEFT JOIN invoices i ON i.b2b_partner_id = p.id
WHERE p.portal_enabled = TRUE
GROUP BY p.id, p.legal_name, p.currency, p.credit_limit;

-- ─── 8. Extend invoices with b2b_partner_id ──────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'invoices') THEN
    ALTER TABLE invoices ADD COLUMN IF NOT EXISTS b2b_partner_id UUID REFERENCES b2b_partners(id) ON DELETE SET NULL;
    CREATE INDEX IF NOT EXISTS idx_invoices_b2b_partner ON invoices(b2b_partner_id) WHERE b2b_partner_id IS NOT NULL;
  END IF;
END $$;

-- ─── 9. Permissions ──────────────────────────────────────────────────────
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('manage_partner_portal',  'إدارة بوابة الشركاء',      'الشراكات', ARRAY['super_admin','admin']),
  ('invite_partner_users',   'دعوة مستخدمي الشركاء',     'الشراكات', ARRAY['super_admin','admin','sales_agent']),
  ('view_partner_inquiries', 'عرض استفسارات الشركاء',    'الشراكات', ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('manage_partner_inquiries','إدارة استفسارات الشركاء', 'الشراكات', ARRAY['super_admin','admin','sales_agent'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- ═══ END PHASE 8 PORTAL ══════════════════════════════════════════════════
