-- =============================================================================
-- PHASE 13 — Customer Portal 2.0
-- Migration: 202601049000000_phase13_customer_portal.sql
--
-- Enables customers to access their own trip data safely:
--   - trip_files   : customer reads own (via bookings.user_id)
--   - trip_services: customer reads own trip services (itinerary)
--   - trip_communications: customer reads outbound messages to them
--   - communication_queue: customer reads own messages
--   - customer_portal_requests: new table for support tickets
--
-- All policies are additive. No existing admin policies touched.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. RLS: let customers read their own trip_files (via booking)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='trip_files' AND policyname='tf_customer_read') THEN
    CREATE POLICY "tf_customer_read" ON trip_files FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM bookings b
          WHERE b.id = trip_files.booking_id
            AND b.user_id = auth.uid()
        )
      );
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS: let customers read trip_services for their own trips
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='trip_services' AND policyname='ts_customer_read') THEN
    CREATE POLICY "ts_customer_read" ON trip_services FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM trip_files tf
          JOIN   bookings b ON b.id = tf.booking_id
          WHERE  tf.id   = trip_services.trip_file_id
            AND  b.user_id = auth.uid()
        )
      );
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RLS: let customers read outbound trip_communications directed to them
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='trip_communications' AND policyname='tc_customer_read') THEN
    CREATE POLICY "tc_customer_read" ON trip_communications FOR SELECT
      USING (
        direction IN ('outbound','inbound')
        AND recipient_type = 'customer'
        AND EXISTS (
          SELECT 1 FROM trip_files tf
          JOIN   bookings b ON b.id = tf.booking_id
          WHERE  tf.id   = trip_communications.trip_file_id
            AND  b.user_id = auth.uid()
        )
      );
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RLS: let customers read their own communication_queue items
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='communication_queue' AND policyname='cq_customer_read') THEN
    CREATE POLICY "cq_customer_read" ON communication_queue FOR SELECT
      USING (
        recipient_type = 'customer'
        AND EXISTS (
          SELECT 1 FROM bookings b
          WHERE b.id = communication_queue.booking_id
            AND b.user_id = auth.uid()
        )
      );
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. New table: customer_portal_requests (support / service requests)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS customer_portal_requests (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  booking_id    UUID        REFERENCES bookings(id) ON DELETE SET NULL,
  request_type  TEXT        NOT NULL DEFAULT 'general'
                            CHECK (request_type IN (
                              'general','document','change_request',
                              'complaint','cancellation','refund','other'
                            )),
  subject       TEXT        NOT NULL,
  body          TEXT        NOT NULL,
  status        TEXT        NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open','in_progress','resolved','closed')),
  admin_reply   TEXT,
  replied_by    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  replied_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cpr_user    ON customer_portal_requests(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cpr_booking ON customer_portal_requests(booking_id) WHERE booking_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cpr_status  ON customer_portal_requests(status);

ALTER TABLE customer_portal_requests ENABLE ROW LEVEL SECURITY;

-- Customer reads/writes own requests
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='customer_portal_requests' AND policyname='cpr_owner') THEN
    CREATE POLICY "cpr_owner" ON customer_portal_requests FOR ALL
      USING (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
  END IF;
END $$;

-- Admins read all requests
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='customer_portal_requests' AND policyname='cpr_admin_read') THEN
    CREATE POLICY "cpr_admin_read" ON customer_portal_requests FOR SELECT
      USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
  END IF;
END $$;

-- Admins can update (reply)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
    WHERE tablename='customer_portal_requests' AND policyname='cpr_admin_update') THEN
    CREATE POLICY "cpr_admin_update" ON customer_portal_requests FOR UPDATE
      USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
  END IF;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. RPC: get_my_trip_itinerary(p_booking_id UUID)
--    Returns trip services grouped by date for the customer portal.
--    Only works if the booking belongs to the caller.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_my_trip_itinerary(p_booking_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  -- Auth check: booking must belong to caller
  SELECT * INTO v_booking
  FROM bookings WHERE id = p_booking_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RETURN '{"error":"not_found"}'::JSON;
  END IF;

  RETURN (
    SELECT json_build_object(
      'booking_number', v_booking.booking_number,
      'services', COALESCE((
        SELECT json_agg(
          json_build_object(
            'service_date',         ts.service_date,
            'time_start',           ts.time_start,
            'service_type',         ts.service_type,
            'name_ar',              ts.name_ar,
            'description',          ts.description,
            'location',             ts.location,
            'confirmation_status',  ts.confirmation_status,
            'confirmation_ref',     ts.confirmation_ref
          ) ORDER BY ts.service_date, ts.time_start
        )
        FROM trip_files tf
        JOIN trip_services ts ON ts.trip_file_id = tf.id
        WHERE tf.booking_id = p_booking_id
          AND ts.service_date IS NOT NULL
          -- Never expose cost/supplier pricing to customer
      ), '[]'::JSON)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_my_trip_itinerary(UUID) TO authenticated;

COMMENT ON FUNCTION get_my_trip_itinerary(UUID) IS
  'Returns trip day-by-day services for a customer. '
  'Auth guard: booking.user_id must equal auth.uid(). '
  'Cost fields never returned.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. RPC: get_my_messages(p_booking_id UUID)
--    Returns communications sent to this customer for their booking.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_my_messages(p_booking_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Auth check
  IF NOT EXISTS (
    SELECT 1 FROM bookings WHERE id = p_booking_id AND user_id = auth.uid()
  ) THEN
    RETURN '{"error":"not_found"}'::JSON;
  END IF;

  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object(
        'id',           tc.id,
        'channel',      tc.channel,
        'direction',    tc.direction,
        'subject',      tc.subject,
        'summary',      tc.summary,
        'sent_at',      tc.sent_at,
        'is_automated', tc.is_automated
      ) ORDER BY tc.sent_at DESC
    ), '[]'::JSON)
    FROM trip_files tf
    JOIN trip_communications tc ON tc.trip_file_id = tf.id
    WHERE tf.booking_id = p_booking_id
      AND tc.direction IN ('outbound','inbound')
      AND tc.recipient_type = 'customer'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_my_messages(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Permissions
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO permission_matrix (permission, name_ar, category_ar, roles)
SELECT p.permission, p.name_ar, p.category_ar, p.roles::text[]
FROM (VALUES
  ('manage_portal_requests', 'إدارة طلبات بوابة العملاء', 'خدمة العملاء',
   '{super_admin,admin,sales_agent,booking_agent}')
) AS p(permission, name_ar, category_ar, roles)
WHERE NOT EXISTS (
  SELECT 1 FROM permission_matrix WHERE permission = p.permission
);


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- SELECT * FROM get_my_trip_itinerary('<booking_uuid>');
-- SELECT * FROM get_my_messages('<booking_uuid>');
-- SELECT * FROM customer_portal_requests LIMIT 1;
-- =============================================================================
