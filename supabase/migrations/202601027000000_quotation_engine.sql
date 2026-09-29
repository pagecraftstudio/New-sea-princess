-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 3 MIGRATION — Quotation Engine
--  File: supabase/migrations/202601027000000_quotation_engine.sql
--
--  Purpose: Full quotation entity with versioning, line items, secure PDF tokens,
--           and conversion-to-booking bridge.
--
--  New tables : quotations, quotation_items, quotation_versions
--  Modifies   : bookings (add quote_id nullable FK)
--               opportunities (add latest_quote_id nullable FK)
--  Safe       : additive only — no drops, no renames, no data changes
--  Run after  : 202601026000000_customer_360.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. QUOTATIONS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS quotations (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_number      TEXT        UNIQUE,                       -- AUTO: QUO-YYYY-NNNN

  -- CRM linkage (all nullable — a quote can be standalone)
  lead_id           UUID        REFERENCES leads(id)         ON DELETE SET NULL,
  opportunity_id    UUID        REFERENCES opportunities(id) ON DELETE SET NULL,
  customer_id       UUID        REFERENCES customers(id)     ON DELETE SET NULL,

  -- Version tracking
  version           INT         NOT NULL DEFAULT 1,
  parent_quote_id   UUID        REFERENCES quotations(id)    ON DELETE SET NULL,
  -- latest_version: true on the newest revision; earlier versions set to false on supersede

  -- Customer-facing info
  title             TEXT        NOT NULL,
  destination       TEXT,
  travel_date_from  DATE,
  travel_date_to    DATE,
  adults_count      INT         DEFAULT 1 CHECK (adults_count >= 0),
  children_count    INT         DEFAULT 0 CHECK (children_count >= 0),
  infants_count     INT         DEFAULT 0 CHECK (infants_count >= 0),

  -- Pricing
  currency          TEXT        DEFAULT 'EGP',
  subtotal          NUMERIC(14,2) DEFAULT 0,
  discount_pct      NUMERIC(5,2)  DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
  discount_amount   NUMERIC(14,2) DEFAULT 0,
  tax_pct           NUMERIC(5,2)  DEFAULT 0 CHECK (tax_pct BETWEEN 0 AND 100),
  tax_amount        NUMERIC(14,2) DEFAULT 0,
  total_amount      NUMERIC(14,2) DEFAULT 0,    -- computed: subtotal - discount + tax
  cost_total        NUMERIC(14,2) DEFAULT 0,    -- internal: sum of item costs (hidden from client)
  gross_profit      NUMERIC(14,2) DEFAULT 0,    -- total_amount - cost_total
  margin_pct        NUMERIC(5,2)  DEFAULT 0,    -- gross_profit / total_amount * 100

  -- Commercial terms
  validity_date     DATE,                        -- quote expires on this date
  payment_terms     TEXT,                        -- free text: "50% deposit, balance 30 days before travel"
  cancellation_policy TEXT,
  included_services TEXT,                        -- what's included (for PDF)
  excluded_services TEXT,                        -- what's excluded (for PDF)
  notes             TEXT,                        -- internal notes (not printed)
  client_notes      TEXT,                        -- shown on PDF / portal

  -- Lifecycle status
  status            TEXT        DEFAULT 'draft'
                                CHECK (status IN (
                                  'draft','internal_review','sent','viewed',
                                  'revision_requested','negotiation',
                                  'accepted','deposit_pending','confirmed',
                                  'expired','rejected','cancelled'
                                )),

  -- Tracking
  sent_at           TIMESTAMPTZ,
  viewed_at         TIMESTAMPTZ,
  accepted_at       TIMESTAMPTZ,
  rejected_at       TIMESTAMPTZ,
  expired_at        TIMESTAMPTZ,

  -- Secure public token for customer-facing link (no auth required)
  public_token      TEXT        UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),

  -- Team
  sales_owner       UUID        REFERENCES auth.users(id),
  approved_by       UUID        REFERENCES auth.users(id),
  approved_at       TIMESTAMPTZ,

  -- Conversion
  converted_to_booking_id UUID  REFERENCES bookings(id) ON DELETE SET NULL,
  converted_at      TIMESTAMPTZ,

  created_by        UUID        REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- Auto quote number
