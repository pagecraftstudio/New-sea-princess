-- ============================================================
-- Migration 052 — Phase 16: Groups, Series Tours, Corporate & MICE
--
-- New tables:
--   group_files             — master group travel file
--   rooming_list            — room assignments per group
--   passenger_manifest      — traveler details per group
--   series_tours            — recurring tour templates
--   series_departures       — individual departures per series
--   corporate_accounts      — corporate client companies
--   corporate_travel_requests — employee travel requests
--   mice_events             — MICE/incentive event files
--   mice_budget_items       — line-item budget for MICE events
--
-- Extends:
--   bookings                — add group_id, series_departure_id
--
-- Safe: additive only
-- Run after: 202601051000000_phase15_sales_intelligence.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. GROUP FILES
--    Master record for group travel. Multiple bookings can link
--    to one group_file (group leader + members).
-- ─────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS group_file_seq START 1;

CREATE TABLE IF NOT EXISTS group_files (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_number    TEXT        UNIQUE,               -- AUTO: GRP-YYYY-NNNN
  name            TEXT        NOT NULL,             -- e.g. "مجموعة كلية الطب — أكتوبر 2026"

  -- Links
  b2b_partner_id  UUID        REFERENCES b2b_partners(id) ON DELETE SET NULL,
  customer_id     UUID        REFERENCES customers(id)    ON DELETE SET NULL,
  opportunity_id  UUID        REFERENCES opportunities(id) ON DELETE SET NULL,
  quotation_id    UUID        REFERENCES quotations(id)   ON DELETE SET NULL,

  -- Group leader contact
  leader_name     TEXT,
  leader_phone    TEXT,
  leader_email    TEXT,
  leader_whatsapp TEXT,

  -- Travel details
  destination     TEXT,
  travel_date_from DATE,
  travel_date_to   DATE,
  pax_total       INT         NOT NULL DEFAULT 1,
  adults_count    INT         DEFAULT 0,
  children_count  INT         DEFAULT 0,
  infants_count   INT         DEFAULT 0,
  rooms_count     INT         DEFAULT 0,

  -- Logistics
  flight_number   TEXT,
  airline         TEXT,
  arrival_airport TEXT,
  departure_airport TEXT,
  hotel_name      TEXT,
  transport_type  TEXT,
  guide_name      TEXT,
  guide_phone     TEXT,

  -- Financials
  currency        TEXT        DEFAULT 'EGP',
  total_price     NUMERIC(14,2) DEFAULT 0,
  deposit_amount  NUMERIC(14,2) DEFAULT 0,
  deposit_paid    NUMERIC(14,2) DEFAULT 0,
  balance_due     NUMERIC(14,2) DEFAULT 0,
  balance_due_date DATE,

  -- Status
  status          TEXT        NOT NULL DEFAULT 'inquiry'
                              CHECK (status IN (
                                'inquiry','quoted','deposit_pending','confirmed',
                                'in_operation','completed','cancelled'
                              )),
  group_type      TEXT        NOT NULL DEFAULT 'leisure'
                              CHECK (group_type IN (
                                'leisure','educational','corporate','religious',
                                'incentive','mice','sports','medical','other'
                              )),
  notes           TEXT,
  internal_notes  TEXT,

  created_by      UUID        REFERENCES auth.users(id),
  assigned_to     UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE group_files ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gf_admin" ON group_files FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "gf_agent" ON group_files FOR SELECT
  USING (assigned_to = auth.uid() OR created_by = auth.uid());

CREATE INDEX IF NOT EXISTS idx_gf_status  ON group_files(status);
CREATE INDEX IF NOT EXISTS idx_gf_partner ON group_files(b2b_partner_id) WHERE b2b_partner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_gf_dates   ON group_files(travel_date_from, travel_date_to);

CREATE OR REPLACE FUNCTION generate_group_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.group_number IS NULL THEN
    NEW.group_number := 'GRP-' || to_char(now(),'YYYY') || '-'
                      || lpad(nextval('group_file_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS trg_group_number ON group_files;
CREATE TRIGGER trg_group_number
  BEFORE INSERT ON group_files
  FOR EACH ROW EXECUTE FUNCTION generate_group_number();


-- ─────────────────────────────────────────────────────────────
-- 2. ROOMING LIST
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rooming_list (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID        NOT NULL REFERENCES group_files(id) ON DELETE CASCADE,
  room_number     INT         NOT NULL,
  room_type       TEXT        NOT NULL DEFAULT 'double'
                              CHECK (room_type IN ('single','double','triple','quad','suite','family','twin')),
  bed_type        TEXT        CHECK (bed_type IN ('king','twin','bunk','sofa_bed','rollaway')),
  meal_plan       TEXT        DEFAULT 'breakfast'
                              CHECK (meal_plan IN ('room_only','breakfast','half_board','full_board','all_inclusive')),
  floor_preference TEXT,
  special_requests TEXT,
  -- Occupants (up to 4 per room)
  occupant_1_name TEXT,
  occupant_1_passport TEXT,
  occupant_2_name TEXT,
  occupant_2_passport TEXT,
  occupant_3_name TEXT,
  occupant_3_passport TEXT,
  occupant_4_name TEXT,
  occupant_4_passport TEXT,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE rooming_list ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rl_admin" ON rooming_list FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_rl_group ON rooming_list(group_id, room_number);


-- ─────────────────────────────────────────────────────────────
-- 3. PASSENGER MANIFEST
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS passenger_manifest (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID        NOT NULL REFERENCES group_files(id) ON DELETE CASCADE,
  seq_number      INT,                              -- passenger number within group
  full_name       TEXT        NOT NULL,
  full_name_en    TEXT,
  nationality     TEXT,
  date_of_birth   DATE,
  gender          TEXT        CHECK (gender IN ('male','female')),
  passport_number TEXT,
  passport_expiry DATE,
  visa_number     TEXT,
  visa_expiry     DATE,
  room_number     INT,                              -- links to rooming_list.room_number
  seat_number     TEXT,                             -- flight seat
  flight_pnr      TEXT,
  meal_preference TEXT,
  emergency_contact_name  TEXT,
  emergency_contact_phone TEXT,
  has_special_needs BOOLEAN DEFAULT FALSE,
  special_needs_notes TEXT,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE passenger_manifest ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pm_admin" ON passenger_manifest FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_pm_group ON passenger_manifest(group_id, seq_number);


-- ─────────────────────────────────────────────────────────────
-- 4. SERIES TOURS
--    Recurring tour templates (e.g. Jordan 7D every Sunday)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS series_tours (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT        UNIQUE,               -- e.g. JOR-7D
  name            TEXT        NOT NULL,
  destination     TEXT,
  duration_nights INT         NOT NULL DEFAULT 1,
  itinerary_id    UUID        REFERENCES itineraries(id) ON DELETE SET NULL,
  capacity        INT         NOT NULL DEFAULT 20,
  hotel_name      TEXT,
  transport_type  TEXT,
  guide_required  BOOLEAN     DEFAULT TRUE,
  base_price      NUMERIC(14,2) DEFAULT 0,
  currency        TEXT        DEFAULT 'EGP',
  season_start    DATE,
  season_end      DATE,
  departure_days  TEXT[],                           -- ['sunday','wednesday']
  is_active       BOOLEAN     DEFAULT TRUE,
  notes           TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE series_tours ENABLE ROW LEVEL SECURITY;
CREATE POLICY "st_admin" ON series_tours FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_st_active ON series_tours(is_active) WHERE is_active = TRUE;


-- ─────────────────────────────────────────────────────────────
-- 5. SERIES DEPARTURES
--    Each individual departure from a series template
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS series_departures (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id       UUID        NOT NULL REFERENCES series_tours(id) ON DELETE CASCADE,
  departure_date  DATE        NOT NULL,
  return_date     DATE,
  capacity        INT         NOT NULL DEFAULT 20,
  booked_count    INT         DEFAULT 0,
  available_seats INT         GENERATED ALWAYS AS (capacity - booked_count) STORED,
  status          TEXT        NOT NULL DEFAULT 'open'
                              CHECK (status IN ('open','sold_out','closed','cancelled','completed')),
  actual_guide_name TEXT,
  actual_hotel    TEXT,
  flight_number   TEXT,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (series_id, departure_date)
);

ALTER TABLE series_departures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sd_admin" ON series_departures FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_sd_series ON series_departures(series_id, departure_date);
CREATE INDEX IF NOT EXISTS idx_sd_date   ON series_departures(departure_date) WHERE status = 'open';


-- ─────────────────────────────────────────────────────────────
-- 6. CORPORATE ACCOUNTS
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS corporate_accounts (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_number    TEXT        UNIQUE,             -- AUTO: CORP-YYYY-NNNN
  company_name      TEXT        NOT NULL,
  industry          TEXT,
  country           TEXT,
  city              TEXT,
  address           TEXT,
  website           TEXT,
  tax_number        TEXT,

  -- Primary contacts
  primary_contact_name  TEXT,
  primary_contact_email TEXT,
  primary_contact_phone TEXT,
  finance_contact_name  TEXT,
  finance_contact_email TEXT,
  hr_contact_name       TEXT,
  hr_contact_email      TEXT,

  -- Commercial terms
  currency            TEXT    DEFAULT 'EGP',
  credit_limit        NUMERIC(14,2) DEFAULT 0,
  payment_terms_days  INT     DEFAULT 30,
  credit_balance      NUMERIC(14,2) DEFAULT 0,

  -- Travel policy
  max_hotel_class     TEXT    CHECK (max_hotel_class IN ('3','4','5','any')),
  preferred_airline   TEXT,
  preferred_hotel_chain TEXT,
  cost_center_required BOOLEAN DEFAULT FALSE,
  manager_approval_required BOOLEAN DEFAULT TRUE,
  manager_approval_threshold NUMERIC(14,2) DEFAULT 0,  -- above this amount needs approval

  -- Account manager
  account_manager_id  UUID    REFERENCES admin_users(id) ON DELETE SET NULL,

  status              TEXT    NOT NULL DEFAULT 'active'
                              CHECK (status IN ('prospect','active','inactive','suspended')),
  notes               TEXT,
  created_by          UUID    REFERENCES auth.users(id),
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE corporate_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ca_admin" ON corporate_accounts FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_ca_status ON corporate_accounts(status);

CREATE SEQUENCE IF NOT EXISTS corporate_account_seq START 1;
CREATE OR REPLACE FUNCTION generate_corporate_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.account_number IS NULL THEN
    NEW.account_number := 'CORP-' || to_char(now(),'YYYY') || '-'
                        || lpad(nextval('corporate_account_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS trg_corp_number ON corporate_accounts;
CREATE TRIGGER trg_corp_number
  BEFORE INSERT ON corporate_accounts
  FOR EACH ROW EXECUTE FUNCTION generate_corporate_number();


-- ─────────────────────────────────────────────────────────────
-- 7. CORPORATE TRAVEL REQUESTS
--    Employee → Manager → Travel Desk workflow
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS corporate_travel_requests (
  id                  UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  request_number      TEXT    UNIQUE,               -- AUTO: CTR-YYYY-NNNN
  corporate_id        UUID    NOT NULL REFERENCES corporate_accounts(id) ON DELETE CASCADE,

  -- Requester
  employee_name       TEXT    NOT NULL,
  employee_email      TEXT,
  employee_department TEXT,
  cost_center         TEXT,

  -- Trip details
  destination         TEXT,
  travel_date_from    DATE,
  travel_date_to      DATE,
  travelers_count     INT     DEFAULT 1,
  purpose             TEXT,
  estimated_budget    NUMERIC(14,2),
  currency            TEXT    DEFAULT 'EGP',
  hotel_class_required TEXT,
  flight_class        TEXT    DEFAULT 'economy'
                              CHECK (flight_class IN ('economy','business','first')),
  notes               TEXT,

  -- Approval workflow
  status              TEXT    NOT NULL DEFAULT 'pending'
                              CHECK (status IN (
                                'pending','manager_approved','manager_rejected',
                                'travel_desk','quoted','booking_confirmed','completed','cancelled'
                              )),
  manager_name        TEXT,
  manager_email       TEXT,
  manager_approved_at TIMESTAMPTZ,
  manager_notes       TEXT,

  -- Links
  quotation_id        UUID    REFERENCES quotations(id) ON DELETE SET NULL,
  booking_id          UUID    REFERENCES bookings(id)   ON DELETE SET NULL,

  handled_by          UUID    REFERENCES admin_users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE corporate_travel_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ctr_admin" ON corporate_travel_requests FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_ctr_corp   ON corporate_travel_requests(corporate_id, status);
CREATE INDEX IF NOT EXISTS idx_ctr_status ON corporate_travel_requests(status);

CREATE SEQUENCE IF NOT EXISTS corporate_request_seq START 1;
CREATE OR REPLACE FUNCTION generate_corporate_request_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.request_number IS NULL THEN
    NEW.request_number := 'CTR-' || to_char(now(),'YYYY') || '-'
                        || lpad(nextval('corporate_request_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS trg_ctr_number ON corporate_travel_requests;
CREATE TRIGGER trg_ctr_number
  BEFORE INSERT ON corporate_travel_requests
  FOR EACH ROW EXECUTE FUNCTION generate_corporate_request_number();


-- ─────────────────────────────────────────────────────────────
-- 8. MICE EVENTS
-- ─────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS mice_event_seq START 1;

CREATE TABLE IF NOT EXISTS mice_events (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_number    TEXT        UNIQUE,               -- AUTO: MICE-YYYY-NNNN
  event_name      TEXT        NOT NULL,
  event_type      TEXT        NOT NULL DEFAULT 'conference'
                              CHECK (event_type IN (
                                'conference','meeting','incentive','exhibition',
                                'team_building','gala','workshop','product_launch','other'
                              )),

  -- Client
  corporate_id    UUID        REFERENCES corporate_accounts(id) ON DELETE SET NULL,
  b2b_partner_id  UUID        REFERENCES b2b_partners(id)       ON DELETE SET NULL,
  client_name     TEXT,
  client_contact  TEXT,
  client_email    TEXT,

  -- Event details
  destination     TEXT,
  venue_name      TEXT,
  venue_address   TEXT,
  start_date      DATE,
  end_date        DATE,
  delegates_count INT         NOT NULL DEFAULT 1,
  setup_days      INT         DEFAULT 0,
  teardown_days   INT         DEFAULT 0,

  -- Services required (flags)
  needs_accommodation BOOLEAN DEFAULT TRUE,
  needs_transport     BOOLEAN DEFAULT TRUE,
  needs_catering      BOOLEAN DEFAULT TRUE,
  needs_av            BOOLEAN DEFAULT FALSE,
  needs_activities    BOOLEAN DEFAULT FALSE,
  needs_staffing      BOOLEAN DEFAULT FALSE,
  needs_translation   BOOLEAN DEFAULT FALSE,

  -- Financials
  currency            TEXT    DEFAULT 'EGP',
  budget_total        NUMERIC(14,2) DEFAULT 0,
  committed_cost      NUMERIC(14,2) DEFAULT 0,
  actual_cost         NUMERIC(14,2) DEFAULT 0,
  revenue             NUMERIC(14,2) DEFAULT 0,
  gross_profit        NUMERIC(14,2)
    GENERATED ALWAYS AS (revenue - actual_cost) STORED,

  -- Status
  status          TEXT        NOT NULL DEFAULT 'inquiry'
                              CHECK (status IN (
                                'inquiry','proposal','confirmed','in_execution',
                                'completed','cancelled'
                              )),
  notes           TEXT,
  internal_notes  TEXT,
  quotation_id    UUID        REFERENCES quotations(id)  ON DELETE SET NULL,

  created_by      UUID        REFERENCES auth.users(id),
  assigned_to     UUID        REFERENCES admin_users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE mice_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "me_admin" ON mice_events FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_me_status ON mice_events(status);
CREATE INDEX IF NOT EXISTS idx_me_dates  ON mice_events(start_date, end_date);

CREATE OR REPLACE FUNCTION generate_mice_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.event_number IS NULL THEN
    NEW.event_number := 'MICE-' || to_char(now(),'YYYY') || '-'
                      || lpad(nextval('mice_event_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS trg_mice_number ON mice_events;
CREATE TRIGGER trg_mice_number
  BEFORE INSERT ON mice_events
  FOR EACH ROW EXECUTE FUNCTION generate_mice_number();


-- ─────────────────────────────────────────────────────────────
-- 9. MICE BUDGET ITEMS
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS mice_budget_items (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  mice_event_id   UUID        NOT NULL REFERENCES mice_events(id) ON DELETE CASCADE,
  category        TEXT        NOT NULL
                              CHECK (category IN (
                                'accommodation','transport','catering','av','activities',
                                'staffing','venue','translation','marketing','other'
                              )),
  description     TEXT        NOT NULL,
  supplier_id     UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  quantity        NUMERIC(8,2) DEFAULT 1,
  unit            TEXT        DEFAULT 'pax',
  budget_amount   NUMERIC(14,2) DEFAULT 0,
  committed_amount NUMERIC(14,2) DEFAULT 0,
  actual_amount   NUMERIC(14,2) DEFAULT 0,
  status          TEXT        DEFAULT 'planned'
                              CHECK (status IN ('planned','requested','confirmed','invoiced','paid')),
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE mice_budget_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "mbi_admin" ON mice_budget_items FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_mbi_event ON mice_budget_items(mice_event_id, category);

-- Auto-update mice_events committed/actual totals
CREATE OR REPLACE FUNCTION sync_mice_budget_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_id UUID := COALESCE(NEW.mice_event_id, OLD.mice_event_id);
BEGIN
  UPDATE mice_events SET
    committed_cost = (SELECT COALESCE(SUM(committed_amount),0) FROM mice_budget_items WHERE mice_event_id = v_id),
    actual_cost    = (SELECT COALESCE(SUM(actual_amount),0)    FROM mice_budget_items WHERE mice_event_id = v_id),
    updated_at     = now()
  WHERE id = v_id;
  RETURN COALESCE(NEW, OLD);
END;$$;
DROP TRIGGER IF EXISTS trg_mice_budget_totals ON mice_budget_items;
CREATE TRIGGER trg_mice_budget_totals
  AFTER INSERT OR UPDATE OR DELETE ON mice_budget_items
  FOR EACH ROW EXECUTE FUNCTION sync_mice_budget_totals();


-- ─────────────────────────────────────────────────────────────
-- 10. Extend bookings with group + series links
-- ─────────────────────────────────────────────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS group_id             UUID REFERENCES group_files(id)      ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS series_departure_id  UUID REFERENCES series_departures(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS corporate_request_id UUID REFERENCES corporate_travel_requests(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_group    ON bookings(group_id)             WHERE group_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_series   ON bookings(series_departure_id)  WHERE series_departure_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_corp_req ON bookings(corporate_request_id) WHERE corporate_request_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────
-- 11. Helper RPCs
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_phase16_summary()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error','unauthorized');
  END IF;
  RETURN json_build_object(
    'active_groups',          (SELECT COUNT(*) FROM group_files     WHERE status NOT IN ('completed','cancelled')),
    'upcoming_departures',    (SELECT COUNT(*) FROM series_departures WHERE departure_date >= CURRENT_DATE AND status = 'open'),
    'active_corporate',       (SELECT COUNT(*) FROM corporate_accounts WHERE status = 'active'),
    'pending_corp_requests',  (SELECT COUNT(*) FROM corporate_travel_requests WHERE status IN ('pending','manager_approved','travel_desk')),
    'active_mice',            (SELECT COUNT(*) FROM mice_events WHERE status NOT IN ('completed','cancelled')),
    'total_group_pax',        (SELECT COALESCE(SUM(pax_total),0) FROM group_files WHERE status NOT IN ('completed','cancelled')),
    'total_mice_revenue',     (SELECT COALESCE(SUM(revenue),0) FROM mice_events)
  );
END;$$;
GRANT EXECUTE ON FUNCTION get_phase16_summary() TO authenticated;


CREATE OR REPLACE FUNCTION get_group_manifest_export(p_group_id UUID)
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error','unauthorized');
  END IF;
  RETURN (
    SELECT json_build_object(
      'group', row_to_json(gf),
      'passengers', (SELECT json_agg(p ORDER BY p.seq_number) FROM passenger_manifest p WHERE p.group_id = p_group_id),
      'rooms', (SELECT json_agg(r ORDER BY r.room_number) FROM rooming_list r WHERE r.group_id = p_group_id)
    )
    FROM group_files gf WHERE gf.id = p_group_id
  );
END;$$;
GRANT EXECUTE ON FUNCTION get_group_manifest_export(UUID) TO authenticated;

-- ══ END PHASE 16 MIGRATION ════════════════════════════════════
-- Verify:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_name IN (
--     'group_files','rooming_list','passenger_manifest',
--     'series_tours','series_departures',
--     'corporate_accounts','corporate_travel_requests',
--     'mice_events','mice_budget_items'
--   );  → 9 rows
