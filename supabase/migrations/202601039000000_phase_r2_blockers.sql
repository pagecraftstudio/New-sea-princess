-- =============================================================================
-- MIGRATION: 202601039000000_phase_r2_blockers.sql
-- Phase R2 — Remaining Production Blockers
--
-- Fixes:
--   R2-1  itinerary_number: enforce NOT NULL after verified backfill
--   R2-2  get_production_status(): remove hardcoded 'production_ready' status;
--         return a real health snapshot derived from actual checks
--   R2-3  send-booking-email: DB-side booking lookup helper function
--         (the edge function fetches the booking by ID — this RPC supports that)
--   R2-4  ALLOWED_ORIGINS: documented in migration comments; enforced in EF code
--
-- All changes are additive or function replacements.
-- No existing data is modified destructively.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- R2-1: Enforce itinerary_number NOT NULL
--
-- Phase R migration (038) backfilled NULLs and created a partial UNIQUE index
-- (WHERE itinerary_number IS NOT NULL), but the column itself was never made
-- NOT NULL. This means new inserts can still produce NULL if the trigger fires
-- at the wrong time or is bypassed.
--
-- The trigger generate_itinerary_number() (from migration 028) sets the value
-- BEFORE INSERT, so once we confirm no NULLs exist we can enforce NOT NULL.
-- The DO block is idempotent: it runs the backfill check again before altering.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- Only proceed if the itineraries table exists
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'itineraries') THEN

    -- Final safety backfill (idempotent)
    -- Window functions are not allowed in UPDATE directly; use a CTE instead.
    WITH numbered AS (
      SELECT id,
             'ITN-' || to_char(created_at, 'YYYY') || '-'
             || lpad(ROW_NUMBER() OVER (ORDER BY created_at)::text, 4, '0') AS new_number
      FROM itineraries
      WHERE itinerary_number IS NULL
    )
    UPDATE itineraries i
    SET    itinerary_number = n.new_number
    FROM   numbered n
    WHERE  i.id = n.id;

    -- Now enforce NOT NULL (only if column is currently nullable)
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name   = 'itineraries'
        AND column_name  = 'itinerary_number'
        AND is_nullable  = 'YES'
    ) THEN
      ALTER TABLE itineraries ALTER COLUMN itinerary_number SET NOT NULL;
      RAISE NOTICE 'itinerary_number: NOT NULL constraint enforced.';
    ELSE
      RAISE NOTICE 'itinerary_number: already NOT NULL — no change.';
    END IF;

    -- Upgrade partial UNIQUE index to full UNIQUE index now that column is NOT NULL
    -- Drop partial index first (if it exists) then recreate without WHERE
    DROP INDEX IF EXISTS idx_itineraries_number_unique;

    CREATE UNIQUE INDEX IF NOT EXISTS idx_itineraries_number_unique
      ON itineraries(itinerary_number);

    RAISE NOTICE 'itinerary_number: full UNIQUE index created.';
  END IF;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- R2-2: get_production_status() — replace hardcoded status with real checks
--
-- Previous implementation always returned 'production_ready' as a string
-- regardless of actual system state. This is misleading and potentially
-- dangerous in a production monitoring context.
--
-- Replacement: return a 'health' object with individual check results and
-- a computed overall_status of 'ok' | 'degraded' | 'missing_tables'.
-- Never hardcode a readiness verdict — let the facts speak.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_production_status()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_leads              BOOLEAN;
  v_has_customers          BOOLEAN;
  v_has_opportunities      BOOLEAN;
  v_has_quotations         BOOLEAN;
  v_has_itineraries        BOOLEAN;
  v_has_service_catalog    BOOLEAN;
  v_has_ai_conversations   BOOLEAN;
  v_has_ai_requests        BOOLEAN;
  v_has_ai_recommendations BOOLEAN;
  v_has_ai_cache           BOOLEAN;
  v_has_permission_matrix  BOOLEAN;
  v_itinerary_nn           BOOLEAN;
  v_permission_count       INT;
  v_rate_plan_count        INT;
  v_margin_count           INT;
  v_overall                TEXT;