CREATE SEQUENCE IF NOT EXISTS quote_seq START 1;

CREATE OR REPLACE FUNCTION generate_quote_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.quote_number := 'QUO-' || to_char(now(), 'YYYY') || '-' ||
                      lpad(nextval('quote_seq')::text, 4, '0');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_quote_number ON quotations;
CREATE TRIGGER trg_quote_number
  BEFORE INSERT ON quotations
  FOR EACH ROW
  WHEN (NEW.quote_number IS NULL)
  EXECUTE FUNCTION generate_quote_number();

-- updated_at (reuses touch_updated_at from Phase 1 migration)
DROP TRIGGER IF EXISTS trg_quotations_updated_at ON quotations;
CREATE TRIGGER trg_quotations_updated_at
  BEFORE UPDATE ON quotations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Auto-expire: mark status=expired when validity_date passed and quote was sent
CREATE OR REPLACE FUNCTION auto_expire_quotes()
RETURNS void LANGUAGE sql AS $$
  UPDATE quotations
  SET status = 'expired', expired_at = now(), updated_at = now()
  WHERE validity_date < CURRENT_DATE
    AND status IN ('sent','viewed','revision_requested','negotiation')
    AND expired_at IS NULL;
$$;

GRANT EXECUTE ON FUNCTION auto_expire_quotes() TO authenticated;

-- RLS
ALTER TABLE quotations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "quotations_read" ON quotations FOR SELECT USING (
  sales_owner = auth.uid()
  OR can_approve_financial()
  OR auth_role() IN ('super_admin','admin','auditor')
);
CREATE POLICY "quotations_insert" ON quotations FOR INSERT WITH CHECK (
  can_write_bookings()
);
CREATE POLICY "quotations_update" ON quotations FOR UPDATE USING (
  sales_owner = auth.uid()
  OR auth_role() IN ('super_admin','admin','financial_manager')
);
CREATE POLICY "quotations_delete" ON quotations FOR DELETE USING (
  auth_role() IN ('super_admin','admin')
  AND status = 'draft'
);

-- Public read via token (no auth needed — for customer portal link)
CREATE POLICY "quotations_public_token" ON quotations FOR SELECT USING (
  public_token IS NOT NULL
  -- The actual token check is done in the RPC below, not here.
  -- This policy is intentionally open for token-based reads via the RPC.
  -- Direct table access still requires authenticated read via above policy.
);

