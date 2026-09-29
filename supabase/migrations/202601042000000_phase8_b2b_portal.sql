-- =============================================================================
-- MIGRATION: 202601042000000_phase8_b2b_portal.sql
-- Phase 8 — B2B Partner Portal
-- Additive only. Creates partner auth linkage, inquiries, portal RLS.
-- =============================================================================

-- ── 1. PARTNER PORTAL USERS ───────────────────────────────────────────────────
-- Links a Supabase auth.users account to a b2b_partners record.
-- One partner company can have multiple portal users (contacts).
CREATE TABLE IF NOT EXISTS partner_portal_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  partner_id    UUID NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  contact_id    UUID REFERENCES partner_contacts(id) ON DELETE SET NULL,
  role          TEXT NOT NULL DEFAULT 'member'
                CHECK (role IN ('admin','member','readonly')),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  invited_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  invited_at    TIMESTAMPTZ DEFAULT now(),
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, partner_id)
);

CREATE INDEX IF NOT EXISTS idx_ppu_user    ON partner_portal_users(user_id);
CREATE INDEX IF NOT EXISTS idx_ppu_partner ON partner_portal_users(partner_id);

ALTER TABLE partner_portal_users ENABLE ROW LEVEL SECURITY;
-- Admin sees all
CREATE POLICY "ppu_admin" ON partner_portal_users FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
-- Partner user sees own record
CREATE POLICY "ppu_self" ON partner_portal_users FOR SELECT
  USING (user_id = auth.uid());

-- ── 2. PARTNER INQUIRIES ──────────────────────────────────────────────────────
-- Structured inquiry submitted by partner through portal → creates CRM lead
CREATE TABLE IF NOT EXISTS partner_inquiries (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  inquiry_number   TEXT UNIQUE,                    -- AUTO: INQ-YYYY-NNNN
  partner_id       UUID NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  submitted_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Trip details
  title            TEXT NOT NULL,
  destination      TEXT,
  travel_date_from DATE,
  travel_date_to   DATE,
  adults_count     INT DEFAULT 1,
  children_count   INT DEFAULT 0,
  infants_count    INT DEFAULT 0,
  hotel_class      TEXT,                           -- 3*/4*/5*/any
  transport_needed BOOLEAN DEFAULT TRUE,
  guide_needed     BOOLEAN DEFAULT FALSE,
  special_requests TEXT,
  budget_per_pax   NUMERIC(14,2),
  budget_currency  TEXT DEFAULT 'EGP',

  -- Linked CRM (set by admin after processing)
  lead_id          UUID REFERENCES leads(id) ON DELETE SET NULL,
  opportunity_id   UUID REFERENCES opportunities(id) ON DELETE SET NULL,

  -- Lifecycle
  status           TEXT NOT NULL DEFAULT 'new'
                   CHECK (status IN ('new','acknowledged','in_progress','quoted','won','lost','cancelled')),
  admin_notes      TEXT,                           -- internal only — never sent to portal
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS inquiry_seq START 1;

CREATE OR REPLACE FUNCTION generate_inquiry_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.inquiry_number IS NULL THEN
    NEW.inquiry_number := 'INQ-' || to_char(now(),'YYYY') || '-' ||
                          lpad(nextval('inquiry_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_inquiry_number ON partner_inquiries;
CREATE TRIGGER trg_inquiry_number
  BEFORE INSERT ON partner_inquiries
  FOR EACH ROW EXECUTE FUNCTION generate_inquiry_number();

DROP TRIGGER IF EXISTS trg_partner_inquiries_updated_at ON partner_inquiries;
CREATE TRIGGER trg_partner_inquiries_updated_at
  BEFORE UPDATE ON partner_inquiries
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE partner_inquiries ENABLE ROW LEVEL SECURITY;
-- Admin sees all
CREATE POLICY "pi_admin" ON partner_inquiries FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
-- Partner sees own inquiries
CREATE POLICY "pi_partner_read" ON partner_inquiries FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = partner_id
        AND ppu.is_active = TRUE
    )
  );
-- Partner can insert own inquiries
CREATE POLICY "pi_partner_insert" ON partner_inquiries FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = partner_id
        AND ppu.is_active = TRUE
    )
  );

