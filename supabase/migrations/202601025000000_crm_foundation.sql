-- ═══════════════════════════════════════════════════════════════════════
-- MIGRATION: 202601025000000_crm_foundation.sql
-- Phase 1 — Sales CRM Foundation
-- New Sea Princess / Flow Travel DMC Operating System
--
-- Creates: customers, leads, lead_activities, tasks, opportunities
-- Modifies: bookings (add nullable FKs)
-- RLS: all tables hardened from creation
-- Safe: additive only — zero changes to existing tables or triggers
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1. CUSTOMERS ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_number TEXT        UNIQUE,             -- AUTO: CUS-YYYY-NNNN
  full_name       TEXT        NOT NULL,
  email           TEXT,
  phone           TEXT,
  whatsapp        TEXT,
  nationality     TEXT,
  language        TEXT        DEFAULT 'ar',
  customer_type   TEXT        DEFAULT 'b2c'
                              CHECK (customer_type IN ('b2c','b2b','corporate','mice')),
  segment         TEXT,                           -- returning / vip / family / etc.
  source          TEXT,                           -- website / whatsapp / referral / etc.
  vip             BOOLEAN     DEFAULT FALSE,
  notes           TEXT,
  user_id         UUID        REFERENCES auth.users(id),   -- if B2C registered
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS customer_seq START 1;

CREATE OR REPLACE FUNCTION generate_customer_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.customer_number := 'CUS-' || to_char(now(), 'YYYY') || '-' ||
                         lpad(nextval('customer_seq')::text, 4, '0');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_number ON customers;