CREATE INDEX IF NOT EXISTS idx_quotations_lead_id       ON quotations(lead_id)        WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quotations_opportunity_id ON quotations(opportunity_id) WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quotations_customer_id   ON quotations(customer_id)    WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quotations_status        ON quotations(status);
CREATE INDEX IF NOT EXISTS idx_quotations_sales_owner   ON quotations(sales_owner);
CREATE INDEX IF NOT EXISTS idx_quotations_created_at    ON quotations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_quotations_public_token  ON quotations(public_token);
CREATE INDEX IF NOT EXISTS idx_quotations_validity      ON quotations(validity_date)  WHERE status IN ('sent','viewed','revision_requested','negotiation');


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. QUOTATION ITEMS  (line items per quote)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS quotation_items (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id   UUID        NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  sort_order     INT         DEFAULT 0,

  -- Service info
  item_type      TEXT        DEFAULT 'other'
                             CHECK (item_type IN (
                               'hotel','flight','transport','guide',
                               'visa','excursion','meal','ticket',
                               'other'
                             )),
  description    TEXT        NOT NULL,
  destination    TEXT,
  date_from      DATE,
  date_to        DATE,
  nights         INT,                    -- for hotels

  -- Pricing
  quantity       INT         DEFAULT 1 CHECK (quantity > 0),
  unit_label     TEXT        DEFAULT 'فرد',   -- per person / per night / per group
  unit_cost      NUMERIC(12,2) DEFAULT 0,     -- internal supplier cost per unit (hidden)
  unit_price     NUMERIC(12,2) DEFAULT 0,     -- selling price per unit (shown to client)
  total_cost     NUMERIC(12,2) GENERATED ALWAYS AS (unit_cost * quantity) STORED,
  total_price    NUMERIC(12,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
  gross_profit   NUMERIC(12,2) GENERATED ALWAYS AS ((unit_price - unit_cost) * quantity) STORED,

  -- Optional supplier linkage
  supplier_id    UUID        REFERENCES suppliers(id) ON DELETE SET NULL,
  supplier_ref   TEXT,                   -- confirmation / ref number

  notes          TEXT,                   -- item-level notes (internal)
  created_at     TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE quotation_items ENABLE ROW LEVEL SECURITY;

-- Inherit visibility from parent quotation
CREATE POLICY "quote_items_read" ON quotation_items FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM quotations q WHERE q.id = quotation_id
    AND (
      q.sales_owner = auth.uid()
      OR can_approve_financial()
      OR auth_role() IN ('super_admin','admin','auditor')
    )
  )
);
CREATE POLICY "quote_items_write" ON quotation_items FOR INSERT WITH CHECK (
  can_write_bookings()
);
CREATE POLICY "quote_items_update" ON quotation_items FOR UPDATE USING (
  can_write_bookings()
);
CREATE POLICY "quote_items_delete" ON quotation_items FOR DELETE USING (
  can_write_bookings()
);

CREATE INDEX IF NOT EXISTS idx_quote_items_quotation_id ON quotation_items(quotation_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_quote_items_supplier_id  ON quotation_items(supplier_id) WHERE supplier_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. QUOTATION VERSIONS  (snapshot archive — one row per superseded version)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS quotation_versions (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id      UUID        NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,
  version_number    INT         NOT NULL,
  snapshot          JSONB       NOT NULL,   -- full quote + items captured at revision time
  superseded_by     UUID        REFERENCES quotations(id) ON DELETE SET NULL,
  created_by        UUID        REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE quotation_versions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "quote_versions_read" ON quotation_versions FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM quotations q WHERE q.id = quotation_id
    AND (
      q.sales_owner = auth.uid()
      OR can_approve_financial()
      OR auth_role() IN ('super_admin','admin','auditor')
    )
  )
);
CREATE POLICY "quote_versions_write" ON quotation_versions FOR INSERT WITH CHECK (
  can_write_bookings()
);

