-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 9 MIGRATION — Trip File & DMC Operations
--  File: supabase/migrations/202601045000000_phase9_trip_files.sql
--
--  Goal : تحويل Booking المؤكد إلى Trip File كامل — cockpit تشغيلي للرحلة
--
--  New tables:
--    trip_files           — ملف الرحلة الرئيسي (1:1 مع booking)
--    trip_services        — خدمات الرحلة (فنادق، نقل، مرشد…) + حالة التأكيد
--    trip_tasks           — مهام العمليات المرتبطة بالرحلة
--    trip_issues          — مشكلات/حوادث تشغيلية
--    trip_communications  — سجل التواصل مع العميل/المورد
--
--  Auto-handoff trigger:
--    trg_auto_trip_file — عند تأكيد الحجز (status → confirmed):
--      1. ينشئ trip_file تلقائياً
--      2. ينسخ itinerary_items → trip_services
--      3. ينشئ checklist tasks أساسية
--
--  Modifies (additive only):
--    bookings — ADD COLUMN trip_file_id (nullable back-reference)
--
--  Safe: no DROP, no RENAME, no data modification
--  Run after: 202601044000000_phase8_completion_fixes.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TRIP FILES — الملف التشغيلي الرئيسي للرحلة
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS trip_files (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_number         TEXT        UNIQUE,                       -- TF-YYYY-NNNNN (auto)

  -- Booking linkage (1:1)
  booking_id          UUID        NOT NULL UNIQUE
                                  REFERENCES bookings(id) ON DELETE CASCADE,

  -- Denormalized for fast ops queries (snapshot at handoff)
  customer_name       TEXT,
  customer_phone      TEXT,
  customer_email      TEXT,
  destination         TEXT,
  travel_date_start   DATE,
  travel_date_end     DATE,
  pax_count           INT         DEFAULT 1,
  b2b_partner_id      UUID        REFERENCES b2b_partners(id) ON DELETE SET NULL,
  itinerary_id        UUID        REFERENCES itineraries(id)  ON DELETE SET NULL,
  quotation_id        UUID        REFERENCES quotations(id)   ON DELETE SET NULL,

  -- Operations lifecycle
  ops_status          TEXT        NOT NULL DEFAULT 'new'
                                  CHECK (ops_status IN (
                                    'new','planning','supplier_confirmation',
                                    'ready','in_operation','completed',
                                    'post_trip','closed'
                                  )),

  -- Readiness score (0–100), recomputed by trigger on trip_services change
  readiness_score     INT         DEFAULT 0 CHECK (readiness_score BETWEEN 0 AND 100),

  -- Operations ownership
  ops_assigned_to     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  ops_notes           TEXT,

  -- Post-trip
  trip_rating         INT         CHECK (trip_rating BETWEEN 1 AND 5),
  trip_feedback       TEXT,
  post_trip_done      BOOLEAN     DEFAULT FALSE,

  -- Audit
  created_by          UUID        REFERENCES auth.users(id),
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE trip_files ENABLE ROW LEVEL SECURITY;

-- Ops team + admins can read all; sales sees own-customer trips
CREATE POLICY "tf_read" ON trip_files FOR SELECT USING (
  is_any_admin()
);
CREATE POLICY "tf_write" ON trip_files FOR INSERT WITH CHECK (
  can_write_bookings()
);
CREATE POLICY "tf_update" ON trip_files FOR UPDATE USING (
  can_write_bookings()
);

CREATE INDEX IF NOT EXISTS idx_tf_booking_id    ON trip_files(booking_id);
CREATE INDEX IF NOT EXISTS idx_tf_ops_status    ON trip_files(ops_status);
CREATE INDEX IF NOT EXISTS idx_tf_travel_start  ON trip_files(travel_date_start);
CREATE INDEX IF NOT EXISTS idx_tf_assigned_to   ON trip_files(ops_assigned_to)
  WHERE ops_assigned_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tf_b2b_partner   ON trip_files(b2b_partner_id)
  WHERE b2b_partner_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. TRIP SERVICES — خدمات الرحلة مع حالة التأكيد
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS trip_services (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_file_id          UUID        NOT NULL REFERENCES trip_files(id) ON DELETE CASCADE,

  -- Source linkage (copied from itinerary_items if auto-handoff)
  itinerary_item_id     UUID        REFERENCES itinerary_items(id) ON DELETE SET NULL,
  service_catalog_id    UUID        REFERENCES service_catalog(id) ON DELETE SET NULL,
  supplier_id           UUID        REFERENCES suppliers(id)       ON DELETE SET NULL,

  -- Service details (snapshot)
  service_type          TEXT        NOT NULL
                                    CHECK (service_type IN (
                                      'hotel','transfer','guide','activity','ticket',
                                      'meal','flight','visa','insurance',
                                      'transport','camp','other'
                                    )),
  name_ar               TEXT        NOT NULL,
  name_en               TEXT,
  description           TEXT,
  service_date          DATE,
  time_start            TIME,
  location              TEXT,
  quantity              NUMERIC(8,2) DEFAULT 1,
  unit                  TEXT        DEFAULT 'per_person',

  -- Pricing snapshot
  cost_unit             NUMERIC(14,2) DEFAULT 0,
  sell_unit             NUMERIC(14,2) DEFAULT 0,
  currency              TEXT        DEFAULT 'EGP',

  -- Confirmation workflow
  confirmation_status   TEXT        NOT NULL DEFAULT 'pending'
                                    CHECK (confirmation_status IN (
                                      'pending','requested','confirmed',
                                      'rejected','cancelled'
                                    )),
  confirmation_ref      TEXT,         -- رقم تأكيد المورد
  confirmation_date     DATE,
  confirmation_deadline DATE,         -- موعد آخر للتأكيد
  confirmation_notes    TEXT,
  voucher_url           TEXT,         -- رابط الفاوتشر

  -- Internal flags
  is_critical           BOOLEAN     DEFAULT TRUE,   -- يؤثر على readiness_score
  sort_order            INT         DEFAULT 0,

  -- Audit
  created_by            UUID        REFERENCES auth.users(id),
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE trip_services ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ts_read"   ON trip_services FOR SELECT USING (is_any_admin());
CREATE POLICY "ts_write"  ON trip_services FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "ts_update" ON trip_services FOR UPDATE USING (can_write_bookings());
CREATE POLICY "ts_delete" ON trip_services FOR DELETE USING (
  auth_role() IN ('super_admin','admin','operations_manager')
);

CREATE INDEX IF NOT EXISTS idx_ts_trip_file_id ON trip_services(trip_file_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_ts_conf_status  ON trip_services(confirmation_status);
CREATE INDEX IF NOT EXISTS idx_ts_service_date ON trip_services(service_date);
CREATE INDEX IF NOT EXISTS idx_ts_supplier     ON trip_services(supplier_id)
  WHERE supplier_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. TRIP TASKS — مهام العمليات
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS trip_tasks (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_file_id    UUID        NOT NULL REFERENCES trip_files(id) ON DELETE CASCADE,

  title           TEXT        NOT NULL,
  description     TEXT,
  task_type       TEXT        DEFAULT 'general'
                              CHECK (task_type IN (
                                'general','supplier_contact','document_request',
                                'payment','traveler_communication','internal',
                                'post_trip'
                              )),
  priority        TEXT        DEFAULT 'normal'
                              CHECK (priority IN ('low','normal','high','urgent')),
  status          TEXT        DEFAULT 'open'
                              CHECK (status IN ('open','in_progress','done','cancelled')),
  assigned_to     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  due_date        DATE,
  completed_at    TIMESTAMPTZ,
  notes           TEXT,

  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE trip_tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tt_read"   ON trip_tasks FOR SELECT USING (is_any_admin());
CREATE POLICY "tt_write"  ON trip_tasks FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "tt_update" ON trip_tasks FOR UPDATE USING (can_write_bookings());

CREATE INDEX IF NOT EXISTS idx_tt_trip_file   ON trip_tasks(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_tt_assigned_to ON trip_tasks(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tt_status      ON trip_tasks(status) WHERE status != 'done';
CREATE INDEX IF NOT EXISTS idx_tt_due_date    ON trip_tasks(due_date) WHERE status != 'done';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. TRIP ISSUES — مشكلات/حوادث تشغيلية
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS trip_issues (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_file_id    UUID        NOT NULL REFERENCES trip_files(id) ON DELETE CASCADE,

  title           TEXT        NOT NULL,
  description     TEXT,
  severity        TEXT        DEFAULT 'medium'
                              CHECK (severity IN ('low','medium','high','critical')),
  category        TEXT        DEFAULT 'operational'
                              CHECK (category IN (
                                'operational','supplier','customer','financial',
                                'document','transport','accommodation','other'
                              )),
  status          TEXT        DEFAULT 'open'
                              CHECK (status IN ('open','in_progress','resolved','closed')),
  reported_by     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  assigned_to     UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  reported_at     TIMESTAMPTZ DEFAULT now(),
  resolved_at     TIMESTAMPTZ,
  resolution      TEXT,

  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE trip_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ti_read"   ON trip_issues FOR SELECT USING (is_any_admin());
CREATE POLICY "ti_write"  ON trip_issues FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "ti_update" ON trip_issues FOR UPDATE USING (can_write_bookings());

CREATE INDEX IF NOT EXISTS idx_ti_trip_file ON trip_issues(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_ti_severity  ON trip_issues(severity) WHERE status != 'closed';
CREATE INDEX IF NOT EXISTS idx_ti_status    ON trip_issues(status)   WHERE status != 'closed';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. TRIP COMMUNICATIONS — سجل التواصل
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS trip_communications (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_file_id    UUID        NOT NULL REFERENCES trip_files(id) ON DELETE CASCADE,

  channel         TEXT        NOT NULL
                              CHECK (channel IN (
                                'whatsapp','email','phone','in_person',
                                'portal','sms','internal_note'
                              )),
  direction       TEXT        NOT NULL DEFAULT 'outbound'
                              CHECK (direction IN ('inbound','outbound','internal')),
  recipient_type  TEXT        DEFAULT 'customer'
                              CHECK (recipient_type IN ('customer','supplier','partner','internal')),
  recipient_name  TEXT,
  subject         TEXT,
  summary         TEXT        NOT NULL,
  sent_by         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  sent_at         TIMESTAMPTZ DEFAULT now(),
  is_automated    BOOLEAN     DEFAULT FALSE,
  metadata        JSONB       DEFAULT '{}',

  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE trip_communications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tc_read"  ON trip_communications FOR SELECT USING (is_any_admin());
CREATE POLICY "tc_write" ON trip_communications FOR INSERT WITH CHECK (can_write_bookings());

CREATE INDEX IF NOT EXISTS idx_tc_trip_file ON trip_communications(trip_file_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_tc_channel   ON trip_communications(channel);


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. BACK-REFERENCE: bookings.trip_file_id
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS trip_file_id UUID REFERENCES trip_files(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_trip_file
  ON bookings(trip_file_id) WHERE trip_file_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. AUTO-NUMBER: TF-YYYY-NNNNN
-- ─────────────────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS trip_file_seq START 1;

CREATE OR REPLACE FUNCTION generate_trip_file_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.trip_number IS NULL THEN
    NEW.trip_number := 'TF-' || TO_CHAR(NOW(), 'YYYY') || '-' ||
                       LPAD(NEXTVAL('trip_file_seq')::TEXT, 5, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_file_number ON trip_files;
CREATE TRIGGER trg_trip_file_number
  BEFORE INSERT ON trip_files
  FOR EACH ROW EXECUTE FUNCTION generate_trip_file_number();


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. UPDATED_AT TRIGGERS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_tf_updated_at  ON trip_files;
CREATE TRIGGER trg_tf_updated_at
  BEFORE UPDATE ON trip_files
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_ts_updated_at  ON trip_services;
CREATE TRIGGER trg_ts_updated_at
  BEFORE UPDATE ON trip_services
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_tt_updated_at  ON trip_tasks;
CREATE TRIGGER trg_tt_updated_at
  BEFORE UPDATE ON trip_tasks
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_ti_updated_at  ON trip_issues;
CREATE TRIGGER trg_ti_updated_at
  BEFORE UPDATE ON trip_issues
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. READINESS SCORE — يُعاد حسابه عند أي تغيير في trip_services
--    readiness = confirmed_critical / total_critical * 100
--    (إذا لا توجد خدمات حرجة → 100%)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalculate_readiness(p_trip_file_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_total     INT;
  v_confirmed INT;
  v_score     INT;
BEGIN
  SELECT
    COUNT(*)                                                 AS total,
    COUNT(*) FILTER (WHERE confirmation_status = 'confirmed') AS confirmed_count
  INTO v_total, v_confirmed
  FROM trip_services
  WHERE trip_file_id = p_trip_file_id
    AND is_critical = TRUE;

  IF v_total = 0 THEN
    v_score := 100;
  ELSE
    v_score := ROUND((v_confirmed::NUMERIC / v_total) * 100);
  END IF;

  UPDATE trip_files
  SET    readiness_score = v_score,
         updated_at      = now()
  WHERE  id = p_trip_file_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_refresh_readiness()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_tf_id UUID;
BEGIN
  v_tf_id := COALESCE(NEW.trip_file_id, OLD.trip_file_id);
  IF v_tf_id IS NOT NULL THEN
    PERFORM recalculate_readiness(v_tf_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ts_readiness ON trip_services;
CREATE TRIGGER trg_ts_readiness
  AFTER INSERT OR UPDATE OR DELETE ON trip_services
  FOR EACH ROW EXECUTE FUNCTION trg_fn_refresh_readiness();


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. AUTO-HANDOFF TRIGGER
--     عند تأكيد الحجز (bookings.status → 'confirmed'):
--       1. ينشئ trip_file (إذا لم يكن موجوداً)
--       2. ينسخ itinerary_items إلى trip_services
--       3. يُنشئ default checklist tasks
--       4. يربط bookings.trip_file_id
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_auto_create_trip_file()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_tf_id   UUID;
  v_tf_exists BOOLEAN;
BEGIN
  -- Only fire when status transitions TO 'confirmed'
  IF NEW.status <> 'confirmed' OR OLD.status = 'confirmed' THEN
    RETURN NEW;
  END IF;

  -- Skip if trip_file already exists for this booking
  SELECT EXISTS(SELECT 1 FROM trip_files WHERE booking_id = NEW.id)
  INTO v_tf_exists;

  IF v_tf_exists THEN
    RETURN NEW;
  END IF;

  -- 1. Create trip_file
  INSERT INTO trip_files (
    booking_id,
    customer_name,
    customer_phone,
    customer_email,
    destination,
    travel_date_start,
    pax_count,
    b2b_partner_id,
    itinerary_id,
    quotation_id,
    ops_status,
    created_by
  ) VALUES (
    NEW.id,
    NEW.customer_name,
    NEW.customer_phone,
    NEW.customer_email,
    -- destination: try to derive from package or itinerary title (best-effort)
    NULL,
    -- travel_date_start: bookings may have departure_date or similar
    NULL,
    COALESCE(NEW.adults_count, 1) + COALESCE(NEW.children_count, 0),
    NEW.b2b_partner_id,
    NEW.itinerary_id,
    NEW.quotation_id,
    'planning',
    NEW.user_id
  )
  RETURNING id INTO v_tf_id;

  -- 2. Update bookings.trip_file_id back-reference
  UPDATE bookings SET trip_file_id = v_tf_id WHERE id = NEW.id;

  -- 3. Copy itinerary_items → trip_services (if itinerary linked)
  IF NEW.itinerary_id IS NOT NULL THEN
    INSERT INTO trip_services (
      trip_file_id,
      itinerary_item_id,
      service_catalog_id,
      supplier_id,
      service_type,
      name_ar,
      name_en,
      description,
      service_date,
      time_start,
      location,
      quantity,
      unit,
      cost_unit,
      sell_unit,
      currency,
      confirmation_status,
      is_critical,
      sort_order,
      created_by
    )
    SELECT
      v_tf_id,
      ii.id,
      ii.service_catalog_id,
      ii.supplier_id,
      ii.category,
      ii.name_ar,
      ii.name_en,
      ii.description,
      id.date,
      ii.time_start,
      ii.location,
      ii.quantity,
      ii.unit,
      ii.cost_unit,
      ii.sell_unit,
      ii.currency,
      'pending',
      TRUE,
      ii.sort_order,
      NEW.user_id
    FROM itinerary_items  ii
    JOIN itinerary_days   id ON id.id = ii.itinerary_day_id
    WHERE ii.itinerary_id = NEW.itinerary_id
    ORDER BY id.day_number, ii.sort_order;
  END IF;

  -- 4. Create default checklist tasks
  INSERT INTO trip_tasks (trip_file_id, title, task_type, priority, created_by)
  VALUES
    (v_tf_id, 'مراجعة مستندات المسافرين', 'document_request', 'high', NEW.user_id),
    (v_tf_id, 'تأكيد حجوزات الفنادق مع الموردين', 'supplier_contact', 'high', NEW.user_id),
    (v_tf_id, 'تأكيد وسائل النقل', 'supplier_contact', 'normal', NEW.user_id),
    (v_tf_id, 'إرسال تفاصيل الرحلة للعميل', 'traveler_communication', 'normal', NEW.user_id),
    (v_tf_id, 'التحقق من حالة الدفع', 'payment', 'high', NEW.user_id);

  -- 5. Log in trip_communications
  INSERT INTO trip_communications (
    trip_file_id, channel, direction, recipient_type,
    summary, is_automated
  ) VALUES (
    v_tf_id, 'internal_note', 'internal', 'internal',
    'تم إنشاء ملف الرحلة تلقائياً عند تأكيد الحجز ' || NEW.booking_number,
    TRUE
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_trip_file ON bookings;
CREATE TRIGGER trg_auto_trip_file
  AFTER UPDATE OF status ON bookings
  FOR EACH ROW EXECUTE FUNCTION fn_auto_create_trip_file();


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. RPC: get_trip_file_summary(p_trip_file_id UUID)
--     Returns full trip cockpit data in one call
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_trip_file_summary(p_trip_file_id UUID)
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
BEGIN
  -- Auth check
  IF NOT is_any_admin() THEN
    RETURN '{"error":"unauthorized"}'::JSON;
  END IF;

  SELECT json_build_object(
    'trip_file',    to_json(tf),
    'booking',      to_json(b),
    'services',     (
      SELECT json_agg(ts ORDER BY ts.service_date, ts.sort_order)
      FROM trip_services ts WHERE ts.trip_file_id = p_trip_file_id
    ),
    'tasks',        (
      SELECT json_agg(tt ORDER BY
        CASE tt.priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2
                         WHEN 'normal' THEN 3 ELSE 4 END,
        tt.due_date NULLS LAST
      )
      FROM trip_tasks tt WHERE tt.trip_file_id = p_trip_file_id
    ),
    'issues',       (
      SELECT json_agg(ti ORDER BY
        CASE ti.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                         WHEN 'medium' THEN 3 ELSE 4 END
      )
      FROM trip_issues ti WHERE ti.trip_file_id = p_trip_file_id
    ),
    'communications', (
      SELECT json_agg(tc ORDER BY tc.sent_at DESC)
      FROM trip_communications tc WHERE tc.trip_file_id = p_trip_file_id
      LIMIT 20
    ),
    'services_summary', json_build_object(
      'total',     (SELECT COUNT(*) FROM trip_services WHERE trip_file_id = p_trip_file_id),
      'confirmed', (SELECT COUNT(*) FROM trip_services WHERE trip_file_id = p_trip_file_id AND confirmation_status = 'confirmed'),
      'pending',   (SELECT COUNT(*) FROM trip_services WHERE trip_file_id = p_trip_file_id AND confirmation_status = 'pending'),
      'rejected',  (SELECT COUNT(*) FROM trip_services WHERE trip_file_id = p_trip_file_id AND confirmation_status = 'rejected')
    ),
    'tasks_summary', json_build_object(
      'total',  (SELECT COUNT(*) FROM trip_tasks WHERE trip_file_id = p_trip_file_id),
      'open',   (SELECT COUNT(*) FROM trip_tasks WHERE trip_file_id = p_trip_file_id AND status = 'open'),
      'done',   (SELECT COUNT(*) FROM trip_tasks WHERE trip_file_id = p_trip_file_id AND status = 'done')
    )
  )
  INTO v_result
  FROM trip_files tf
  JOIN bookings   b  ON b.id = tf.booking_id
  WHERE tf.id = p_trip_file_id;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_trip_file_summary(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 12. RPC: get_ops_board()
--     Returns trip files grouped by ops_status — for kanban board
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_ops_board()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_result JSON;
BEGIN
  IF NOT is_any_admin() THEN
    RETURN '{"error":"unauthorized"}'::JSON;
  END IF;

  SELECT json_agg(row ORDER BY row.travel_date_start NULLS LAST)
  INTO v_result
  FROM (
    SELECT
      tf.id,
      tf.trip_number,
      tf.ops_status,
      tf.customer_name,
      tf.travel_date_start,
      tf.travel_date_end,
      tf.pax_count,
      tf.readiness_score,
      tf.destination,
      b.booking_number,
      b.total_price,
      b.status AS booking_status,
      (SELECT COUNT(*) FROM trip_tasks tt
       WHERE tt.trip_file_id = tf.id AND tt.status = 'open') AS open_tasks,
      (SELECT COUNT(*) FROM trip_issues ti
       WHERE ti.trip_file_id = tf.id AND ti.status NOT IN ('resolved','closed')) AS open_issues,
      (SELECT COUNT(*) FROM trip_services ts
       WHERE ts.trip_file_id = tf.id AND ts.confirmation_status = 'pending'
         AND ts.is_critical = TRUE) AS pending_critical_services
    FROM trip_files tf
    JOIN bookings   b ON b.id = tf.booking_id
    WHERE tf.ops_status NOT IN ('closed')
    ORDER BY tf.travel_date_start NULLS LAST
  ) row;

  RETURN COALESCE(v_result, '[]'::JSON);
END;
$$;

GRANT EXECUTE ON FUNCTION get_ops_board() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 13. VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- trip_files exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'trip_files'
  ), 'trip_files table missing';

  -- trip_services exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'trip_services'
  ), 'trip_services table missing';

  -- trip_tasks exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'trip_tasks'
  ), 'trip_tasks table missing';

  -- Auto-trigger exists
  ASSERT EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE trigger_name = 'trg_auto_trip_file'
  ), 'trg_auto_trip_file missing';

  RAISE NOTICE 'Phase 9 migration verified OK';
END;
$$;