-- ══════════════════════════════════════════════════════════════════════════════
--  PHASE 5 MIGRATION — Product, Service & Pricing Engine
--  File: supabase/migrations/202601029000000_pricing_engine.sql
--
--  Purpose: Dynamic pricing engine with rate plans, supplier rates,
--           seasonal rules, margin targets, B2B/B2C pricing modes,
--           and child/occupancy pricing.
--
--  New tables :
--    rate_plans          — Named pricing configurations (B2C, B2B, Corporate, etc.)
--    rate_plan_rules     — Seasonal / occupancy / market rules per plan
--    supplier_rates      — Contracted supplier rates per service/season
--    pricing_overrides   — Per-quote manual price override log
--    margin_settings     — Global and per-category margin targets
--
--  Modifies   :
--    service_catalog     — ADD rate_plan_id, margin_target_pct, child_price_pct
--    quotations          — ADD rate_plan_id, pricing_mode
--    itinerary_items     — ADD supplier_rate_id, rate_plan_id, exchange_rate
--
--  Safe       : additive only — no drops, no renames, no data changes
--  Run after  : 202601028000000_itinerary_builder.sql
-- ══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. MARGIN SETTINGS  (global + per-category targets)
--    Central config table — one row per category or 'global'.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS margin_settings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  scope           TEXT        NOT NULL UNIQUE,  -- 'global' | category name
  label_ar        TEXT        NOT NULL,
  min_margin_pct  NUMERIC(5,2) NOT NULL DEFAULT 15  CHECK (min_margin_pct >= 0),
  target_margin_pct NUMERIC(5,2) NOT NULL DEFAULT 25 CHECK (target_margin_pct >= 0),
  warn_below_pct  NUMERIC(5,2) NOT NULL DEFAULT 10  CHECK (warn_below_pct >= 0),
  block_below_pct NUMERIC(5,2)            DEFAULT 0  CHECK (block_below_pct >= 0),
  -- block_below_pct = 0 means no hard block
  updated_by      UUID        REFERENCES auth.users(id),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE margin_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ms_read"  ON margin_settings FOR SELECT USING (is_any_admin());
CREATE POLICY "ms_write" ON margin_settings FOR ALL   USING (can_write_financial());

-- Seed defaults
INSERT INTO margin_settings (scope, label_ar, min_margin_pct, target_margin_pct, warn_below_pct, block_below_pct)
VALUES
  ('global',     'عام (افتراضي)',         10, 20, 8,  0),
  ('hotel',      'فنادق',                 12, 22, 8,  0),
  ('transfer',   'نقل',                   15, 28, 10, 0),
  ('guide',      'مرشدون',                20, 35, 12, 0),
  ('activity',   'أنشطة وجولات',          20, 35, 12, 0),
  ('ticket',     'تذاكر دخول',            15, 30, 10, 0),
  ('meal',       'وجبات',                 25, 40, 15, 0),
  ('flight',     'طيران',                  8, 15,  5, 0),
  ('visa',       'تأشيرات',               15, 25, 10, 0),
  ('insurance',  'تأمين سفر',             20, 35, 15, 0),
  ('transport',  'باصات / مركبات',        15, 28, 10, 0),
  ('other',      'أخرى',                  10, 20,  8, 0)
