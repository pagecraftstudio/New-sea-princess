-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 10 — Drivers, Guides & Vehicles
--  Tables: drivers, guides, vehicles, resource_assignments
--  Constraint: no double-booking enforced by DB function
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. VEHICLES ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vehicles (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar         TEXT        NOT NULL,
  name_en         TEXT,
  vehicle_type    TEXT        NOT NULL DEFAULT 'minibus'
                              CHECK (vehicle_type IN (
                                'sedan','suv','minibus','bus','van',
                                'minivan','coaster','luxury','other'
                              )),
  plate_number    TEXT        UNIQUE,
  capacity        INT         NOT NULL DEFAULT 4 CHECK (capacity > 0),
  color           TEXT,
  year            INT,
  make_model      TEXT,                          -- e.g. "Toyota Hiace"
  supplier_id     UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  is_owned        BOOLEAN     DEFAULT FALSE,     -- شركة تملكه أم مؤجَّر
  status          TEXT        NOT NULL DEFAULT 'available'
                              CHECK (status IN ('available','in_use','maintenance','retired')),
  notes           TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "v_read"   ON vehicles FOR SELECT USING (is_any_admin());
CREATE POLICY "v_write"  ON vehicles FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "v_update" ON vehicles FOR UPDATE USING (can_write_bookings());
CREATE POLICY "v_delete" ON vehicles FOR DELETE USING (auth_role() IN ('super_admin','admin'));

CREATE INDEX IF NOT EXISTS idx_vehicles_status ON vehicles(status);
CREATE INDEX IF NOT EXISTS idx_vehicles_type   ON vehicles(vehicle_type);

-- ── 2. DRIVERS ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS drivers (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name       TEXT        NOT NULL,
  phone           TEXT,
  whatsapp        TEXT,
  email           TEXT,
  national_id     TEXT,
  license_number  TEXT,
  license_expiry  DATE,
  default_vehicle_id UUID     REFERENCES vehicles(id) ON DELETE SET NULL,
  supplier_id     UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  languages       TEXT[]      DEFAULT ARRAY['ar'],
  status          TEXT        NOT NULL DEFAULT 'available'
                              CHECK (status IN ('available','busy','off','inactive')),
  notes           TEXT,
  photo_url       TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "d_read"   ON drivers FOR SELECT USING (is_any_admin());
CREATE POLICY "d_write"  ON drivers FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "d_update" ON drivers FOR UPDATE USING (can_write_bookings());
CREATE POLICY "d_delete" ON drivers FOR DELETE USING (auth_role() IN ('super_admin','admin'));

CREATE INDEX IF NOT EXISTS idx_drivers_status ON drivers(status);

-- ── 3. GUIDES ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS guides (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name       TEXT        NOT NULL,
  phone           TEXT,
  whatsapp        TEXT,
  email           TEXT,
  national_id     TEXT,
  license_number  TEXT,       -- رقم ترخيص الإرشاد
  license_expiry  DATE,
  languages       TEXT[]      NOT NULL DEFAULT ARRAY['ar'],
  specializations TEXT[]      DEFAULT ARRAY[]::TEXT[],  -- destinations/topics
  rating          NUMERIC(3,2) CHECK (rating BETWEEN 1 AND 5),
  supplier_id     UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  status          TEXT        NOT NULL DEFAULT 'available'
                              CHECK (status IN ('available','busy','off','inactive')),
  notes           TEXT,
  photo_url       TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE guides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "g_read"   ON guides FOR SELECT USING (is_any_admin());
CREATE POLICY "g_write"  ON guides FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "g_update" ON guides FOR UPDATE USING (can_write_bookings());
CREATE POLICY "g_delete" ON guides FOR DELETE USING (auth_role() IN ('super_admin','admin'));

CREATE INDEX IF NOT EXISTS idx_guides_status ON guides(status);

-- ── 4. RESOURCE ASSIGNMENTS ──────────────────────────────────────────────────
--  Links driver / guide / vehicle to a trip_service (or directly to trip_file)
CREATE TABLE IF NOT EXISTS resource_assignments (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Link to operations
  trip_file_id    UUID        NOT NULL REFERENCES trip_files(id) ON DELETE CASCADE,
  trip_service_id UUID        REFERENCES trip_services(id) ON DELETE CASCADE,

  -- Resource (exactly one must be non-null enforced below)
  resource_type   TEXT        NOT NULL
                              CHECK (resource_type IN ('driver','guide','vehicle')),
  driver_id       UUID        REFERENCES drivers(id)  ON DELETE RESTRICT,
  guide_id        UUID        REFERENCES guides(id)   ON DELETE RESTRICT,
  vehicle_id      UUID        REFERENCES vehicles(id) ON DELETE RESTRICT,

  -- Time window (for conflict detection)
  assigned_date   DATE        NOT NULL,
  time_start      TIME,
  time_end        TIME,

  -- Details
  pickup_location TEXT,
  dropoff_location TEXT,
  passenger_count INT         DEFAULT 1,
  notes           TEXT,
  status          TEXT        NOT NULL DEFAULT 'scheduled'
                              CHECK (status IN ('scheduled','confirmed','completed','cancelled')),

  -- Audit
  assigned_by     UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now(),

  -- Exactly one resource
  CONSTRAINT chk_one_resource CHECK (
    (CASE WHEN driver_id  IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN guide_id   IS NOT NULL THEN 1 ELSE 0 END +
     CASE WHEN vehicle_id IS NOT NULL THEN 1 ELSE 0 END) = 1
  )
);

ALTER TABLE resource_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ra_read"   ON resource_assignments FOR SELECT USING (is_any_admin());
CREATE POLICY "ra_write"  ON resource_assignments FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "ra_update" ON resource_assignments FOR UPDATE USING (can_write_bookings());
CREATE POLICY "ra_delete" ON resource_assignments FOR DELETE USING (can_write_bookings());

CREATE INDEX IF NOT EXISTS idx_ra_trip_file    ON resource_assignments(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_ra_trip_service ON resource_assignments(trip_service_id);
CREATE INDEX IF NOT EXISTS idx_ra_driver       ON resource_assignments(driver_id, assigned_date);
CREATE INDEX IF NOT EXISTS idx_ra_guide        ON resource_assignments(guide_id, assigned_date);
CREATE INDEX IF NOT EXISTS idx_ra_vehicle      ON resource_assignments(vehicle_id, assigned_date);
CREATE INDEX IF NOT EXISTS idx_ra_date         ON resource_assignments(assigned_date);

-- ── 5. UPDATED_AT TRIGGERS ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_vehicles_updated_at') THEN
    CREATE TRIGGER trg_vehicles_updated_at BEFORE UPDATE ON vehicles
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_drivers_updated_at') THEN
    CREATE TRIGGER trg_drivers_updated_at BEFORE UPDATE ON drivers
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_guides_updated_at') THEN
    CREATE TRIGGER trg_guides_updated_at BEFORE UPDATE ON guides
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_ra_updated_at') THEN
    CREATE TRIGGER trg_ra_updated_at BEFORE UPDATE ON resource_assignments
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

-- ── 6. CONFLICT DETECTION FUNCTION ───────────────────────────────────────────
-- Returns TRUE if the given resource is already assigned during the window
CREATE OR REPLACE FUNCTION check_resource_conflict(
  p_resource_type TEXT,
  p_resource_id   UUID,
  p_date          DATE,
  p_time_start    TIME,
  p_time_end      TIME,
  p_exclude_id    UUID DEFAULT NULL   -- exclude current row on UPDATE
)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM resource_assignments ra
    WHERE ra.status NOT IN ('cancelled')
      AND ra.assigned_date = p_date
      AND (p_exclude_id IS NULL OR ra.id <> p_exclude_id)
      AND CASE p_resource_type
            WHEN 'driver'  THEN ra.driver_id  = p_resource_id
            WHEN 'guide'   THEN ra.guide_id   = p_resource_id
            WHEN 'vehicle' THEN ra.vehicle_id = p_resource_id
            ELSE FALSE
          END
      -- Time overlap check (NULL times = all-day, always conflicts)
      AND (
        p_time_start IS NULL OR p_time_end IS NULL
        OR ra.time_start IS NULL OR ra.time_end IS NULL
        OR (p_time_start, p_time_end) OVERLAPS (ra.time_start, ra.time_end)
      )
  );
$$;

GRANT EXECUTE ON FUNCTION check_resource_conflict TO authenticated;

-- ── 7. GET DAILY SCHEDULE RPC ─────────────────────────────────────────────────
-- Returns all assignments for a given date, enriched with names
CREATE OR REPLACE FUNCTION get_daily_schedule(p_date DATE)
RETURNS TABLE (
  assignment_id   UUID,
  trip_file_id    UUID,
  trip_number     TEXT,
  trip_title      TEXT,
  resource_type   TEXT,
  resource_name   TEXT,
  resource_phone  TEXT,
  vehicle_plate   TEXT,
  vehicle_cap     INT,
  time_start      TIME,
  time_end        TIME,
  pickup_location TEXT,
  dropoff_location TEXT,
  passenger_count INT,
  notes           TEXT,
  status          TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ra.id,
    ra.trip_file_id,
    tf.trip_number,
    COALESCE(tf.customer_name, tf.destination, tf.trip_number),
    ra.resource_type,
    CASE ra.resource_type
      WHEN 'driver'  THEN d.full_name
      WHEN 'guide'   THEN g.full_name
      WHEN 'vehicle' THEN COALESCE(v.name_ar, v.make_model)
    END,
    CASE ra.resource_type
      WHEN 'driver'  THEN d.phone
      WHEN 'guide'   THEN g.phone
      ELSE NULL
    END,
    v.plate_number,
    v.capacity,
    ra.time_start,
    ra.time_end,
    ra.pickup_location,
    ra.dropoff_location,
    ra.passenger_count,
    ra.notes,
    ra.status
  FROM resource_assignments ra
  JOIN trip_files tf ON tf.id = ra.trip_file_id
  LEFT JOIN drivers  d ON d.id = ra.driver_id
  LEFT JOIN guides   g ON g.id = ra.guide_id
  LEFT JOIN vehicles v ON v.id = COALESCE(ra.vehicle_id,
    CASE WHEN ra.resource_type='driver' THEN d.default_vehicle_id ELSE NULL END)
  WHERE ra.assigned_date = p_date
    AND ra.status <> 'cancelled'
  ORDER BY ra.time_start NULLS LAST, tf.trip_number;
$$;

GRANT EXECUTE ON FUNCTION get_daily_schedule TO authenticated;

-- ── 8. RESOURCE SUMMARY RPC ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_resource_summary()
RETURNS JSON
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'drivers_total',     (SELECT COUNT(*) FROM drivers WHERE status <> 'inactive'),
    'drivers_available', (SELECT COUNT(*) FROM drivers WHERE status = 'available'),
    'drivers_busy',      (SELECT COUNT(*) FROM drivers WHERE status = 'busy'),
    'guides_total',      (SELECT COUNT(*) FROM guides  WHERE status <> 'inactive'),
    'guides_available',  (SELECT COUNT(*) FROM guides  WHERE status = 'available'),
    'guides_busy',       (SELECT COUNT(*) FROM guides  WHERE status = 'busy'),
    'vehicles_total',    (SELECT COUNT(*) FROM vehicles WHERE status <> 'retired'),
    'vehicles_available',(SELECT COUNT(*) FROM vehicles WHERE status = 'available'),
    'vehicles_in_use',   (SELECT COUNT(*) FROM vehicles WHERE status = 'in_use'),
    'assignments_today', (SELECT COUNT(*) FROM resource_assignments
                          WHERE assigned_date = CURRENT_DATE AND status <> 'cancelled'),
    'license_expiring',  (SELECT COUNT(*) FROM (
                            SELECT license_expiry FROM drivers  WHERE license_expiry BETWEEN CURRENT_DATE AND CURRENT_DATE+30
                            UNION ALL
                            SELECT license_expiry FROM guides   WHERE license_expiry BETWEEN CURRENT_DATE AND CURRENT_DATE+30
                          ) x)
  );
$$;

GRANT EXECUTE ON FUNCTION get_resource_summary TO authenticated;

-- ── 9. OPTIONAL: ADD RESOURCE REFS TO TRIP_SERVICES ──────────────────────────
-- Convenience columns so a service can store its primary driver/guide/vehicle
ALTER TABLE trip_services
  ADD COLUMN IF NOT EXISTS driver_id  UUID REFERENCES drivers(id)  ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS guide_id   UUID REFERENCES guides(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS vehicle_id UUID REFERENCES vehicles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ts_driver  ON trip_services(driver_id);
CREATE INDEX IF NOT EXISTS idx_ts_guide   ON trip_services(guide_id);
CREATE INDEX IF NOT EXISTS idx_ts_vehicle ON trip_services(vehicle_id);
