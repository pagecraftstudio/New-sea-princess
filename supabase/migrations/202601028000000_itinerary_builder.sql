-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 4 MIGRATION — Tailor-Made Itinerary Builder
--  File: supabase/migrations/202601028000000_itinerary_builder.sql
--
--  Purpose: Full itinerary builder — service catalog, trip itineraries,
--           day-by-day structure, service items per day, and linkage to
--           quotations and bookings.
--
--  New tables : service_catalog, itineraries, itinerary_days, itinerary_items
--  Modifies   : quotations  (add itinerary_id nullable FK)
--               bookings    (add itinerary_id nullable FK)
--  Safe       : additive only — no drops, no renames, no data changes
--  Run after  : 202601027000000_quotation_engine.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SERVICE CATALOG
--    Reusable atomic services: hotel nights, transfers, guides, activities, etc.
--    Sales picks from catalog when building itinerary → auto-fills cost/price.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS service_catalog (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT        UNIQUE,                     -- e.g. SVC-0001
  name_ar         TEXT        NOT NULL,
  name_en         TEXT,
  category        TEXT        NOT NULL
                              CHECK (category IN (
                                'hotel','transfer','guide','activity','ticket',
                                'meal','flight','visa','insurance',
                                'transport','camp','other'
                              )),
  description     TEXT,
  unit            TEXT        DEFAULT 'per_person'
                              CHECK (unit IN (
                                'per_person','per_group','per_room',
                                'per_vehicle','per_day','fixed'
                              )),
  default_currency TEXT       DEFAULT 'EGP',
  cost_amount     NUMERIC(14,2) DEFAULT 0,                -- internal cost
  sell_amount     NUMERIC(14,2) DEFAULT 0,                -- default selling price
  supplier_id     UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  destination     TEXT,                                   -- e.g. "القاهرة"
  is_active       BOOLEAN     DEFAULT TRUE,
  notes           TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE service_catalog ENABLE ROW LEVEL SECURITY;

CREATE POLICY "svc_read"  ON service_catalog FOR SELECT USING (is_any_admin());
CREATE POLICY "svc_write" ON service_catalog FOR ALL   USING (can_write_bookings());

CREATE INDEX IF NOT EXISTS idx_svc_catalog_category   ON service_catalog(category);
CREATE INDEX IF NOT EXISTS idx_svc_catalog_destination ON service_catalog(destination);
CREATE INDEX IF NOT EXISTS idx_svc_catalog_active      ON service_catalog(is_active) WHERE is_active = TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. ITINERARIES
--    Top-level trip plan. Can be linked to a quotation and/or a booking.
--    Standalone creation is also valid (template itineraries).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS itineraries (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  itinerary_number TEXT       UNIQUE,                     -- AUTO: ITN-YYYY-NNNN

  -- Linkage (all nullable — itinerary can be standalone template)
  quotation_id    UUID        REFERENCES quotations(id)  ON DELETE SET NULL,
  booking_id      UUID        REFERENCES bookings(id)    ON DELETE SET NULL,
  lead_id         UUID        REFERENCES leads(id)       ON DELETE SET NULL,
  opportunity_id  UUID        REFERENCES opportunities(id) ON DELETE SET NULL,
  customer_id     UUID        REFERENCES customers(id)   ON DELETE SET NULL,

  -- Trip metadata
  title           TEXT        NOT NULL,
  destination     TEXT,                                   -- primary destination
  destinations    TEXT[],                                 -- multi-destination list
  trip_type       TEXT        DEFAULT 'custom'
                              CHECK (trip_type IN (
                                'custom','group','series','corporate','mice',
                                'hajj','umrah','leisure','adventure'
                              )),
  travel_date_from DATE,
  travel_date_to   DATE,
  duration_nights  INT        GENERATED ALWAYS AS (
                                travel_date_to - travel_date_from
                              ) STORED,                   -- auto-computed
  adults_count    INT         DEFAULT 1 CHECK (adults_count >= 0),
  children_count  INT         DEFAULT 0 CHECK (children_count >= 0),
  infants_count   INT         DEFAULT 0 CHECK (infants_count >= 0),
  currency        TEXT        DEFAULT 'EGP',

  -- Pricing summary (recomputed from itinerary_items)
  cost_total      NUMERIC(14,2) DEFAULT 0,
  sell_total      NUMERIC(14,2) DEFAULT 0,
  gross_profit    NUMERIC(14,2) DEFAULT 0,
  margin_pct      NUMERIC(5,2)  DEFAULT 0,

  -- Status
  status          TEXT        DEFAULT 'draft'
                              CHECK (status IN (
                                'draft','review','final','archived'
                              )),
  is_template     BOOLEAN     DEFAULT FALSE,              -- mark as reusable template
  notes           TEXT,

  -- Ownership
  created_by      UUID        REFERENCES auth.users(id),
  assigned_to     UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE itineraries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "itn_read"  ON itineraries FOR SELECT USING (
  assigned_to = auth.uid()
  OR created_by  = auth.uid()
  OR can_approve_financial()
  OR auth_role() IN ('admin','auditor')
);
CREATE POLICY "itn_insert" ON itineraries FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "itn_update" ON itineraries FOR UPDATE USING (
  assigned_to = auth.uid()
  OR created_by = auth.uid()
  OR auth_role() IN ('super_admin','admin','financial_manager')
);
CREATE POLICY "itn_delete" ON itineraries FOR DELETE USING (
  auth_role() IN ('super_admin','admin')
);

CREATE INDEX IF NOT EXISTS idx_itn_quotation   ON itineraries(quotation_id) WHERE quotation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_itn_booking     ON itineraries(booking_id)   WHERE booking_id   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_itn_customer    ON itineraries(customer_id)  WHERE customer_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_itn_assigned_to ON itineraries(assigned_to);
CREATE INDEX IF NOT EXISTS idx_itn_template    ON itineraries(is_template)  WHERE is_template  = TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ITINERARY DAYS
--    One row per day. sort_order controls display sequence.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS itinerary_days (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  itinerary_id    UUID        NOT NULL REFERENCES itineraries(id) ON DELETE CASCADE,
  day_number      INT         NOT NULL CHECK (day_number >= 1),
  date            DATE,                                   -- actual calendar date (nullable for template)
  city            TEXT,
  country         TEXT,
  title           TEXT,                                   -- e.g. "القاهرة — وصول وجولة الأهرامات"
  description     TEXT,                                   -- shown on PDF
  overnight_city  TEXT,                                   -- where they sleep
  meal_plan       TEXT        DEFAULT 'none'
                              CHECK (meal_plan IN (
                                'none','breakfast','half_board','full_board','all_inclusive'
                              )),
  notes           TEXT,                                   -- internal notes
  sort_order      INT         DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (itinerary_id, day_number)
);

ALTER TABLE itinerary_days ENABLE ROW LEVEL SECURITY;

-- Days inherit access from parent itinerary via join check
CREATE POLICY "itn_days_all" ON itinerary_days FOR ALL USING (
  EXISTS (
    SELECT 1 FROM itineraries i
    WHERE i.id = itinerary_id
      AND (
        i.assigned_to = auth.uid()
        OR i.created_by = auth.uid()
        OR can_approve_financial()
        OR auth_role() IN ('admin','auditor')
      )
  )
);

CREATE INDEX IF NOT EXISTS idx_itn_days_itinerary ON itinerary_days(itinerary_id, sort_order);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ITINERARY ITEMS
--    Services within each day. Linked optionally to service_catalog.
--    Stores both cost and selling price at time of building (snapshot).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS itinerary_items (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  itinerary_day_id  UUID        NOT NULL REFERENCES itinerary_days(id) ON DELETE CASCADE,
  itinerary_id      UUID        NOT NULL REFERENCES itineraries(id)    ON DELETE CASCADE,

  -- Optional link to catalog (denormalized for snapshot safety)
  service_catalog_id UUID       REFERENCES service_catalog(id) ON DELETE SET NULL,
  supplier_id        UUID       REFERENCES suppliers(id)       ON DELETE SET NULL,

  -- Service details (snapshot — changes to catalog don't affect historical items)
  name_ar           TEXT        NOT NULL,
  name_en           TEXT,
  category          TEXT        NOT NULL
                                CHECK (category IN (
                                  'hotel','transfer','guide','activity','ticket',
                                  'meal','flight','visa','insurance',
                                  'transport','camp','other'
                                )),
  description       TEXT,
  time_start        TIME,                                 -- e.g. 09:00 pickup
  time_end          TIME,
  duration_hours    NUMERIC(4,1),
  location          TEXT,                                 -- pickup/meeting point
  meeting_point     TEXT,

  -- Quantity & pricing
  unit              TEXT        DEFAULT 'per_person'
                                CHECK (unit IN (
                                  'per_person','per_group','per_room',
                                  'per_vehicle','per_day','fixed'
                                )),
  quantity          NUMERIC(8,2) DEFAULT 1,
  cost_unit         NUMERIC(14,2) DEFAULT 0,             -- cost per unit
  sell_unit         NUMERIC(14,2) DEFAULT 0,             -- sell per unit
  cost_total        NUMERIC(14,2) GENERATED ALWAYS AS (cost_unit * quantity) STORED,
  sell_total        NUMERIC(14,2) GENERATED ALWAYS AS (sell_unit * quantity) STORED,
  currency          TEXT        DEFAULT 'EGP',
  is_optional       BOOLEAN     DEFAULT FALSE,            -- shown as optional on PDF
  is_included       BOOLEAN     DEFAULT TRUE,             -- if false → "excluded" on PDF
  notes             TEXT,
  sort_order        INT         DEFAULT 0,

  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE itinerary_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "itn_items_all" ON itinerary_items FOR ALL USING (
  EXISTS (
    SELECT 1 FROM itineraries i
    WHERE i.id = itinerary_id
      AND (
        i.assigned_to = auth.uid()
        OR i.created_by = auth.uid()
        OR can_approve_financial()
        OR auth_role() IN ('admin','auditor')
      )
  )
);

CREATE INDEX IF NOT EXISTS idx_itn_items_day      ON itinerary_items(itinerary_day_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_itn_items_itn      ON itinerary_items(itinerary_id);
CREATE INDEX IF NOT EXISTS idx_itn_items_catalog  ON itinerary_items(service_catalog_id) WHERE service_catalog_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_itn_items_supplier ON itinerary_items(supplier_id)        WHERE supplier_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. LINK ITINERARY → QUOTATION & BOOKING
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS itinerary_id UUID REFERENCES itineraries(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_quotations_itinerary ON quotations(itinerary_id) WHERE itinerary_id IS NOT NULL;

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS itinerary_id UUID REFERENCES itineraries(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_itinerary ON bookings(itinerary_id) WHERE itinerary_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. AUTO-NUMBER: ITN-YYYY-NNNN
-- ─────────────────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS itinerary_seq START 1;

CREATE OR REPLACE FUNCTION generate_itinerary_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.itinerary_number IS NULL THEN
    NEW.itinerary_number := 'ITN-' || to_char(now(), 'YYYY') || '-'
                          || LPAD(nextval('itinerary_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_itn_number ON itineraries;
CREATE TRIGGER trg_itn_number
  BEFORE INSERT ON itineraries
  FOR EACH ROW EXECUTE FUNCTION generate_itinerary_number();


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. RECALCULATE ITINERARY TOTALS
--    Called after item insert/update/delete to sync totals on parent itinerary.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalculate_itinerary_totals(p_itinerary_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cost  NUMERIC(14,2);
  v_sell  NUMERIC(14,2);
  v_gp    NUMERIC(14,2);
  v_marg  NUMERIC(5,2);
BEGIN
  SELECT
    COALESCE(SUM(cost_total), 0),
    COALESCE(SUM(sell_total), 0)
  INTO v_cost, v_sell
  FROM itinerary_items
  WHERE itinerary_id = p_itinerary_id
    AND is_included = TRUE;

  v_gp   := v_sell - v_cost;
  v_marg := CASE WHEN v_sell > 0 THEN ROUND((v_gp / v_sell) * 100, 2) ELSE 0 END;

  UPDATE itineraries
  SET cost_total   = v_cost,
      sell_total   = v_sell,
      gross_profit = v_gp,
      margin_pct   = v_marg,
      updated_at   = now()
  WHERE id = p_itinerary_id;
END;
$$;

GRANT EXECUTE ON FUNCTION recalculate_itinerary_totals(UUID) TO authenticated;

-- Trigger to auto-recalculate on item change
CREATE OR REPLACE FUNCTION trg_fn_recalc_itn_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM recalculate_itinerary_totals(
    COALESCE(NEW.itinerary_id, OLD.itinerary_id)
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_recalc_itn_totals ON itinerary_items;
CREATE TRIGGER trg_recalc_itn_totals
  AFTER INSERT OR UPDATE OR DELETE ON itinerary_items
  FOR EACH ROW EXECUTE FUNCTION trg_fn_recalc_itn_totals();


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. SERVICE CATALOG AUTO-CODE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS service_catalog_seq START 1;

CREATE OR REPLACE FUNCTION generate_service_catalog_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code IS NULL THEN
    NEW.code := 'SVC-' || LPAD(nextval('service_catalog_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_svc_code ON service_catalog;
CREATE TRIGGER trg_svc_code
  BEFORE INSERT ON service_catalog
  FOR EACH ROW EXECUTE FUNCTION generate_service_catalog_code();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. HELPER: GET ITINERARY SUMMARY (for CRM dashboard)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_itinerary_summary()
RETURNS TABLE (
  total_itineraries   BIGINT,
  draft_count         BIGINT,
  final_count         BIGINT,
  template_count      BIGINT,
  total_sell_value    NUMERIC
) LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    COUNT(*)                                           AS total_itineraries,
    COUNT(*) FILTER (WHERE status = 'draft')           AS draft_count,
    COUNT(*) FILTER (WHERE status = 'final')           AS final_count,
    COUNT(*) FILTER (WHERE is_template = TRUE)         AS template_count,
    COALESCE(SUM(sell_total), 0)                       AS total_sell_value
  FROM itineraries;
$$;

GRANT EXECUTE ON FUNCTION get_itinerary_summary() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. SEED: COMMON SERVICE CATALOG ITEMS
--     These are starter entries — safe to extend or delete.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO service_catalog (name_ar, name_en, category, unit, default_currency, cost_amount, sell_amount, destination, notes)
VALUES
  ('ليلة فندقية - أربعة نجوم',   'Hotel Night - 4 Star',      'hotel',    'per_room',   'EGP', 1200, 1800, NULL, 'فندق 4 نجوم مع إفطار'),
  ('ليلة فندقية - خمسة نجوم',   'Hotel Night - 5 Star',      'hotel',    'per_room',   'EGP', 2200, 3200, NULL, 'فندق 5 نجوم مع إفطار'),
  ('نقل مطار - سيارة خاصة',      'Airport Transfer - Private', 'transfer', 'per_vehicle','EGP', 350,  550,  NULL, 'سيارة خاصة حتى 4 أشخاص'),
  ('نقل مطار - ميني فان',        'Airport Transfer - Van',    'transfer', 'per_vehicle','EGP', 500,  750,  NULL, 'ميني فان حتى 8 أشخاص'),
  ('مرشد سياحي - يوم كامل',      'Guide - Full Day',          'guide',    'per_group',  'EGP', 800,  1200, NULL, 'مرشد سياحي معتمد - 8 ساعات'),
  ('مرشد سياحي - نصف يوم',       'Guide - Half Day',          'guide',    'per_group',  'EGP', 500,  750,  NULL, 'مرشد سياحي معتمد - 4 ساعات'),
  ('جولة الأهرامات وأبو الهول',   'Pyramids & Sphinx Tour',    'activity', 'per_person', 'EGP', 150,  350,  'القاهرة', 'تضمن دخول المنطقة الأثرية'),
  ('متحف القاهرة الكبير',        'Grand Egyptian Museum',     'ticket',   'per_person', 'EGP', 200,  400,  'القاهرة', 'تذكرة دخول المتحف'),
  ('جولة وادي الملوك',           'Valley of the Kings Tour',  'activity', 'per_person', 'EGP', 180,  380,  'الأقصر', 'يشمل 3 مقابر'),
  ('رحلة المراكب بالنيل - غروب', 'Nile Felucca - Sunset',    'activity', 'per_group',  'EGP', 200,  450,  'أسوان', 'ساعتان على النيل'),
  ('تأشيرة سياحية - مصر',        'Tourist Visa - Egypt',      'visa',     'per_person', 'USD', 25,   40,   NULL, 'تأشيرة مصر عند الوصول'),
  ('تأمين سفر',                  'Travel Insurance',          'insurance','per_person', 'USD', 15,   35,   NULL, 'تأمين شامل لمدة الرحلة'),
  ('وجبة غداء - مطعم سياحي',    'Lunch - Tourist Restaurant','meal',     'per_person', 'EGP', 120,  220,  NULL, 'وجبة غداء متكاملة'),
  ('إفطار فندقي',                'Hotel Breakfast',           'meal',     'per_person', 'EGP', 80,   150,  NULL, 'إفطار بوفيه في الفندق'),
  ('باص سياحي - يوم كامل',       'Tourist Bus - Full Day',   'transport','per_vehicle','EGP', 1200, 1800, NULL, 'باص سياحي مكيف 30 مقعد'),
  ('سيارة خاصة - يوم كامل',      'Private Car - Full Day',   'transport','per_vehicle','EGP', 600,  900,  NULL, 'سيارة خاصة مع سائق - 8 ساعات')
ON CONFLICT DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION generate_itinerary_number()          TO authenticated;
GRANT EXECUTE ON FUNCTION generate_service_catalog_code()      TO authenticated;
GRANT EXECUTE ON FUNCTION trg_fn_recalc_itn_totals()           TO authenticated;
GRANT EXECUTE ON FUNCTION get_itinerary_summary()              TO authenticated;


-- ══ END PHASE 4 MIGRATION ═════════════════════════════════════════════════════
-- Apply this after 202601027000000_quotation_engine.sql
-- Verification:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_name IN ('service_catalog','itineraries','itinerary_days','itinerary_items');
--   → 4 rows
--
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name IN ('recalculate_itinerary_totals','get_itinerary_summary');
--   → 2 rows
--
--   SELECT COUNT(*) FROM service_catalog;
--   → 16 rows (seed data)