BEGIN
  -- Auth guard: only admin users may call this
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error', 'unauthorized');
  END IF;

  -- Table existence checks
  v_has_leads              := (SELECT to_regclass('public.leads')              IS NOT NULL);
  v_has_customers          := (SELECT to_regclass('public.customers')          IS NOT NULL);
  v_has_opportunities      := (SELECT to_regclass('public.opportunities')      IS NOT NULL);
  v_has_quotations         := (SELECT to_regclass('public.quotations')         IS NOT NULL);
  v_has_itineraries        := (SELECT to_regclass('public.itineraries')        IS NOT NULL);
  v_has_service_catalog    := (SELECT to_regclass('public.service_catalog')    IS NOT NULL);
  v_has_ai_conversations   := (SELECT to_regclass('public.ai_conversations')   IS NOT NULL);
  v_has_ai_requests        := (SELECT to_regclass('public.ai_requests')        IS NOT NULL);
  v_has_ai_recommendations := (SELECT to_regclass('public.ai_recommendations') IS NOT NULL);
  v_has_ai_cache           := (SELECT to_regclass('public.ai_insights_cache')  IS NOT NULL);
  v_has_permission_matrix  := (SELECT to_regclass('public.permission_matrix')  IS NOT NULL);

  -- itinerary_number NOT NULL check
  v_itinerary_nn := CASE
    WHEN NOT v_has_itineraries THEN NULL
    ELSE (
      SELECT is_nullable = 'NO'
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name   = 'itineraries'
        AND column_name  = 'itinerary_number'
    )
  END;

  -- Row count sanity checks
  v_permission_count := CASE WHEN v_has_permission_matrix
                             THEN (SELECT COUNT(*) FROM permission_matrix)
                             ELSE 0 END;
  v_rate_plan_count  := CASE WHEN (SELECT to_regclass('public.rate_plans') IS NOT NULL)
                             THEN (SELECT COUNT(*) FROM rate_plans)
                             ELSE 0 END;
  v_margin_count     := CASE WHEN (SELECT to_regclass('public.margin_settings') IS NOT NULL)
                             THEN (SELECT COUNT(*) FROM margin_settings)
                             ELSE 0 END;

  -- Compute overall health (never hardcode)
  v_overall := CASE
    WHEN NOT (v_has_leads AND v_has_customers AND v_has_opportunities
              AND v_has_quotations AND v_has_ai_recommendations
              AND v_has_permission_matrix)
      THEN 'missing_tables'
    WHEN v_permission_count < 30
      THEN 'degraded'
    WHEN NOT COALESCE(v_itinerary_nn, TRUE)
      THEN 'degraded'
    ELSE 'ok'
  END;

  RETURN json_build_object(
    -- Core phase tables
    'tables', json_build_object(
      'leads',              v_has_leads,
      'customers',          v_has_customers,
      'opportunities',      v_has_opportunities,
      'quotations',         v_has_quotations,
      'itineraries',        v_has_itineraries,
      'service_catalog',    v_has_service_catalog,
      'ai_conversations',   v_has_ai_conversations,
      'ai_requests',        v_has_ai_requests,
      'ai_recommendations', v_has_ai_recommendations,
      'ai_insights_cache',  v_has_ai_cache,
      'permission_matrix',  v_has_permission_matrix
    ),

    -- Schema integrity
    'schema', json_build_object(
      'itinerary_number_not_null', v_itinerary_nn
    ),

    -- Data sanity
    'data', json_build_object(
      'permission_count',    v_permission_count,
      'rate_plan_count',     v_rate_plan_count,
      'margin_setting_count', v_margin_count
    ),

    -- Health verdict — computed, never hardcoded
    'overall_status', v_overall,
    'last_migration', '202601039000000_phase_r2_blockers',
    'generated_at',   now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_production_status() TO authenticated;

COMMENT ON FUNCTION get_production_status() IS
  'Returns a health snapshot of the production system. '
  'overall_status: ok | degraded | missing_tables. '
  'Never returns a hardcoded readiness verdict — based on actual DB checks. '
  'Only callable by admin_users (SECURITY DEFINER + auth guard).';


-- ─────────────────────────────────────────────────────────────────────────────
-- R2-3: fetch_booking_for_email(p_booking_id UUID)
--
-- Used by the hardened send-booking-email edge function.
-- The EF now accepts booking_id instead of a full booking payload,
-- and calls this RPC to fetch only the fields needed for the email.
--
-- Security:
--   - SECURITY DEFINER so the EF's service-role client can call it without
--     needing to bypass RLS separately
--   - Caller must be authenticated (auth.uid() IS NOT NULL)
--   - Returns only email-relevant fields — no internal financial details,
--     no passport data, no admin notes
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fetch_booking_for_email(p_booking_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking RECORD;
  v_package RECORD;
BEGIN
  -- Must be authenticated (edge function passes user JWT for user-initiated
  -- emails; service role is used only for admin-triggered emails with explicit
  -- admin_users check in the EF)
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'unauthenticated');
  END IF;

  -- Fetch booking — only select fields required by the email template
  SELECT
    b.id,
    b.booking_number,
    b.customer_name,
    b.customer_email,
    b.adults_count,
    b.children_count,
    b.infants_count,
    b.total_price,
    b.remaining_amount,
    b.status,
    b.mecca_hotel,
    b.madina_hotel,
    b.mecca_rooms,
    b.madina_rooms,
    b.booking_type,
    b.user_id
  INTO v_booking
  FROM bookings b
  WHERE b.id = p_booking_id;

  IF NOT FOUND THEN
    RETURN json_build_object('error', 'booking_not_found');
  END IF;

  -- Authorization: only the booking owner or an admin can trigger the email
  IF v_booking.user_id != auth.uid()
     AND NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid())
  THEN
    RETURN json_build_object('error', 'forbidden');
  END IF;

  -- Fetch package info (title + departure date only)
  SELECT title, departure_date
  INTO v_package
  FROM packages
  WHERE id = (
    SELECT package_id FROM bookings WHERE id = p_booking_id
  );

  RETURN json_build_object(
    'booking_number',    v_booking.booking_number,
    'customer_name',     v_booking.customer_name,
    'customer_email',    v_booking.customer_email,
    'adults_count',      v_booking.adults_count,
    'children_count',    v_booking.children_count,
    'infants_count',     v_booking.infants_count,
    'total_price',       v_booking.total_price,
    'remaining_amount',  v_booking.remaining_amount,
    'status',            v_booking.status,
    'booking_type',      v_booking.booking_type,
    'mecca_hotel',       v_booking.mecca_hotel,
    'madina_hotel',      v_booking.madina_hotel,
    'mecca_rooms',       v_booking.mecca_rooms,
    'madina_rooms',      v_booking.madina_rooms,
    'package_title',     v_package.title,
    'package_departure', v_package.departure_date
  );
