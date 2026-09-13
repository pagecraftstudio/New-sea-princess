-- ═══════════════════════════════════════════════════════════════════════════════
-- PHASE 8 — B2B Partners, Supplier Contracts, Partner Rates
-- Migration: 202601040000000_phase8_b2b_contracts.sql
-- Additive only. No existing tables modified destructively.
-- Depends on: pricing_engine (rate_plans), customers_suppliers (suppliers)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── 1. B2B PARTNERS ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS b2b_partners (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name          TEXT        NOT NULL,
  trading_name        TEXT,
  partner_type        TEXT        NOT NULL DEFAULT 'agency'
                      CHECK (partner_type IN ('agency','wholesaler','ota','corporate','mice','school','ngo','government','other')),
  tier                TEXT        NOT NULL DEFAULT 'standard'
                      CHECK (tier IN ('strategic','platinum','gold','silver','standard','new')),
  country             TEXT,
  city                TEXT,
  website             TEXT,
  email               TEXT,
  phone               TEXT,
  whatsapp            TEXT,
  currency            TEXT        NOT NULL DEFAULT 'EGP',
  credit_limit        NUMERIC(14,2) NOT NULL DEFAULT 0,
  payment_terms_days  INTEGER     NOT NULL DEFAULT 30,
  rate_plan_id        UUID        REFERENCES rate_plans(id) ON DELETE SET NULL,
  contract_status     TEXT        NOT NULL DEFAULT 'active'
                      CHECK (contract_status IN ('draft','active','expired','suspended','terminated')),
  contract_expiry     DATE,
  is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
  notes               TEXT,
  created_by          UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_b2b_partners_type     ON b2b_partners(partner_type);
CREATE INDEX IF NOT EXISTS idx_b2b_partners_tier     ON b2b_partners(tier);
CREATE INDEX IF NOT EXISTS idx_b2b_partners_active   ON b2b_partners(is_active);
CREATE INDEX IF NOT EXISTS idx_b2b_partners_contract ON b2b_partners(contract_status);

CREATE TRIGGER trg_b2b_partners_updated_at
  BEFORE UPDATE ON b2b_partners
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE b2b_partners ENABLE ROW LEVEL SECURITY;
CREATE POLICY "b2b_partners_admin" ON b2b_partners FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 2. PARTNER CONTACTS ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS partner_contacts (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id  UUID        NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  full_name   TEXT        NOT NULL,
  role        TEXT,
  email       TEXT,
  phone       TEXT,
  whatsapp    TEXT,
  is_primary  BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_partner_contacts_partner ON partner_contacts(partner_id);

ALTER TABLE partner_contacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "partner_contacts_admin" ON partner_contacts FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 3. PARTNER RATES (overrides on top of rate_plans) ──────────────────────
CREATE TABLE IF NOT EXISTS partner_rates (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id       UUID        NOT NULL REFERENCES b2b_partners(id) ON DELETE CASCADE,
  rate_plan_id     UUID        REFERENCES rate_plans(id) ON DELETE SET NULL,
  service_category TEXT        NOT NULL DEFAULT 'general',
  destination      TEXT,
  override_type    TEXT        NOT NULL DEFAULT 'discount_pct'
                   CHECK (override_type IN ('discount_pct','markup_pct','fixed_net','commission_pct')),
  override_value   NUMERIC(10,4) NOT NULL DEFAULT 0,
  valid_from       DATE,
  valid_to         DATE,
  notes            TEXT,
  created_by       UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_partner_rates_partner ON partner_rates(partner_id);
CREATE INDEX IF NOT EXISTS idx_partner_rates_category ON partner_rates(service_category);

CREATE TRIGGER trg_partner_rates_updated_at
  BEFORE UPDATE ON partner_rates
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE partner_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "partner_rates_admin" ON partner_rates FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 4. SUPPLIER CONTRACTS ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS supplier_contracts (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id         UUID        NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  currency            TEXT        NOT NULL DEFAULT 'EGP',
  valid_from          DATE        NOT NULL,
  valid_to            DATE        NOT NULL,
  destination         TEXT,
  market              TEXT        NOT NULL DEFAULT 'all',
  rate_basis          TEXT        NOT NULL DEFAULT 'net'
                      CHECK (rate_basis IN ('net','gross','commission')),
  commission_pct      NUMERIC(5,2) NOT NULL DEFAULT 0,
  payment_terms_days  INTEGER     NOT NULL DEFAULT 30,
  release_days        INTEGER     NOT NULL DEFAULT 0,
  status              TEXT        NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','active','expired','terminated')),
  notes               TEXT,
  created_by          UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_supplier_contracts_supplier ON supplier_contracts(supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_contracts_status   ON supplier_contracts(status);
CREATE INDEX IF NOT EXISTS idx_supplier_contracts_dates    ON supplier_contracts(valid_from, valid_to);

CREATE TRIGGER trg_supplier_contracts_updated_at
  BEFORE UPDATE ON supplier_contracts
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE supplier_contracts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_contracts_admin" ON supplier_contracts FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 5. CONTRACT SEASONS ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS contract_seasons (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID        NOT NULL REFERENCES supplier_contracts(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  date_from   DATE        NOT NULL,
  date_to     DATE        NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contract_seasons_contract ON contract_seasons(contract_id);

ALTER TABLE contract_seasons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract_seasons_admin" ON contract_seasons FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 6. CONTRACT RATES ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS contract_rates (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id      UUID          NOT NULL REFERENCES supplier_contracts(id) ON DELETE CASCADE,
  season_id        UUID          REFERENCES contract_seasons(id) ON DELETE SET NULL,
  service_category TEXT          NOT NULL DEFAULT 'hotel',
  service_name     TEXT,
  room_type        TEXT,
  board_basis      TEXT,
  currency         TEXT          NOT NULL DEFAULT 'EGP',
  single_rate      NUMERIC(14,2),
  double_rate      NUMERIC(14,2),
  triple_rate      NUMERIC(14,2),
  child_rate       NUMERIC(14,2),
  infant_rate      NUMERIC(14,2),
  extra_bed_rate   NUMERIC(14,2),
  notes            TEXT,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contract_rates_contract ON contract_rates(contract_id);
CREATE INDEX IF NOT EXISTS idx_contract_rates_season   ON contract_rates(season_id);

CREATE TRIGGER trg_contract_rates_updated_at
  BEFORE UPDATE ON contract_rates
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE contract_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract_rates_admin" ON contract_rates FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 7. PERMISSIONS ─────────────────────────────────────────────────────────
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('manage_b2b_partners',    'إدارة شركاء B2B',        'الشراكات', ARRAY['super_admin','admin','sales_agent','booking_agent']),
  ('view_b2b_partners',      'عرض شركاء B2B',          'الشراكات', ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent','auditor']),
  ('manage_supplier_contracts','إدارة عقود الموردين',  'الموردون', ARRAY['super_admin','admin','booking_agent']),
  ('view_supplier_contracts', 'عرض عقود الموردين',     'الموردون', ARRAY['super_admin','admin','financial_manager','sales_agent','booking_agent','auditor'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- ═══ END PHASE 8 ═════════════════════════════════════════════════════════════