CREATE INDEX IF NOT EXISTS idx_pi_partner ON partner_inquiries(partner_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pi_status  ON partner_inquiries(status);

-- ── 3. PARTNER QUOTE ACTIONS ──────────────────────────────────────────────────
-- Partner approves/rejects/comments on quotes sent to them
CREATE TABLE IF NOT EXISTS partner_quote_actions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id    UUID NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  partner_id  UUID NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  user_id     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  action      TEXT NOT NULL
              CHECK (action IN ('viewed','approved','rejected','revision_requested','commented')),
  comment     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pqa_quote   ON partner_quote_actions(quote_id);
CREATE INDEX IF NOT EXISTS idx_pqa_partner ON partner_quote_actions(partner_id);

ALTER TABLE partner_quote_actions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pqa_admin" ON partner_quote_actions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "pqa_partner_read" ON partner_quote_actions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = partner_id
        AND ppu.is_active = TRUE
    )
  );
CREATE POLICY "pqa_partner_insert" ON partner_quote_actions FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = partner_id
        AND ppu.is_active = TRUE
    )
  );

-- ── 4. LINK quotations TO b2b_partners ───────────────────────────────────────
-- Add partner_id to quotations so we know which quotes belong to which partner
ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS partner_id UUID REFERENCES b2b_partners(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_quotations_partner ON quotations(partner_id) WHERE partner_id IS NOT NULL;

-- Partner can read their own quotes (hide cost_total, gross_profit, margin_pct — done in RPC)
CREATE POLICY "quotations_partner_read" ON quotations FOR SELECT
  USING (
    partner_id IS NOT NULL AND
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = quotations.partner_id
        AND ppu.is_active = TRUE
    )
  );