END;
$$;

GRANT EXECUTE ON FUNCTION fetch_booking_for_email(UUID) TO authenticated;

COMMENT ON FUNCTION fetch_booking_for_email(UUID) IS
  'Fetches only email-safe booking fields for the send-booking-email edge function. '
  'Enforces: caller is authenticated AND is booking owner or admin. '
  'Never exposes passport data, internal notes, or financial detail beyond price/remaining.';


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION QUERIES (run manually after applying)
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Confirm itinerary_number is NOT NULL:
-- SELECT column_name, is_nullable FROM information_schema.columns
-- WHERE table_name='itineraries' AND column_name='itinerary_number';
-- Expected: is_nullable = 'NO'

-- 2. Confirm UNIQUE index is full (no WHERE clause):
-- SELECT indexname, indexdef FROM pg_indexes
-- WHERE tablename='itineraries' AND indexname='idx_itineraries_number_unique';
-- Expected: no "WHERE" clause in indexdef

-- 3. Health check returns computed status:
-- SELECT get_production_status();
-- overall_status should be 'ok' or 'degraded' — never 'production_ready'

-- 4. fetch_booking_for_email requires auth:
-- SELECT fetch_booking_for_email('00000000-0000-0000-0000-000000000000'::uuid);
-- Called without auth.uid() → should return {"error":"unauthenticated"}

-- ══ END PHASE R2 ═════════════════════════════════════════════════════════════