CREATE TRIGGER trg_customer_number
  BEFORE INSERT ON customers
  FOR EACH ROW
  WHEN (NEW.customer_number IS NULL)
  EXECUTE FUNCTION generate_customer_number();

ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_admin_read"  ON customers FOR SELECT USING (can_read_bookings());
CREATE POLICY "customers_admin_write" ON customers FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "customers_admin_update" ON customers FOR UPDATE USING (can_write_bookings());
CREATE POLICY "customers_self_read"   ON customers FOR SELECT USING (user_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_customers_email    ON customers(email);
CREATE INDEX IF NOT EXISTS idx_customers_phone    ON customers(phone);
CREATE INDEX IF NOT EXISTS idx_customers_type     ON customers(customer_type);
CREATE INDEX IF NOT EXISTS idx_customers_user_id  ON customers(user_id);

-- ── 2. LEADS ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS leads (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_number       TEXT        UNIQUE,             -- AUTO: LEAD-YYYY-NNNN
  customer_id       UUID        REFERENCES customers(id),  -- set on conversion
  full_name         TEXT        NOT NULL,
  email             TEXT,
  phone             TEXT,
  whatsapp          TEXT,
  nationality       TEXT,
  language          TEXT        DEFAULT 'ar',
  lead_type         TEXT        DEFAULT 'b2c'
                                CHECK (lead_type IN ('b2c','b2b','corporate','mice')),
  source            TEXT        DEFAULT 'manual',   -- website/whatsapp/phone/email/social/referral/b2b/manual
  source_detail     TEXT,                           -- campaign name, referrer name, etc.
  destination       TEXT,
  travel_date_from  DATE,
  travel_date_to    DATE,
  adults_count      INT         DEFAULT 1,
  children_count    INT         DEFAULT 0,
  infants_count     INT         DEFAULT 0,
  budget_estimate   NUMERIC(12,2),
  budget_currency   TEXT        DEFAULT 'EGP',
  travel_style      TEXT,                           -- luxury / budget / adventure / religious
  interests         TEXT[],
  status            TEXT        DEFAULT 'new'
                                CHECK (status IN (
                                  'new','contacted','qualified','unqualified',
                                  'opportunity','won','lost','nurture'
                                )),
  priority          TEXT        DEFAULT 'medium'
                                CHECK (priority IN ('low','medium','high','urgent')),
  lead_score        INT         DEFAULT 0,
  assigned_to       UUID        REFERENCES auth.users(id),
  next_follow_up    TIMESTAMPTZ,
  notes             TEXT,
  lost_reason       TEXT,
  lost_detail       TEXT,
  converted_at      TIMESTAMPTZ,
  created_by        UUID        REFERENCES auth.users(id),
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS lead_seq START 1;

CREATE OR REPLACE FUNCTION generate_lead_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.lead_number := 'LEAD-' || to_char(now(), 'YYYY') || '-' ||
                     lpad(nextval('lead_seq')::text, 4, '0');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lead_number ON leads;
CREATE TRIGGER trg_lead_number
  BEFORE INSERT ON leads
  FOR EACH ROW
  WHEN (NEW.lead_number IS NULL)
  EXECUTE FUNCTION generate_lead_number();

-- updated_at auto-refresh
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_leads_updated_at ON leads;
CREATE TRIGGER trg_leads_updated_at
  BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE leads ENABLE ROW LEVEL SECURITY;

-- Ownership-level RLS: sales_agent sees own leads; managers see all
CREATE POLICY "leads_read" ON leads FOR SELECT USING (
  assigned_to = auth.uid()
  OR can_approve_financial()
  OR auth_role() IN ('super_admin','admin','auditor')
);
CREATE POLICY "leads_insert" ON leads FOR INSERT WITH CHECK (
  can_write_bookings()
);
CREATE POLICY "leads_update" ON leads FOR UPDATE USING (
  assigned_to = auth.uid()
  OR auth_role() IN ('super_admin','admin','financial_manager')
);
CREATE POLICY "leads_delete" ON leads FOR DELETE USING (
  auth_role() IN ('super_admin','admin')
);

CREATE INDEX IF NOT EXISTS idx_leads_assigned_to   ON leads(assigned_to);
CREATE INDEX IF NOT EXISTS idx_leads_status        ON leads(status);
CREATE INDEX IF NOT EXISTS idx_leads_customer_id   ON leads(customer_id);
CREATE INDEX IF NOT EXISTS idx_leads_created_at    ON leads(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_next_followup ON leads(next_follow_up) WHERE next_follow_up IS NOT NULL;

-- ── 3. LEAD ACTIVITIES ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS lead_activities (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id      UUID        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  activity_type TEXT       NOT NULL
                           CHECK (activity_type IN (
                             'call','email','whatsapp','meeting','note',
                             'follow_up','status_change','assignment','other'
                           )),
  subject      TEXT,
  body         TEXT,
  outcome      TEXT,
  next_action  TEXT,
  due_at       TIMESTAMPTZ,
  done         BOOLEAN     DEFAULT FALSE,
  done_at      TIMESTAMPTZ,
  created_by   UUID        REFERENCES auth.users(id),
  created_at   TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE lead_activities ENABLE ROW LEVEL SECURITY;

-- Inherit lead visibility: if you can see the lead you can see its activities
CREATE POLICY "lead_activities_read" ON lead_activities FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM leads l WHERE l.id = lead_id
    AND (
      l.assigned_to = auth.uid()
      OR can_approve_financial()
      OR auth_role() IN ('super_admin','admin','auditor')
    )
  )
);
CREATE POLICY "lead_activities_write" ON lead_activities FOR INSERT WITH CHECK (
  can_write_bookings()
);
CREATE POLICY "lead_activities_update" ON lead_activities FOR UPDATE USING (
  created_by = auth.uid() OR auth_role() IN ('super_admin','admin')
);

CREATE INDEX IF NOT EXISTS idx_lead_activities_lead_id    ON lead_activities(lead_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_lead_activities_due_at     ON lead_activities(due_at) WHERE due_at IS NOT NULL AND done = FALSE;

-- ── 4. TASKS ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tasks (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  title        TEXT        NOT NULL,
  description  TEXT,
  task_type    TEXT        DEFAULT 'follow_up'
                           CHECK (task_type IN (
                             'follow_up','call','email','whatsapp','meeting',
                             'document','quote','other'
                           )),
  priority     TEXT        DEFAULT 'medium'
                           CHECK (priority IN ('low','medium','high','urgent')),
  status       TEXT        DEFAULT 'open'
                           CHECK (status IN ('open','in_progress','done','cancelled')),
  lead_id      UUID        REFERENCES leads(id) ON DELETE SET NULL,
  -- opportunity_id added via ALTER TABLE after opportunities is created (section 6)
  assigned_to  UUID        REFERENCES auth.users(id),
  due_at       TIMESTAMPTZ,
  done_at      TIMESTAMPTZ,
  created_by   UUID        REFERENCES auth.users(id),
  created_at   TIMESTAMPTZ DEFAULT now(),
  updated_at   TIMESTAMPTZ DEFAULT now()
);

-- Note: opportunity_id FK is added after opportunities table is created below (ALTER TABLE)

DROP TRIGGER IF EXISTS trg_tasks_updated_at ON tasks;
CREATE TRIGGER trg_tasks_updated_at
  BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tasks_read" ON tasks FOR SELECT USING (
  assigned_to = auth.uid()
  OR created_by = auth.uid()
  OR auth_role() IN ('super_admin','admin','financial_manager','auditor')
);
CREATE POLICY "tasks_write" ON tasks FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "tasks_update" ON tasks FOR UPDATE USING (
  assigned_to = auth.uid()
  OR created_by = auth.uid()
  OR auth_role() IN ('super_admin','admin')
);

CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_lead_id     ON tasks(lead_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status      ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_at      ON tasks(due_at) WHERE due_at IS NOT NULL AND status != 'done';

-- ── 5. OPPORTUNITIES ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS opportunities (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  opp_number      TEXT        UNIQUE,             -- AUTO: OPP-YYYY-NNNN
  lead_id         UUID        REFERENCES leads(id),
  customer_id     UUID        REFERENCES customers(id),
  title           TEXT        NOT NULL,
  destination     TEXT,
  travel_date_from DATE,
  travel_date_to  DATE,
  adults_count    INT         DEFAULT 1,
  children_count  INT         DEFAULT 0,
  infants_count   INT         DEFAULT 0,
  estimated_value NUMERIC(12,2),
  currency        TEXT        DEFAULT 'EGP',
  probability     INT         DEFAULT 20 CHECK (probability BETWEEN 0 AND 100),
  expected_close  DATE,
  stage           TEXT        DEFAULT 'new'
                              CHECK (stage IN (
                                'new','qualification','discovery','itinerary',
                                'quote','follow_up','negotiation','deposit_pending',
                                'won','lost'
                              )),
  sales_owner     UUID        REFERENCES auth.users(id),
  notes           TEXT,
  lost_reason     TEXT,
  won_at          TIMESTAMPTZ,
  lost_at         TIMESTAMPTZ,
  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS opp_seq START 1;

CREATE OR REPLACE FUNCTION generate_opp_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.opp_number := 'OPP-' || to_char(now(), 'YYYY') || '-' ||
                    lpad(nextval('opp_seq')::text, 4, '0');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_opp_number ON opportunities;
CREATE TRIGGER trg_opp_number
  BEFORE INSERT ON opportunities
  FOR EACH ROW
  WHEN (NEW.opp_number IS NULL)
  EXECUTE FUNCTION generate_opp_number();

DROP TRIGGER IF EXISTS trg_opportunities_updated_at ON opportunities;
CREATE TRIGGER trg_opportunities_updated_at
  BEFORE UPDATE ON opportunities
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

ALTER TABLE opportunities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "opp_read" ON opportunities FOR SELECT USING (
  sales_owner = auth.uid()
  OR can_approve_financial()
  OR auth_role() IN ('super_admin','admin','auditor')
);
CREATE POLICY "opp_insert" ON opportunities FOR INSERT WITH CHECK (can_write_bookings());
CREATE POLICY "opp_update" ON opportunities FOR UPDATE USING (
  sales_owner = auth.uid()
  OR auth_role() IN ('super_admin','admin','financial_manager')
);

CREATE INDEX IF NOT EXISTS idx_opp_lead_id      ON opportunities(lead_id);
CREATE INDEX IF NOT EXISTS idx_opp_customer_id  ON opportunities(customer_id);
CREATE INDEX IF NOT EXISTS idx_opp_stage        ON opportunities(stage);
CREATE INDEX IF NOT EXISTS idx_opp_sales_owner  ON opportunities(sales_owner);
CREATE INDEX IF NOT EXISTS idx_opp_created_at   ON opportunities(created_at DESC);

-- ── 6. ADD opportunity_id FK to tasks (now that opportunities exists) ────────
ALTER TABLE tasks
  ADD COLUMN IF NOT EXISTS opportunity_id UUID REFERENCES opportunities(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_opportunity_id ON tasks(opportunity_id) WHERE opportunity_id IS NOT NULL;

-- ── 7. EXTEND bookings (backward-safe nullable FKs) ─────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS lead_id         UUID REFERENCES leads(id),
  ADD COLUMN IF NOT EXISTS opportunity_id  UUID REFERENCES opportunities(id),
  ADD COLUMN IF NOT EXISTS customer_id     UUID REFERENCES customers(id),
  ADD COLUMN IF NOT EXISTS booking_source  TEXT DEFAULT 'direct';

CREATE INDEX IF NOT EXISTS idx_bookings_lead_id        ON bookings(lead_id) WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_opportunity_id ON bookings(opportunity_id) WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_customer_id    ON bookings(customer_id) WHERE customer_id IS NOT NULL;

-- ── 8. GRANT EXECUTE on helper to authenticated ──────────────────────────────
GRANT EXECUTE ON FUNCTION generate_customer_number() TO authenticated;
GRANT EXECUTE ON FUNCTION generate_lead_number()     TO authenticated;
GRANT EXECUTE ON FUNCTION generate_opp_number()      TO authenticated;
GRANT EXECUTE ON FUNCTION touch_updated_at()          TO authenticated;

-- ── 9. CRM SUMMARY RPC (for dashboard widget) ────────────────────────────────
CREATE OR REPLACE FUNCTION get_crm_summary()
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'leads_total',       (SELECT count(*) FROM leads),
    'leads_new',         (SELECT count(*) FROM leads WHERE status = 'new'),
    'leads_contacted',   (SELECT count(*) FROM leads WHERE status = 'contacted'),
    'leads_qualified',   (SELECT count(*) FROM leads WHERE status = 'qualified'),
    'leads_won',         (SELECT count(*) FROM leads WHERE status = 'won'),
    'leads_lost',        (SELECT count(*) FROM leads WHERE status = 'lost'),
    'overdue_followups', (SELECT count(*) FROM leads WHERE next_follow_up < now() AND status NOT IN ('won','lost')),
    'open_tasks',        (SELECT count(*) FROM tasks WHERE status != 'done'),
    'overdue_tasks',     (SELECT count(*) FROM tasks WHERE due_at < now() AND status != 'done'),
    'pipeline_count',    (SELECT count(*) FROM opportunities WHERE stage NOT IN ('won','lost')),
    'pipeline_value',    (SELECT COALESCE(sum(estimated_value), 0) FROM opportunities WHERE stage NOT IN ('won','lost')),
    'won_value',         (SELECT COALESCE(sum(estimated_value), 0) FROM opportunities WHERE stage = 'won')
  );
$$;

GRANT EXECUTE ON FUNCTION get_crm_summary() TO authenticated;

-- ── DONE ────────────────────────────────────────────────────────────────────
-- Apply this migration, then run verification tests.
-- Zero risk: all changes are additive. No existing table modified destructively.
