-- =============================================================================
-- MIGRATION: 202601041000000_phase8_complete.sql
-- Phase 8 Completion — fixes schema gaps found after partial implementation
-- Safe: additive only (ADD COLUMN IF NOT EXISTS, ALTER CONSTRAINT)
-- =============================================================================

-- ── 1. contract_seasons: add missing season_type column ───────────────────────
-- supplier-contracts.html inserts season_type but column never defined in 202601040
ALTER TABLE contract_seasons
  ADD COLUMN IF NOT EXISTS season_type TEXT NOT NULL DEFAULT 'regular'
    CHECK (season_type IN ('low','regular','high','peak','blackout'));

-- ── 2. supplier_contracts: add missing columns used by UI ─────────────────────
-- contract_number (auto-generated reference)
ALTER TABLE supplier_contracts
  ADD COLUMN IF NOT EXISTS contract_number    TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS signed_date        DATE,
  ADD COLUMN IF NOT EXISTS cancellation_policy TEXT;

-- Auto-generate contract_number on INSERT (pattern: SC-YYYY-NNNN)
CREATE SEQUENCE IF NOT EXISTS supplier_contract_seq START 1;

CREATE OR REPLACE FUNCTION generate_supplier_contract_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_number IS NULL THEN
    NEW.contract_number := 'SC-' || to_char(now(), 'YYYY') || '-' ||
                           lpad(nextval('supplier_contract_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_contract_number ON supplier_contracts;
CREATE TRIGGER trg_supplier_contract_number
  BEFORE INSERT ON supplier_contracts
  FOR EACH ROW EXECUTE FUNCTION generate_supplier_contract_number();

-- ── 3. partner_rates: fix override_type constraint mismatch ───────────────────
-- DB has 'fixed_net', UI sends 'net_rate' → saves fail with constraint violation.
-- Fix: replace constraint to accept both names.
ALTER TABLE partner_rates
  DROP CONSTRAINT IF EXISTS partner_rates_override_type_check;

ALTER TABLE partner_rates
  ADD CONSTRAINT partner_rates_override_type_check
    CHECK (override_type IN ('discount_pct','markup_pct','fixed_net','net_rate','commission_pct'));

-- ── 4. contract_rates: add missing cancellation_policy field ──────────────────
ALTER TABLE contract_rates
  ADD COLUMN IF NOT EXISTS min_stay    INTEGER,
  ADD COLUMN IF NOT EXISTS stop_sale   BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS notes       TEXT;

-- ── 5. b2b_partners: add partner_number auto-increment ────────────────────────
ALTER TABLE b2b_partners
  ADD COLUMN IF NOT EXISTS partner_number TEXT UNIQUE;

CREATE SEQUENCE IF NOT EXISTS b2b_partner_seq START 1;

CREATE OR REPLACE FUNCTION generate_b2b_partner_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.partner_number IS NULL THEN
    NEW.partner_number := 'B2B-' || to_char(now(), 'YYYY') || '-' ||
                          lpad(nextval('b2b_partner_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_partner_number ON b2b_partners;
CREATE TRIGGER trg_b2b_partner_number
  BEFORE INSERT ON b2b_partners
  FOR EACH ROW EXECUTE FUNCTION generate_b2b_partner_number();

-- ── 6. RPC: partner summary stats for b2b-partners KPI cards ─────────────────
CREATE OR REPLACE FUNCTION get_b2b_summary()
RETURNS JSON
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total_partners',    (SELECT count(*) FROM b2b_partners),
    'active_partners',   (SELECT count(*) FROM b2b_partners WHERE is_active = true),
    'strategic_partners',(SELECT count(*) FROM b2b_partners WHERE tier = 'strategic' AND is_active = true),
    'expiring_soon',     (SELECT count(*) FROM b2b_partners
                          WHERE contract_status = 'active'
                            AND contract_expiry IS NOT NULL
                            AND contract_expiry <= current_date + interval '60 days'),
    'total_contracts',   (SELECT count(*) FROM supplier_contracts),
    'active_contracts',  (SELECT count(*) FROM supplier_contracts WHERE status = 'active'),
    'expiring_contracts',(SELECT count(*) FROM supplier_contracts
                          WHERE status = 'active'
                            AND valid_to <= current_date + interval '30 days'),
    'total_rates',       (SELECT count(*) FROM partner_rates)
  );
$$;

GRANT EXECUTE ON FUNCTION get_b2b_summary() TO authenticated;

-- ── 7. RPC: contracts expiring alert (for dashboard widget) ───────────────────
CREATE OR REPLACE FUNCTION get_expiring_contracts(days_ahead INT DEFAULT 30)
RETURNS TABLE (
  id          UUID,
  supplier_id UUID,
  supplier_name TEXT,
  valid_to    DATE,
  status      TEXT,
  days_left   INT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    sc.id,
    sc.supplier_id,
    s.name_ar AS supplier_name,
    sc.valid_to,
    sc.status,
    (sc.valid_to - current_date)::INT AS days_left
  FROM supplier_contracts sc
  JOIN suppliers s ON s.id = sc.supplier_id
  WHERE sc.status = 'active'
    AND sc.valid_to <= current_date + (days_ahead || ' days')::interval
    AND sc.valid_to >= current_date
  ORDER BY sc.valid_to ASC;
$$;

GRANT EXECUTE ON FUNCTION get_expiring_contracts(INT) TO authenticated;

-- =============================================================================
-- Phase 8 schema gaps — FIXED
-- Changes:
--   contract_seasons.season_type         — added (was missing, UI used it)
--   supplier_contracts.contract_number   — added with auto-sequence
--   supplier_contracts.signed_date       — added
--   supplier_contracts.cancellation_policy — added
--   partner_rates override_type constraint — fixed (net_rate accepted)
--   contract_rates.min_stay / stop_sale  — added
--   b2b_partners.partner_number          — added with auto-sequence
--   get_b2b_summary()                    — new RPC
--   get_expiring_contracts()             — new RPC
-- =============================================================================