ON CONFLICT (scope) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RATE PLANS
--    Named pricing configurations — e.g. "B2C Retail", "B2B Net", "VIP", etc.
--    Each plan defines a default pricing mode and markup/discount rules.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rate_plans (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT        UNIQUE NOT NULL,   -- e.g. RETAIL / B2B / VIP / CORP
  name_ar         TEXT        NOT NULL,
  name_en         TEXT,
  description     TEXT,

  -- Which customer segment this plan targets
  target_type     TEXT        DEFAULT 'b2c'
                              CHECK (target_type IN ('b2c','b2b','corporate','mice','vip','group','all')),

  -- Default pricing mode for services using this plan
  pricing_mode    TEXT        NOT NULL DEFAULT 'cost_plus'
                              CHECK (pricing_mode IN (
                                'cost_plus',       -- sell = cost + markup_pct
                                'margin_target',   -- sell = cost / (1 - margin_pct)
                                'fixed',           -- sell = fixed price from catalog
                                'contract'         -- sell = supplier contracted rate + markup
                              )),

  -- Markup / margin defaults (can be overridden per rule or per item)
  default_markup_pct    NUMERIC(6,2) DEFAULT 0,    -- used for cost_plus mode
  default_margin_pct    NUMERIC(6,2) DEFAULT 20,   -- used for margin_target mode
  default_discount_pct  NUMERIC(6,2) DEFAULT 0,    -- applied on top (e.g. B2B net discount)

  -- Child pricing (percentage of adult price)
  child_price_pct       NUMERIC(6,2) DEFAULT 75,   -- 75% of adult
  infant_price_pct      NUMERIC(6,2) DEFAULT 10,   -- 10% of adult
  single_supplement_pct NUMERIC(6,2) DEFAULT 30,   -- +30% for solo traveler

  -- Currency for this plan's rates
  currency        TEXT        DEFAULT 'EGP',

  is_active       BOOLEAN     DEFAULT TRUE,
  is_default      BOOLEAN     DEFAULT FALSE,  -- one plan flagged as default for new quotes
  sort_order      INT         DEFAULT 0,

  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE rate_plans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rp_read"  ON rate_plans FOR SELECT USING (is_any_admin());
CREATE POLICY "rp_write" ON rate_plans FOR ALL   USING (can_write_financial());

CREATE INDEX IF NOT EXISTS idx_rate_plans_active ON rate_plans(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_rate_plans_type   ON rate_plans(target_type);

-- Seed standard rate plans
INSERT INTO rate_plans (code, name_ar, name_en, target_type, pricing_mode, default_markup_pct, default_margin_pct, default_discount_pct, child_price_pct, single_supplement_pct, is_default)
VALUES
  ('RETAIL',   'تجزئة - B2C',          'B2C Retail',         'b2c',       'margin_target', 0,  25, 0,  75, 30, TRUE),
  ('B2B_NET',  'صافي - وكالات',         'B2B Net',            'b2b',       'cost_plus',     0,  15, 15, 75, 25, FALSE),
  ('CORP',     'شركات',                 'Corporate',          'corporate', 'margin_target', 0,  20, 10, 75, 30, FALSE),
  ('MICE',     'مؤتمرات وفعاليات',      'MICE',               'mice',      'margin_target', 0,  18, 0,  75, 0,  FALSE),
  ('VIP',      'VIP - كبار العملاء',   'VIP Premium',        'vip',       'fixed',         0,  35, 0,  80, 40, FALSE),
  ('GROUP',    'مجموعات',               'Group Rate',         'group',     'cost_plus',     10, 0,  0,  60, 0,  FALSE)
ON CONFLICT (code) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RATE PLAN RULES
--    Seasonal / destination / occupancy overrides within a plan.
--    Evaluated in priority order — first matching rule wins.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rate_plan_rules (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  rate_plan_id    UUID        NOT NULL REFERENCES rate_plans(id) ON DELETE CASCADE,

  -- Rule label
  name_ar         TEXT        NOT NULL,
  rule_type       TEXT        NOT NULL
                              CHECK (rule_type IN (
                                'seasonal',    -- date range override
                                'destination', -- destination override
                                'occupancy',   -- pax count override
                                'category',    -- service category override
                                'combined'     -- multiple conditions
                              )),

  -- Conditions (all nullable — omitted = always matches)
  date_from       DATE,                     -- season start
  date_to         DATE,                     -- season end
  destination     TEXT,                     -- e.g. 'القاهرة'
  service_category TEXT                     -- hotel/transfer/etc.
                              CHECK (service_category IS NULL OR service_category IN (
                                'hotel','transfer','guide','activity','ticket',
                                'meal','flight','visa','insurance','transport','camp','other'
                              )),
  min_pax         INT,                      -- minimum group size to trigger
  max_pax         INT,                      -- maximum group size

  -- Override values (override rate plan defaults when rule matches)
  pricing_mode    TEXT
                              CHECK (pricing_mode IS NULL OR pricing_mode IN (
                                'cost_plus','margin_target','fixed','contract'
                              )),
  markup_pct      NUMERIC(6,2),
  margin_pct      NUMERIC(6,2),
  discount_pct    NUMERIC(6,2),

  -- Rule weight — higher priority wins when multiple rules match
  priority        INT         DEFAULT 10,
  is_active       BOOLEAN     DEFAULT TRUE,

  notes           TEXT,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE rate_plan_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rpr_read"  ON rate_plan_rules FOR SELECT USING (is_any_admin());
CREATE POLICY "rpr_write" ON rate_plan_rules FOR ALL   USING (can_write_financial());

CREATE INDEX IF NOT EXISTS idx_rpr_plan     ON rate_plan_rules(rate_plan_id);
CREATE INDEX IF NOT EXISTS idx_rpr_dates    ON rate_plan_rules(date_from, date_to);
CREATE INDEX IF NOT EXISTS idx_rpr_priority ON rate_plan_rules(priority DESC);
CREATE INDEX IF NOT EXISTS idx_rpr_active   ON rate_plan_rules(is_active) WHERE is_active = TRUE;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. SUPPLIER RATES
--    Contracted rates per supplier per service category and season.
--    Used when pricing_mode = 'contract' to auto-fill cost.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS supplier_rates (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id       UUID        NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  service_catalog_id UUID       REFERENCES service_catalog(id) ON DELETE SET NULL,

  -- What this rate covers
  name_ar           TEXT        NOT NULL,
  service_category  TEXT        NOT NULL
                                CHECK (service_category IN (
                                  'hotel','transfer','guide','activity','ticket',
                                  'meal','flight','visa','insurance','transport','camp','other'
                                )),
  destination       TEXT,

  -- Rate details
  rate_type         TEXT        DEFAULT 'net'
                                CHECK (rate_type IN ('net','gross','commission')),
  unit              TEXT        DEFAULT 'per_person'
                                CHECK (unit IN ('per_person','per_group','per_room','per_vehicle','per_day','fixed')),
  currency          TEXT        DEFAULT 'EGP',
  cost_amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
  commission_pct    NUMERIC(5,2)  DEFAULT 0,   -- if rate_type = 'commission'

  -- Occupancy variants (for hotels)
  single_rate       NUMERIC(14,2),   -- single room rate
  double_rate       NUMERIC(14,2),   -- double room rate (per person)
  triple_rate       NUMERIC(14,2),   -- triple room rate (per person)
  child_rate        NUMERIC(14,2),   -- child rate
  infant_rate       NUMERIC(14,2),   -- infant rate

  -- Validity
  valid_from        DATE        NOT NULL,
  valid_to          DATE        NOT NULL,
  CHECK (valid_to >= valid_from),

  -- Contract reference
  contract_number   TEXT,
  release_days      INT         DEFAULT 0,    -- minimum days before travel to confirm
  min_pax           INT         DEFAULT 1,
  cancellation_policy TEXT,

  is_active         BOOLEAN     DEFAULT TRUE,
  notes             TEXT,

  created_by        UUID        REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE supplier_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sr_read"  ON supplier_rates FOR SELECT USING (is_any_admin());
CREATE POLICY "sr_write" ON supplier_rates FOR ALL   USING (can_write_financial());

CREATE INDEX IF NOT EXISTS idx_sr_supplier   ON supplier_rates(supplier_id);
CREATE INDEX IF NOT EXISTS idx_sr_catalog    ON supplier_rates(service_catalog_id);
CREATE INDEX IF NOT EXISTS idx_sr_category   ON supplier_rates(service_category);
CREATE INDEX IF NOT EXISTS idx_sr_dates      ON supplier_rates(valid_from, valid_to);
CREATE INDEX IF NOT EXISTS idx_sr_active     ON supplier_rates(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_sr_dest       ON supplier_rates(destination);


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. PRICING OVERRIDES
--    Audit trail when a user manually overrides a calculated price on a quote
--    or itinerary item. Supports approval workflow for margin violations.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS pricing_overrides (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Source of the override
  source_type       TEXT        NOT NULL CHECK (source_type IN ('quotation_item','itinerary_item')),
  source_id         UUID        NOT NULL,

  -- What changed
  field_name        TEXT        NOT NULL,   -- 'unit_price', 'unit_cost', 'discount_pct'
  old_value         NUMERIC(14,4),
  new_value         NUMERIC(14,4),
  reason            TEXT,

  -- Computed margin at time of override
  cost_at_override  NUMERIC(14,2),
  sell_at_override  NUMERIC(14,2),
  margin_at_override NUMERIC(5,2),

  -- Approval (if margin < block_below_pct)
  requires_approval BOOLEAN     DEFAULT FALSE,
  approved_by       UUID        REFERENCES auth.users(id),
  approved_at       TIMESTAMPTZ,
  status            TEXT        DEFAULT 'applied'
                                CHECK (status IN ('applied','pending_approval','approved','rejected')),

  created_by        UUID        REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE pricing_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "po_read"  ON pricing_overrides FOR SELECT USING (can_read_financial());
CREATE POLICY "po_write" ON pricing_overrides FOR ALL   USING (is_any_admin());

CREATE INDEX IF NOT EXISTS idx_po_source ON pricing_overrides(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_po_status ON pricing_overrides(status) WHERE status = 'pending_approval';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. EXTEND EXISTING TABLES
-- ─────────────────────────────────────────────────────────────────────────────

-- service_catalog: add pricing enrichment columns
ALTER TABLE service_catalog
  ADD COLUMN IF NOT EXISTS rate_plan_id       UUID REFERENCES rate_plans(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS margin_target_pct  NUMERIC(5,2),   -- override global margin for this service
  ADD COLUMN IF NOT EXISTS child_price_pct    NUMERIC(5,2),   -- child price as % of adult
  ADD COLUMN IF NOT EXISTS single_supplement  NUMERIC(14,2),  -- flat supplement for single occupancy
  ADD COLUMN IF NOT EXISTS min_pax            INT DEFAULT 1,
  ADD COLUMN IF NOT EXISTS max_pax            INT;

-- quotations: add rate plan linkage and pricing mode
ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS rate_plan_id       UUID REFERENCES rate_plans(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pricing_mode       TEXT
    CHECK (pricing_mode IS NULL OR pricing_mode IN ('cost_plus','margin_target','fixed','contract')),
  ADD COLUMN IF NOT EXISTS exchange_rate      NUMERIC(12,6) DEFAULT 1,   -- quote currency → EGP
  ADD COLUMN IF NOT EXISTS base_currency      TEXT DEFAULT 'EGP';

-- itinerary_items: add supplier rate linkage + exchange rate snapshot
ALTER TABLE itinerary_items
  ADD COLUMN IF NOT EXISTS supplier_rate_id   UUID REFERENCES supplier_rates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rate_plan_id       UUID REFERENCES rate_plans(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS exchange_rate      NUMERIC(12,6) DEFAULT 1,
  ADD COLUMN IF NOT EXISTS margin_pct         NUMERIC(5,2);  -- computed snapshot


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. PRICING CALCULATOR FUNCTION
--    Given cost, mode, and plan → returns sell price and margin.
--    Called from the frontend via RPC for live calculation.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION calculate_sell_price(
  p_cost          NUMERIC,
  p_pricing_mode  TEXT,      -- 'cost_plus' | 'margin_target' | 'fixed' | 'contract'
  p_markup_pct    NUMERIC,   -- used for cost_plus
  p_margin_pct    NUMERIC,   -- used for margin_target
  p_fixed_price   NUMERIC    -- used for fixed / contract
)
RETURNS TABLE (
  sell_price    NUMERIC,
  gross_profit  NUMERIC,
  margin_pct    NUMERIC
)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_sell    NUMERIC;
  v_profit  NUMERIC;
  v_margin  NUMERIC;
BEGIN
  CASE p_pricing_mode
    WHEN 'cost_plus' THEN
      v_sell := ROUND(p_cost * (1 + COALESCE(p_markup_pct, 0) / 100.0), 2);

    WHEN 'margin_target' THEN
      -- sell = cost / (1 - margin%)
      IF COALESCE(p_margin_pct, 0) >= 100 THEN
        RAISE EXCEPTION 'Margin target cannot be >= 100%%';
      END IF;
      v_sell := ROUND(p_cost / NULLIF(1 - COALESCE(p_margin_pct, 0) / 100.0, 0), 2);

    WHEN 'fixed', 'contract' THEN
      v_sell := COALESCE(p_fixed_price, p_cost);

    ELSE
      v_sell := p_cost;
  END CASE;

  v_profit := v_sell - p_cost;
  v_margin := CASE WHEN v_sell > 0 THEN ROUND(v_profit / v_sell * 100, 2) ELSE 0 END;

  RETURN QUERY SELECT v_sell, v_profit, v_margin;
END;
$$;

GRANT EXECUTE ON FUNCTION calculate_sell_price(NUMERIC, TEXT, NUMERIC, NUMERIC, NUMERIC) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. GET APPLICABLE SUPPLIER RATE FUNCTION
--    Finds the best matching supplier rate for a given service/date/destination.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_supplier_rate(
  p_supplier_id       UUID,
  p_service_catalog_id UUID,   -- optional
  p_category          TEXT,
  p_destination       TEXT,
  p_travel_date       DATE
)
RETURNS TABLE (
  rate_id       UUID,
  cost_amount   NUMERIC,
  single_rate   NUMERIC,
  double_rate   NUMERIC,
  currency      TEXT,
  unit          TEXT,
  contract_number TEXT,
  release_days  INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT
    sr.id,
    sr.cost_amount,
    sr.single_rate,
    sr.double_rate,
    sr.currency,
    sr.unit,
    sr.contract_number,
    sr.release_days
  FROM supplier_rates sr
  WHERE
    sr.supplier_id = p_supplier_id
    AND sr.is_active = TRUE
    AND sr.valid_from <= COALESCE(p_travel_date, CURRENT_DATE)
    AND sr.valid_to   >= COALESCE(p_travel_date, CURRENT_DATE)
    AND (sr.service_category = p_category OR p_category IS NULL)
    AND (sr.destination = p_destination OR sr.destination IS NULL OR p_destination IS NULL)
    AND (sr.service_catalog_id = p_service_catalog_id
         OR sr.service_catalog_id IS NULL
         OR p_service_catalog_id IS NULL)
  ORDER BY
    -- Prefer exact catalog match, then destination match, then most recent valid_from
    (sr.service_catalog_id = p_service_catalog_id) DESC,
    (sr.destination = p_destination) DESC,
    sr.valid_from DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION get_supplier_rate(UUID, UUID, TEXT, TEXT, DATE) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. GET MARGIN SETTING FUNCTION
--    Returns margin target for a given service category.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_margin_setting(p_category TEXT)
RETURNS TABLE (
  min_margin_pct    NUMERIC,
  target_margin_pct NUMERIC,
  warn_below_pct    NUMERIC,
  block_below_pct   NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    COALESCE(ms.min_margin_pct,    g.min_margin_pct),
    COALESCE(ms.target_margin_pct, g.target_margin_pct),
    COALESCE(ms.warn_below_pct,    g.warn_below_pct),
    COALESCE(ms.block_below_pct,   g.block_below_pct)
  FROM margin_settings g
  LEFT JOIN margin_settings ms ON ms.scope = p_category AND ms.scope != 'global'
  WHERE g.scope = 'global'
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION get_margin_setting(TEXT) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. RECALCULATE QUOTATION TOTALS FUNCTION
--     Recomputes subtotal, cost_total, gross_profit, margin_pct from items.
--     Called after item changes on a quotation.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalculate_quotation_totals(p_quote_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_subtotal    NUMERIC;
  v_cost_total  NUMERIC;
  v_discount    NUMERIC;
  v_tax         NUMERIC;
  v_total       NUMERIC;
  v_profit      NUMERIC;
  v_margin      NUMERIC;
  v_disc_pct    NUMERIC;
  v_tax_pct     NUMERIC;
BEGIN
  SELECT
    COALESCE(SUM(total_price), 0),
    COALESCE(SUM(total_cost),  0)
  INTO v_subtotal, v_cost_total
  FROM quotation_items
  WHERE quotation_id = p_quote_id;

  SELECT discount_pct, tax_pct
  INTO v_disc_pct, v_tax_pct
  FROM quotations
  WHERE id = p_quote_id;

  v_discount := ROUND(v_subtotal * COALESCE(v_disc_pct, 0) / 100.0, 2);
  v_tax      := ROUND((v_subtotal - v_discount) * COALESCE(v_tax_pct, 0) / 100.0, 2);
  v_total    := v_subtotal - v_discount + v_tax;
  v_profit   := v_total - v_cost_total;
  v_margin   := CASE WHEN v_total > 0 THEN ROUND(v_profit / v_total * 100, 2) ELSE 0 END;

  UPDATE quotations SET
    subtotal       = v_subtotal,
    cost_total     = v_cost_total,
    discount_amount = v_discount,
    tax_amount     = v_tax,
    total_amount   = v_total,
    gross_profit   = v_profit,
    margin_pct     = v_margin,
    updated_at     = now()
  WHERE id = p_quote_id;
END;
$$;

GRANT EXECUTE ON FUNCTION recalculate_quotation_totals(UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 11. AUTO-RECALC TRIGGER ON QUOTATION ITEMS
--     Fires after any insert/update/delete on quotation_items → recalc totals.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION trg_fn_recalc_quote_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_quote_id UUID;
BEGIN
  v_quote_id := COALESCE(NEW.quotation_id, OLD.quotation_id);
  IF v_quote_id IS NOT NULL THEN
    PERFORM recalculate_quotation_totals(v_quote_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_recalc_quote_totals ON quotation_items;
CREATE TRIGGER trg_recalc_quote_totals
  AFTER INSERT OR UPDATE OR DELETE ON quotation_items
  FOR EACH ROW EXECUTE FUNCTION trg_fn_recalc_quote_totals();


-- ─────────────────────────────────────────────────────────────────────────────
-- 12. PRICING SUMMARY VIEW
--     Per-quote pricing summary with margin analysis.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW pricing_summary AS
SELECT
  q.id                              AS quotation_id,
  q.quote_number,
  q.title,
  q.currency,
  q.pricing_mode,
  rp.name_ar                        AS rate_plan_name,
  q.adults_count,
  q.children_count,
  q.total_amount,
  q.cost_total,
  q.gross_profit,
  q.margin_pct,
  q.discount_pct,
  q.discount_amount,
  q.tax_amount,
  CASE
    WHEN q.adults_count > 0
    THEN ROUND(q.total_amount / q.adults_count, 2)
    ELSE 0
  END                               AS price_per_adult,
  CASE
    WHEN q.adults_count > 0
    THEN ROUND(q.cost_total / q.adults_count, 2)
    ELSE 0
  END                               AS cost_per_adult,
  COUNT(qi.id)                      AS item_count,
  -- Category breakdown
  COALESCE(SUM(CASE WHEN qi.item_type = 'hotel'     THEN qi.total_price ELSE 0 END), 0) AS hotel_sell,
  COALESCE(SUM(CASE WHEN qi.item_type = 'flight'    THEN qi.total_price ELSE 0 END), 0) AS flight_sell,
  COALESCE(SUM(CASE WHEN qi.item_type = 'transport' THEN qi.total_price ELSE 0 END), 0) AS transport_sell,
  COALESCE(SUM(CASE WHEN qi.item_type = 'guide'     THEN qi.total_price ELSE 0 END), 0) AS guide_sell,
  COALESCE(SUM(CASE WHEN qi.item_type = 'visa'      THEN qi.total_price ELSE 0 END), 0) AS visa_sell,
  COALESCE(SUM(CASE WHEN qi.item_type = 'excursion' THEN qi.total_price ELSE 0 END), 0) AS excursion_sell,
  -- Cost breakdown
  COALESCE(SUM(CASE WHEN qi.item_type = 'hotel'     THEN qi.total_cost ELSE 0 END), 0) AS hotel_cost,
  COALESCE(SUM(CASE WHEN qi.item_type = 'flight'    THEN qi.total_cost ELSE 0 END), 0) AS flight_cost,
  COALESCE(SUM(CASE WHEN qi.item_type = 'transport' THEN qi.total_cost ELSE 0 END), 0) AS transport_cost
FROM quotations q
LEFT JOIN rate_plans rp     ON rp.id = q.rate_plan_id
LEFT JOIN quotation_items qi ON qi.quotation_id = q.id
GROUP BY q.id, rp.name_ar;

GRANT SELECT ON pricing_summary TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 13. SUPPLIER RATE EXPIRY VIEW
--     Highlights rates expiring soon — for contracting dashboard.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW supplier_rates_expiry AS
SELECT
  sr.id,
  sr.name_ar,
  sr.service_category,
  sr.destination,
  sr.valid_from,
  sr.valid_to,
  sr.cost_amount,
  sr.currency,
  s.name_ar                         AS supplier_name,
  s.type                            AS supplier_type,
  (sr.valid_to - CURRENT_DATE)      AS days_remaining,
  CASE
    WHEN sr.valid_to < CURRENT_DATE           THEN 'expired'
    WHEN sr.valid_to < CURRENT_DATE + 30      THEN 'expiring_soon'
    WHEN sr.valid_to < CURRENT_DATE + 90      THEN 'expiring_90'
    ELSE 'valid'
  END                               AS expiry_status
FROM supplier_rates sr
JOIN suppliers s ON s.id = sr.supplier_id
WHERE sr.is_active = TRUE
ORDER BY sr.valid_to ASC;

GRANT SELECT ON supplier_rates_expiry TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT SELECT ON margin_settings        TO authenticated;
GRANT SELECT ON rate_plans             TO authenticated;
GRANT SELECT ON rate_plan_rules        TO authenticated;
GRANT SELECT ON supplier_rates         TO authenticated;
GRANT SELECT ON pricing_overrides      TO authenticated;
GRANT SELECT ON pricing_summary        TO authenticated;
GRANT SELECT ON supplier_rates_expiry  TO authenticated;


-- ══ END PHASE 5 MIGRATION ═════════════════════════════════════════════════════
-- Verification:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_name IN (
--     'margin_settings','rate_plans','rate_plan_rules','supplier_rates','pricing_overrides'
--   );
--   → 5 rows
--
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_name IN (
--     'calculate_sell_price','get_supplier_rate','get_margin_setting',
--     'recalculate_quotation_totals'
--   );
--   → 4 rows
--
--   SELECT COUNT(*) FROM rate_plans;     → 6
--   SELECT COUNT(*) FROM margin_settings; → 12
