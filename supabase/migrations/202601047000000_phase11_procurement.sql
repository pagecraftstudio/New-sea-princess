-- ══════════════════════════════════════════════════════════════════════════
--  NSP Migration v47 — Phase 11: Supplier Availability & Procurement
--
--  Goal: Operations knows instantly which services are confirmed vs pending.
--
--  NEW TABLES:
--    supplier_requests       — Formal outbound request sent to a supplier
--                              per trip_service. Tracks send date, deadline,
--                              contact used, and response.
--    supplier_confirmations  — Formal confirmation received: ref number,
--                              rate, cancellation deadline, voucher.
--
--  NEW RPCs:
--    get_procurement_dashboard()  — Cross-trip: all pending/at-risk services
--    get_supplier_workload()      — Per supplier: all current commitments
--    mark_service_requested()     — Atomically update status + log request
--
--  EXTENDS:
--    trip_services           — ADD confirmation_deadline + voucher_url
--                              (already exist per Phase 9, idempotent)
--
--  SAFETY: purely additive — no existing table columns removed or renamed.
-- ══════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════
--  TABLE 1: supplier_requests
--  One row per outbound request sent to a supplier for a trip_service.
--  A service can have multiple requests (e.g. initial + follow-up).
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS supplier_requests (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- What we're requesting
  trip_service_id     UUID        NOT NULL REFERENCES trip_services(id) ON DELETE CASCADE,
  trip_file_id        UUID        NOT NULL REFERENCES trip_files(id)    ON DELETE CASCADE,
  supplier_id         UUID        REFERENCES suppliers(id) ON DELETE SET NULL,

  -- Request details
  request_type        TEXT        NOT NULL DEFAULT 'availability'
                                  CHECK (request_type IN (
                                    'availability','booking','amendment',
                                    'cancellation','follow_up'
                                  )),
  channel             TEXT        DEFAULT 'email'
                                  CHECK (channel IN ('email','whatsapp','phone','fax','portal','other')),

  -- Dates
  requested_date      DATE        NOT NULL DEFAULT CURRENT_DATE,
  response_deadline   DATE,                        -- موعد آخر للرد

  -- What we asked for
  quantity            NUMERIC(8,2),
  travelers_count     INT,
  requirements        TEXT,                        -- special requirements sent

  -- Request content
  request_subject     TEXT,
  request_body        TEXT,
  contact_name        TEXT,
  contact_email       TEXT,
  contact_phone       TEXT,

  -- Response tracking
  response_status     TEXT        NOT NULL DEFAULT 'awaiting'
                                  CHECK (response_status IN (
                                    'awaiting','received','confirmed',
                                    'rejected','expired'
                                  )),
  response_received_at TIMESTAMPTZ,
  response_notes      TEXT,

  -- Audit
  sent_by             UUID        REFERENCES auth.users(id),
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION touch_sr_updated()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_sr_updated ON supplier_requests;
CREATE TRIGGER trg_sr_updated
  BEFORE UPDATE ON supplier_requests
  FOR EACH ROW EXECUTE FUNCTION touch_sr_updated();

-- Auto-update trip_service status to 'requested' when a request is sent
CREATE OR REPLACE FUNCTION trg_fn_request_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- When a new request is created, move the service to 'requested' if still pending
  UPDATE trip_services
  SET    confirmation_status = 'requested',
         updated_at          = now()
  WHERE  id = NEW.trip_service_id
    AND  confirmation_status = 'pending';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_request_status ON supplier_requests;
CREATE TRIGGER trg_request_status
  AFTER INSERT ON supplier_requests
  FOR EACH ROW EXECUTE FUNCTION trg_fn_request_status();

CREATE INDEX IF NOT EXISTS idx_sreq_service   ON supplier_requests(trip_service_id);
CREATE INDEX IF NOT EXISTS idx_sreq_trip      ON supplier_requests(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_sreq_supplier  ON supplier_requests(supplier_id);
CREATE INDEX IF NOT EXISTS idx_sreq_deadline  ON supplier_requests(response_deadline)
  WHERE response_status = 'awaiting';
CREATE INDEX IF NOT EXISTS idx_sreq_status    ON supplier_requests(response_status);

ALTER TABLE supplier_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sreq_read"   ON supplier_requests FOR SELECT USING (is_any_admin());
CREATE POLICY "sreq_write"  ON supplier_requests FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "sreq_update" ON supplier_requests FOR UPDATE USING (can_write_bookings());


-- ══════════════════════════════════════════════════════════════════════════
--  TABLE 2: supplier_confirmations
--  Formal confirmation received from supplier. One per trip_service
--  (or one per request if multiple versions needed).
-- ══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS supplier_confirmations (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Links
  trip_service_id       UUID        NOT NULL REFERENCES trip_services(id) ON DELETE CASCADE,
  trip_file_id          UUID        NOT NULL REFERENCES trip_files(id)    ON DELETE CASCADE,
  supplier_request_id   UUID        REFERENCES supplier_requests(id)      ON DELETE SET NULL,
  supplier_id           UUID        REFERENCES suppliers(id)              ON DELETE SET NULL,

  -- Confirmation details
  confirmation_ref      TEXT,                        -- رقم تأكيد المورد
  confirmation_date     DATE        DEFAULT CURRENT_DATE,
  confirmed_by_name     TEXT,                        -- اسم المسؤول لدى المورد
  confirmed_by_contact  TEXT,                        -- هاتف/بريد المسؤول

  -- What was confirmed
  confirmed_quantity    NUMERIC(8,2),
  confirmed_rate        NUMERIC(14,2),
  rate_currency         TEXT        DEFAULT 'EGP',
  room_type             TEXT,                        -- للفنادق: نوع الغرفة
  board_basis           TEXT,                        -- RO/BB/HB/FB

  -- Cancellation policy
  cancellation_deadline DATE,
  cancellation_policy   TEXT,

  -- Voucher
  voucher_ref           TEXT,
  voucher_url           TEXT,
  voucher_notes         TEXT,

  -- Status
  is_active             BOOLEAN     DEFAULT TRUE,    -- FALSE if superseded
  notes                 TEXT,

  -- Audit
  recorded_by           UUID        REFERENCES auth.users(id),
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION touch_sconf_updated()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_sconf_updated ON supplier_confirmations;
CREATE TRIGGER trg_sconf_updated
  BEFORE UPDATE ON supplier_confirmations
  FOR EACH ROW EXECUTE FUNCTION touch_sconf_updated();

-- When a confirmation is recorded, sync trip_service fields
CREATE OR REPLACE FUNCTION trg_fn_sync_confirmation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Update trip_service with confirmation details
  UPDATE trip_services
  SET    confirmation_status   = 'confirmed',
         confirmation_ref      = NEW.confirmation_ref,
         confirmation_date     = NEW.confirmation_date,
         confirmation_deadline = NEW.cancellation_deadline,
         confirmation_notes    = NEW.notes,
         voucher_url           = NEW.voucher_url,
         updated_at            = now()
  WHERE  id = NEW.trip_service_id;

  -- Mark the linked request as received
  IF NEW.supplier_request_id IS NOT NULL THEN
    UPDATE supplier_requests
    SET    response_status       = 'confirmed',
           response_received_at  = now(),
           response_notes        = NEW.notes
    WHERE  id = NEW.supplier_request_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_confirmation ON supplier_confirmations;
CREATE TRIGGER trg_sync_confirmation
  AFTER INSERT ON supplier_confirmations
  FOR EACH ROW EXECUTE FUNCTION trg_fn_sync_confirmation();

CREATE INDEX IF NOT EXISTS idx_sconf_service  ON supplier_confirmations(trip_service_id);
CREATE INDEX IF NOT EXISTS idx_sconf_trip     ON supplier_confirmations(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_sconf_supplier ON supplier_confirmations(supplier_id);
CREATE INDEX IF NOT EXISTS idx_sconf_cancel   ON supplier_confirmations(cancellation_deadline)
  WHERE is_active = TRUE;

ALTER TABLE supplier_confirmations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sconf_read"   ON supplier_confirmations FOR SELECT USING (is_any_admin());
CREATE POLICY "sconf_write"  ON supplier_confirmations FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "sconf_update" ON supplier_confirmations FOR UPDATE USING (can_write_bookings());


-- ══════════════════════════════════════════════════════════════════════════
--  EXTEND trip_services — ensure confirmation_deadline and voucher_url exist
--  (Phase 9 already added these; ADD COLUMN IF NOT EXISTS is idempotent)
-- ══════════════════════════════════════════════════════════════════════════
ALTER TABLE trip_services
  ADD COLUMN IF NOT EXISTS confirmation_deadline DATE,
  ADD COLUMN IF NOT EXISTS voucher_url           TEXT;


-- ══════════════════════════════════════════════════════════════════════════
--  RPC: get_procurement_dashboard()
--  Returns all non-confirmed, non-cancelled trip services across ALL active
--  trips, ordered by urgency (travel_date ASC, then overdue requests first).
--  Used by procurement.html board and the dashboard widget.
-- ══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_procurement_dashboard()
RETURNS TABLE (
  trip_service_id     UUID,
  trip_file_id        UUID,
  trip_number         TEXT,
  trip_title          TEXT,
  trip_status         TEXT,
  travel_date_start  DATE,
  service_type        TEXT,
  service_name        TEXT,
  supplier_id         UUID,
  supplier_name       TEXT,
  service_date        DATE,
  confirmation_status TEXT,
  confirmation_ref    TEXT,
  confirmation_deadline DATE,
  is_critical         BOOLEAN,
  days_to_travel      INT,
  last_request_date   DATE,
  last_request_status TEXT,
  request_count       BIGINT,
  urgency_level       TEXT    -- 'critical'|'high'|'medium'|'low'
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ts.id                                       AS trip_service_id,
    tf.id                                       AS trip_file_id,
    tf.trip_number,
    COALESCE(tf.customer_name, tf.destination, tf.trip_number) AS trip_title,
    tf.ops_status                                   AS trip_status,
    tf.travel_date_start,
    ts.service_type,
    ts.name_ar                                  AS service_name,
    ts.supplier_id,
    s.name_ar                                   AS supplier_name,
    ts.service_date,
    ts.confirmation_status,
    ts.confirmation_ref,
    ts.confirmation_deadline,
    ts.is_critical,
    (tf.travel_date_start - CURRENT_DATE)::INT   AS days_to_travel,
    -- Last request sent
    (SELECT MAX(sr.requested_date)
     FROM supplier_requests sr
     WHERE sr.trip_service_id = ts.id)          AS last_request_date,
    (SELECT sr.response_status
     FROM supplier_requests sr
     WHERE sr.trip_service_id = ts.id
     ORDER BY sr.created_at DESC LIMIT 1)       AS last_request_status,
    (SELECT COUNT(*)
     FROM supplier_requests sr
     WHERE sr.trip_service_id = ts.id)          AS request_count,
    -- Urgency: critical = travel in ≤7 days + unconfirmed critical service
    CASE
      WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 7  THEN 'critical'
      WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 14 THEN 'high'
      WHEN                    (tf.travel_date_start - CURRENT_DATE) <= 7  THEN 'high'
      WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 30 THEN 'medium'
      ELSE 'low'
    END                                         AS urgency_level
  FROM trip_services ts
  JOIN trip_files    tf ON tf.id = ts.trip_file_id
  LEFT JOIN suppliers s ON s.id  = ts.supplier_id
  WHERE ts.confirmation_status NOT IN ('confirmed', 'cancelled')
    AND tf.ops_status NOT IN ('completed', 'cancelled', 'closed')
    AND tf.travel_date_start >= CURRENT_DATE - 1   -- include trips starting yesterday
  ORDER BY
    CASE WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 7  THEN 1
         WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 14 THEN 2
         WHEN                    (tf.travel_date_start - CURRENT_DATE) <= 7  THEN 3
         WHEN ts.is_critical AND (tf.travel_date_start - CURRENT_DATE) <= 30 THEN 4
         ELSE 5
    END,
    tf.travel_date_start ASC,
    ts.service_date ASC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION get_procurement_dashboard() TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════
--  RPC: get_supplier_workload(p_supplier_id)
--  Returns all current and upcoming confirmed/pending services for one
--  supplier. Used by supplier intelligence page and supplier detail.
-- ══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_supplier_workload(p_supplier_id UUID)
RETURNS TABLE (
  trip_service_id     UUID,
  trip_number         TEXT,
  trip_title          TEXT,
  service_type        TEXT,
  service_name        TEXT,
  service_date        DATE,
  quantity            NUMERIC,
  confirmation_status TEXT,
  confirmation_ref    TEXT,
  travel_date_start  DATE
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ts.id,
    tf.trip_number,
    COALESCE(tf.customer_name, tf.destination, tf.trip_number),
    ts.service_type,
    ts.name_ar,
    ts.service_date,
    ts.quantity,
    ts.confirmation_status,
    ts.confirmation_ref,
    tf.travel_date_start
  FROM trip_services ts
  JOIN trip_files    tf ON tf.id = ts.trip_file_id
  WHERE ts.supplier_id = p_supplier_id
    AND tf.ops_status NOT IN ('cancelled','closed')
    AND (tf.travel_date_start >= CURRENT_DATE - 30)
  ORDER BY tf.travel_date_start ASC, ts.service_date ASC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION get_supplier_workload(UUID) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════
--  RPC: get_procurement_summary()
--  Returns aggregate counts for the dashboard KPI widget.
-- ══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_procurement_summary()
RETURNS JSON
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'pending_total',   (
      SELECT COUNT(*) FROM trip_services ts
      JOIN trip_files tf ON tf.id = ts.trip_file_id
      WHERE ts.confirmation_status IN ('pending','requested')
        AND tf.ops_status NOT IN ('completed','cancelled','closed')
        AND tf.travel_date_start >= CURRENT_DATE - 1
    ),
    'critical_unconfirmed', (
      SELECT COUNT(*) FROM trip_services ts
      JOIN trip_files tf ON tf.id = ts.trip_file_id
      WHERE ts.confirmation_status IN ('pending','requested')
        AND ts.is_critical = TRUE
        AND tf.travel_date_start <= CURRENT_DATE + 14
        AND tf.ops_status NOT IN ('completed','cancelled','closed')
    ),
    'overdue_requests', (
      SELECT COUNT(*) FROM supplier_requests
      WHERE response_status = 'awaiting'
        AND response_deadline < CURRENT_DATE
    ),
    'confirmed_today', (
      SELECT COUNT(*) FROM supplier_confirmations
      WHERE confirmation_date = CURRENT_DATE
        AND is_active = TRUE
    ),
    'cancellation_due_soon', (
      SELECT COUNT(*) FROM supplier_confirmations
      WHERE cancellation_deadline BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
        AND is_active = TRUE
    )
  );
$$;

GRANT EXECUTE ON FUNCTION get_procurement_summary() TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════
--  PERMISSIONS
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
VALUES
  ('read_procurement',         'عرض لوحة المشتريات',       'العمليات', ARRAY['super_admin','admin','financial_manager','auditor','booking_agent','sales_agent']),
  ('write_procurement',        'إدارة طلبات التأكيد',       'العمليات', ARRAY['super_admin','admin','booking_agent']),
  ('read_supplier_requests',   'عرض طلبات الموردين',        'العمليات', ARRAY['super_admin','admin','financial_manager','auditor','booking_agent']),
  ('write_supplier_requests',  'إرسال طلبات الموردين',      'العمليات', ARRAY['super_admin','admin','booking_agent'])
ON CONFLICT (permission) DO NOTHING;


-- ══════════════════════════════════════════════════════════════════════════
--  VERIFICATION
-- ══════════════════════════════════════════════════════════════════════════
-- 1. New tables:
--    SELECT table_name FROM information_schema.tables
--    WHERE table_name IN ('supplier_requests','supplier_confirmations')
--    AND table_schema = 'public';
--    -- Expected: 2 rows
--
-- 2. RPCs created:
--    SELECT routine_name FROM information_schema.routines
--    WHERE routine_name IN (
--      'get_procurement_dashboard','get_supplier_workload','get_procurement_summary')
--    AND routine_schema = 'public';
--    -- Expected: 3 rows
--
-- 3. Trigger chain: insert supplier_confirmation → trip_service becomes 'confirmed':
--    (test manually with a sample INSERT then check trip_services)
--
-- 4. Existing readiness trigger still fires:
--    SELECT trigger_name FROM information_schema.triggers
--    WHERE trigger_name = 'trg_ts_readiness';
--    -- Expected: 1 row