-- ── 5. LINK bookings TO b2b_partners ─────────────────────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS partner_id UUID REFERENCES b2b_partners(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_partner ON bookings(partner_id) WHERE partner_id IS NOT NULL;

-- Partner can read their own bookings (limited fields via RPC)
CREATE POLICY "bookings_partner_read" ON bookings FOR SELECT
  USING (
    partner_id IS NOT NULL AND
    EXISTS (
      SELECT 1 FROM partner_portal_users ppu
      WHERE ppu.user_id = auth.uid()
        AND ppu.partner_id = bookings.partner_id
        AND ppu.is_active = TRUE
    )
  );

-- ── 6. HELPER FUNCTION — get current user's partner_id ───────────────────────
CREATE OR REPLACE FUNCTION get_my_partner_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT partner_id FROM partner_portal_users
  WHERE user_id = auth.uid() AND is_active = TRUE
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_my_partner_id() TO authenticated;

-- ── 7. RPC — partner portal dashboard summary ─────────────────────────────────
-- Returns counts visible to the logged-in partner user (no internal financials)
CREATE OR REPLACE FUNCTION get_partner_dashboard()
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_partner_id UUID;
  v_result JSON;
BEGIN
  v_partner_id := get_my_partner_id();
  IF v_partner_id IS NULL THEN
    RETURN '{"error":"not_a_partner"}'::JSON;
  END IF;

  SELECT json_build_object(
    'partner_id',        v_partner_id,
    'open_inquiries',    (SELECT count(*) FROM partner_inquiries
                          WHERE partner_id = v_partner_id AND status NOT IN ('won','lost','cancelled')),
    'pending_quotes',    (SELECT count(*) FROM quotations
                          WHERE partner_id = v_partner_id AND status IN ('sent','viewed','revision_requested','negotiation')),
    'active_bookings',   (SELECT count(*) FROM bookings
                          WHERE partner_id = v_partner_id AND status IN ('confirmed','pending')),
    'completed_bookings',(SELECT count(*) FROM bookings
                          WHERE partner_id = v_partner_id AND status = 'completed'),
    'total_invoices',    (SELECT count(*) FROM nsp_invoices i
                          JOIN bookings b ON b.id = i.booking_id
                          WHERE b.partner_id = v_partner_id),
    'outstanding_amount',(SELECT COALESCE(sum(remaining_amount),0) FROM nsp_invoices i
                          JOIN bookings b ON b.id = i.booking_id
                          WHERE b.partner_id = v_partner_id AND i.status NOT IN ('paid','cancelled'))
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_dashboard() TO authenticated;

-- ── 8. RPC — partner quotes (strips internal cost/margin) ─────────────────────
CREATE OR REPLACE FUNCTION get_partner_quotes()
RETURNS TABLE (
  id               UUID,
  quote_number     TEXT,
  title            TEXT,
  destination      TEXT,
  travel_date_from DATE,
  travel_date_to   DATE,
  adults_count     INT,
  children_count   INT,
  currency         TEXT,
  total_amount     NUMERIC,
  status           TEXT,
  validity_date    DATE,
  payment_terms    TEXT,
  cancellation_policy TEXT,
  included_services TEXT,
  excluded_services TEXT,
  client_notes     TEXT,
  sent_at          TIMESTAMPTZ,
  created_at       TIMESTAMPTZ,
  version          INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_partner_id UUID;
BEGIN
  v_partner_id := get_my_partner_id();
  IF v_partner_id IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    q.id, q.quote_number, q.title, q.destination,
    q.travel_date_from, q.travel_date_to,
    q.adults_count, q.children_count,
    q.currency, q.total_amount,
    q.status, q.validity_date, q.payment_terms,
    q.cancellation_policy, q.included_services,
    q.excluded_services, q.client_notes,
    q.sent_at, q.created_at, q.version
    -- cost_total, gross_profit, margin_pct intentionally excluded
  FROM quotations q
  WHERE q.partner_id = v_partner_id
    AND q.status NOT IN ('draft','internal_review')
  ORDER BY q.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_quotes() TO authenticated;

-- ── 9. RPC — partner bookings (limited fields) ────────────────────────────────
CREATE OR REPLACE FUNCTION get_partner_bookings()
RETURNS TABLE (
  id               UUID,
  booking_number   TEXT,
  customer_name    TEXT,
  status           TEXT,
  total_price      NUMERIC,
  paid_amount      NUMERIC,
  remaining_amount NUMERIC,
  created_at       TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_partner_id UUID;
BEGIN
  v_partner_id := get_my_partner_id();
  IF v_partner_id IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    b.id, b.booking_number, b.customer_name,
    b.status, b.total_price, b.paid_amount, b.remaining_amount,
    b.created_at
  FROM bookings b
  WHERE b.partner_id = v_partner_id
  ORDER BY b.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_partner_bookings() TO authenticated;

-- ── 10. PERMISSIONS ───────────────────────────────────────────────────────────
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('manage_partner_portal', 'إدارة بوابة الشركاء', 'الشراكات',
    ARRAY['super_admin','admin']),
  ('invite_partner_users',  'دعوة مستخدمي الشركاء', 'الشراكات',
    ARRAY['super_admin','admin','sales_agent'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- ── 11. UPDATE admin nav — add portal management link ─────────────────────────
-- (done in admin-nav.js patch below)

-- =============================================================================
-- Phase 8 B2B Portal schema — COMPLETE
-- New tables: partner_portal_users, partner_inquiries, partner_quote_actions
-- Modified:   quotations.partner_id, bookings.partner_id
-- New RPCs:   get_my_partner_id, get_partner_dashboard,
--             get_partner_quotes, get_partner_bookings
-- =============================================================================