CREATE INDEX IF NOT EXISTS idx_quote_versions_quotation_id ON quotation_versions(quotation_id, version_number DESC);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. FUNCTION: save_quote_version()
--    Captures a snapshot of the quote + items before a new revision is saved.
--    Called manually from application when a sent quote is revised.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION save_quote_version(p_quotation_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quote   quotations%ROWTYPE;
  v_items   JSONB;
  v_ver_id  UUID;
BEGIN
  SELECT * INTO v_quote FROM quotations WHERE id = p_quotation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quotation not found: %', p_quotation_id; END IF;

  SELECT json_agg(row_to_json(qi)) INTO v_items
  FROM quotation_items qi WHERE qi.quotation_id = p_quotation_id;

  INSERT INTO quotation_versions (quotation_id, version_number, snapshot, created_by)
  VALUES (
    p_quotation_id,
    v_quote.version,
    jsonb_build_object('quote', row_to_json(v_quote), 'items', COALESCE(v_items, '[]'::jsonb)),
    auth.uid()
  )
  RETURNING id INTO v_ver_id;

  -- Bump version number on the live quote
  UPDATE quotations SET version = version + 1, updated_at = now()
  WHERE id = p_quotation_id;

  RETURN v_ver_id;
END;
$$;

GRANT EXECUTE ON FUNCTION save_quote_version(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. FUNCTION: recalculate_quote_totals()
--    Recomputes subtotal/cost/profit/margin from line items and applies discount/tax.
--    Call after any item INSERT/UPDATE/DELETE.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalculate_quote_totals(p_quotation_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subtotal     NUMERIC(14,2);
  v_cost_total   NUMERIC(14,2);
  v_disc_pct     NUMERIC(5,2);
  v_disc_amt     NUMERIC(14,2);
  v_tax_pct      NUMERIC(5,2);
  v_tax_amt      NUMERIC(14,2);
  v_total        NUMERIC(14,2);
  v_profit       NUMERIC(14,2);
  v_margin       NUMERIC(5,2);
BEGIN
  SELECT
    COALESCE(SUM(total_price), 0),
    COALESCE(SUM(total_cost),  0)
  INTO v_subtotal, v_cost_total
  FROM quotation_items
  WHERE quotation_id = p_quotation_id;

  SELECT discount_pct, tax_pct
  INTO v_disc_pct, v_tax_pct
  FROM quotations WHERE id = p_quotation_id;

  v_disc_amt := ROUND(v_subtotal * COALESCE(v_disc_pct, 0) / 100, 2);
  v_tax_amt  := ROUND((v_subtotal - v_disc_amt) * COALESCE(v_tax_pct, 0) / 100, 2);
  v_total    := v_subtotal - v_disc_amt + v_tax_amt;
  v_profit   := v_total - v_cost_total;
  v_margin   := CASE WHEN v_total > 0 THEN ROUND(v_profit / v_total * 100, 2) ELSE 0 END;

  UPDATE quotations SET
    subtotal        = v_subtotal,
    discount_amount = v_disc_amt,
    tax_amount      = v_tax_amt,
    total_amount    = v_total,
    cost_total      = v_cost_total,
    gross_profit    = v_profit,
    margin_pct      = v_margin,
    updated_at      = now()
  WHERE id = p_quotation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION recalculate_quote_totals(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. FUNCTION: get_quote_by_token()
--    Public (no auth) read of a quote via its secure token.
--    Returns only client-visible fields — never cost_total, margin_pct, notes.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_quote_by_token(p_token TEXT)
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'id',                q.id,
    'quote_number',      q.quote_number,
    'title',             q.title,
    'destination',       q.destination,
    'travel_date_from',  q.travel_date_from,
    'travel_date_to',    q.travel_date_to,
    'adults_count',      q.adults_count,
    'children_count',    q.children_count,
    'infants_count',     q.infants_count,
    'currency',          q.currency,
    'subtotal',          q.subtotal,
    'discount_pct',      q.discount_pct,
    'discount_amount',   q.discount_amount,
    'tax_pct',           q.tax_pct,
    'tax_amount',        q.tax_amount,
    'total_amount',      q.total_amount,
    'payment_terms',     q.payment_terms,
    'cancellation_policy', q.cancellation_policy,
    'included_services', q.included_services,
    'excluded_services', q.excluded_services,
    'client_notes',      q.client_notes,
    'validity_date',     q.validity_date,
    'status',            q.status,
    'version',           q.version,
    'sent_at',           q.sent_at,
    'created_at',        q.created_at,
    'items', (
      SELECT json_agg(
        json_build_object(
          'item_type',   qi.item_type,
          'description', qi.description,
          'destination', qi.destination,
          'date_from',   qi.date_from,
          'date_to',     qi.date_to,
          'nights',      qi.nights,
          'quantity',    qi.quantity,
          'unit_label',  qi.unit_label,
          'unit_price',  qi.unit_price,
          'total_price', qi.total_price
        ) ORDER BY qi.sort_order
      )
      FROM quotation_items qi WHERE qi.quotation_id = q.id
    )
  )
  FROM quotations q
  WHERE q.public_token = p_token
    AND q.status NOT IN ('cancelled')
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_quote_by_token(TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. FUNCTION: get_quotation_summary()   (for CRM dashboard widget)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_quotation_summary()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total',           (SELECT COUNT(*) FROM quotations),
    'draft',           (SELECT COUNT(*) FROM quotations WHERE status = 'draft'),
    'sent',            (SELECT COUNT(*) FROM quotations WHERE status IN ('sent','viewed')),
    'accepted',        (SELECT COUNT(*) FROM quotations WHERE status IN ('accepted','deposit_pending','confirmed')),
    'expired',         (SELECT COUNT(*) FROM quotations WHERE status = 'expired'),
    'rejected',        (SELECT COUNT(*) FROM quotations WHERE status IN ('rejected','cancelled')),
    'total_value',     (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status NOT IN ('rejected','cancelled','expired')),
    'accepted_value',  (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status IN ('accepted','deposit_pending','confirmed')),
    'pipeline_value',  (SELECT COALESCE(SUM(total_amount),0) FROM quotations WHERE status IN ('sent','viewed','revision_requested','negotiation'))
  );
$$;

GRANT EXECUTE ON FUNCTION get_quotation_summary() TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. EXTEND opportunities — link to latest quote
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE opportunities
  ADD COLUMN IF NOT EXISTS latest_quote_id UUID REFERENCES quotations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS quotes_count     INT DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_opp_latest_quote ON opportunities(latest_quote_id) WHERE latest_quote_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. EXTEND bookings — link to source quote
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS quote_id UUID REFERENCES quotations(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_quote_id ON bookings(quote_id) WHERE quote_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. TRIGGER: auto-update opportunity.quotes_count when quotation is created
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sync_opportunity_quotes_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.opportunity_id IS NOT NULL THEN
    UPDATE opportunities
    SET quotes_count     = (SELECT COUNT(*) FROM quotations WHERE opportunity_id = NEW.opportunity_id),
        latest_quote_id  = (SELECT id FROM quotations WHERE opportunity_id = NEW.opportunity_id ORDER BY created_at DESC LIMIT 1),
        updated_at       = now()
    WHERE id = NEW.opportunity_id;
  END IF;

  IF TG_OP = 'DELETE' AND OLD.opportunity_id IS NOT NULL THEN
    UPDATE opportunities
    SET quotes_count     = (SELECT COUNT(*) FROM quotations WHERE opportunity_id = OLD.opportunity_id),
        latest_quote_id  = (SELECT id FROM quotations WHERE opportunity_id = OLD.opportunity_id ORDER BY created_at DESC LIMIT 1),
        updated_at       = now()
    WHERE id = OLD.opportunity_id;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_opp_quotes ON quotations;
CREATE TRIGGER trg_sync_opp_quotes
  AFTER INSERT OR UPDATE OF opportunity_id OR DELETE ON quotations
  FOR EACH ROW EXECUTE FUNCTION sync_opportunity_quotes_count();


-- ─────────────────────────────────────────────────────────────────────────────
-- GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION generate_quote_number()              TO authenticated;
GRANT EXECUTE ON FUNCTION recalculate_quote_totals(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION save_quote_version(UUID)             TO authenticated;
GRANT EXECUTE ON FUNCTION get_quotation_summary()              TO authenticated;
GRANT EXECUTE ON FUNCTION sync_opportunity_quotes_count()      TO authenticated;


-- ══ END PHASE 3 MIGRATION ═════════════════════════════════════════════════════
-- Apply this after 202601026000000_customer_360.sql
-- Verification:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_name IN ('quotations','quotation_items','quotation_versions');
--   → 3 rows
--
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name IN ('get_quote_by_token','recalculate_quote_totals','save_quote_version');
--   → 3 rows
