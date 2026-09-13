-- ============================================================
-- Migration 050 — Phase 14: Marketing & Sales Automation
--
-- New tables:
--   marketing_segments      — dynamic customer/lead segments
--   marketing_campaigns     — email/whatsapp campaigns
--   campaign_members        — recipients per campaign
--   automation_rules        — trigger→action rules engine
--   automation_executions   — execution log per rule instance
--   abandoned_bookings      — tracks incomplete booking funnels
--
-- Extends:
--   page_events             — add metadata column for richer tracking
--
-- Safe: additive only
-- Run after: 202601049000000_phase13_customer_portal.sql
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. MARKETING SEGMENTS
--    Dynamic filter definitions. Evaluated at send-time against
--    customers + leads. segment_type controls which table to query.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS marketing_segments (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL,
  description   TEXT,
  segment_type  TEXT        NOT NULL DEFAULT 'customers'
                            CHECK (segment_type IN ('customers','leads','newsletter','all')),

  -- Filter criteria stored as JSONB — evaluated server-side
  -- e.g. {"customer_type":"b2c","vip":true,"language":"ar","min_bookings":2}
  filters       JSONB       NOT NULL DEFAULT '{}',

  -- Snapshot: last computed member count
  member_count  INT         DEFAULT 0,
  last_computed TIMESTAMPTZ,

  is_active     BOOLEAN     DEFAULT TRUE,
  created_by    UUID        REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE marketing_segments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "seg_all" ON marketing_segments FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_seg_type   ON marketing_segments(segment_type);
CREATE INDEX IF NOT EXISTS idx_seg_active ON marketing_segments(is_active) WHERE is_active = TRUE;


-- ─────────────────────────────────────────────────────────────
-- 2. MARKETING CAMPAIGNS
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS marketing_campaigns (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_number TEXT        UNIQUE,          -- AUTO: CMP-YYYY-NNNN
  name            TEXT        NOT NULL,
  description     TEXT,
  campaign_type   TEXT        NOT NULL DEFAULT 'email'
                              CHECK (campaign_type IN ('email','whatsapp','in_app','sms')),
  campaign_goal   TEXT        DEFAULT 'engagement'
                              CHECK (campaign_goal IN (
                                'engagement','lead_nurture','re_engagement',
                                'upsell','seasonal','destination','announcement'
                              )),

  -- Target
  segment_id      UUID        REFERENCES marketing_segments(id) ON DELETE SET NULL,
  target_count    INT         DEFAULT 0,       -- computed at send

  -- Content
  subject         TEXT,                        -- email subject / WhatsApp intro
  body_html       TEXT,                        -- email HTML body
  body_text       TEXT,                        -- plain text / WhatsApp body
  preview_text    TEXT,                        -- email preview snippet

  -- Schedule
  status          TEXT        NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','scheduled','sending','sent','cancelled','failed')),
  scheduled_at    TIMESTAMPTZ,
  sent_at         TIMESTAMPTZ,

  -- Stats (updated after send)
  sent_count      INT         DEFAULT 0,
  delivered_count INT         DEFAULT 0,
  opened_count    INT         DEFAULT 0,
  clicked_count   INT         DEFAULT 0,
  bounced_count   INT         DEFAULT 0,
  unsubscribed    INT         DEFAULT 0,

  -- Tracking
  utm_source      TEXT        DEFAULT 'flow_crm',
  utm_medium      TEXT,
  utm_campaign    TEXT,

  created_by      UUID        REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE marketing_campaigns ENABLE ROW LEVEL SECURITY;
CREATE POLICY "camp_all" ON marketing_campaigns FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_camp_status ON marketing_campaigns(status);
CREATE INDEX IF NOT EXISTS idx_camp_sched  ON marketing_campaigns(scheduled_at) WHERE scheduled_at IS NOT NULL;

-- Auto-number
CREATE SEQUENCE IF NOT EXISTS campaign_seq START 1;
CREATE OR REPLACE FUNCTION generate_campaign_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.campaign_number IS NULL THEN
    NEW.campaign_number := 'CMP-' || to_char(now(),'YYYY') || '-'
                        || lpad(nextval('campaign_seq')::text, 4, '0');
  END IF;
  RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS trg_camp_number ON marketing_campaigns;
CREATE TRIGGER trg_camp_number
  BEFORE INSERT ON marketing_campaigns
  FOR EACH ROW EXECUTE FUNCTION generate_campaign_number();


-- ─────────────────────────────────────────────────────────────
-- 3. CAMPAIGN MEMBERS
--    One row per recipient per campaign. Tracks delivery status.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS campaign_members (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   UUID        NOT NULL REFERENCES marketing_campaigns(id) ON DELETE CASCADE,

  -- Recipient (one of these must be set)
  customer_id   UUID        REFERENCES customers(id)              ON DELETE SET NULL,
  lead_id       UUID        REFERENCES leads(id)                  ON DELETE SET NULL,
  subscriber_id UUID        REFERENCES newsletter_subscribers(id) ON DELETE SET NULL,

  -- Denormalized for reliability (snapshot at send time)
  email         TEXT,
  phone         TEXT,
  name          TEXT,

  -- Delivery
  status        TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','sent','delivered','opened','clicked','bounced','unsubscribed','failed')),
  sent_at       TIMESTAMPTZ,
  opened_at     TIMESTAMPTZ,
  clicked_at    TIMESTAMPTZ,
  error_msg     TEXT,

  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE campaign_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cm_all" ON campaign_members FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_cm_campaign ON campaign_members(campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_cm_customer ON campaign_members(customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cm_lead     ON campaign_members(lead_id)     WHERE lead_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────
-- 4. AUTOMATION RULES
--    Trigger → Condition → Action engine.
--    Evaluated by a scheduled job or on relevant DB events.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS automation_rules (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL,
  description   TEXT,
  is_active     BOOLEAN     DEFAULT TRUE,

  -- Trigger
  trigger_event TEXT        NOT NULL
                            CHECK (trigger_event IN (
                              'quote_sent',           -- quotation status → sent
                              'quote_viewed',         -- future: tracking pixel
                              'quote_no_response',    -- N hours after sent, no action
                              'quote_accepted',
                              'quote_rejected',
                              'lead_created',
                              'lead_no_contact',      -- N hours after new, uncontacted
                              'booking_abandoned',    -- page_events funnel dropped
                              'booking_confirmed',
                              'booking_completed',
                              'payment_overdue',
                              'trip_upcoming',        -- N days before travel_date
                              'post_trip',            -- N days after completed
                              'customer_dormant'      -- no activity for N days
                            )),
  trigger_delay_hours INT   DEFAULT 0,   -- delay after event fires
  trigger_config  JSONB     DEFAULT '{}', -- e.g. {"days_before":3} for trip_upcoming

  -- Condition (optional extra filter)
  condition_type  TEXT      DEFAULT 'none'
                            CHECK (condition_type IN ('none','segment','field_match','custom')),
  condition_config JSONB    DEFAULT '{}',

  -- Action
  action_type    TEXT        NOT NULL
                            CHECK (action_type IN (
                              'send_email',       -- via send-communication edge fn
                              'send_whatsapp',
                              'create_task',      -- create a task for sales agent
                              'update_lead_status',
                              'add_to_campaign',
                              'tag_customer',
                              'notify_admin'
                            )),
  action_config  JSONB       NOT NULL DEFAULT '{}',
  -- e.g. for send_email: {"subject":"متابعة عرض أسعارك","template":"quote_followup"}
  -- e.g. for create_task: {"title":"متابعة العميل","priority":"high","assign_to":"lead_owner"}

  -- Limits
  max_executions_per_entity INT DEFAULT 1, -- prevent spam
  cooldown_hours            INT DEFAULT 24,

  created_by    UUID        REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE automation_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auto_rules_all" ON automation_rules FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_auto_trigger ON automation_rules(trigger_event) WHERE is_active = TRUE;


-- ─────────────────────────────────────────────────────────────
-- 5. AUTOMATION EXECUTIONS
--    Audit log of every rule execution. Enforces cooldown/limits.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS automation_executions (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id       UUID        NOT NULL REFERENCES automation_rules(id) ON DELETE CASCADE,

  -- What triggered this
  entity_type   TEXT        NOT NULL, -- 'lead','quotation','booking','customer'
  entity_id     UUID        NOT NULL,

  -- Result
  status        TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','running','completed','failed','skipped')),
  action_taken  TEXT,        -- what action was executed
  result        JSONB,       -- response/error from action
  error_msg     TEXT,

  executed_at   TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE automation_executions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auto_exec_all" ON automation_executions FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

CREATE INDEX IF NOT EXISTS idx_ae_rule      ON automation_executions(rule_id, executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_entity    ON automation_executions(entity_type, entity_id, executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_ae_status    ON automation_executions(status);


-- ─────────────────────────────────────────────────────────────
-- 6. ABANDONED BOOKINGS
--    Tracks users who started but didn't complete the booking form.
--    Fed by page_events inserts from the public booking page.
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS abandoned_bookings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      TEXT        NOT NULL,
  user_id         UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  package_id      UUID        REFERENCES packages(id)   ON DELETE SET NULL,
  package_title   TEXT,

  -- Funnel step when abandoned (1=viewed, 2=started, 3=traveler_details, 4=payment)
  last_step       INT         NOT NULL DEFAULT 1,
  last_step_label TEXT,

  -- Captured contact (from partial form fill if available)
  customer_name   TEXT,
  customer_email  TEXT,
  customer_phone  TEXT,
  adults_count    INT,

  -- Recovery status
  recovery_status TEXT        NOT NULL DEFAULT 'new'
                              CHECK (recovery_status IN (
                                'new','reminder_sent','task_created','recovered','ignored'
                              )),
  recovered_booking_id UUID   REFERENCES bookings(id) ON DELETE SET NULL,
  notes           TEXT,

  abandoned_at    TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE abandoned_bookings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ab_all" ON abandoned_bookings FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
-- Allow public insert from booking page (same pattern as page_events)
CREATE POLICY "ab_public_insert" ON abandoned_bookings FOR INSERT WITH CHECK (TRUE);

CREATE INDEX IF NOT EXISTS idx_ab_status    ON abandoned_bookings(recovery_status);
CREATE INDEX IF NOT EXISTS idx_ab_session   ON abandoned_bookings(session_id);
CREATE INDEX IF NOT EXISTS idx_ab_package   ON abandoned_bookings(package_id);
CREATE INDEX IF NOT EXISTS idx_ab_abandoned ON abandoned_bookings(abandoned_at DESC);


-- ─────────────────────────────────────────────────────────────
-- 7. Extend page_events with metadata column
--    Allows richer funnel tracking without schema changes.
-- ─────────────────────────────────────────────────────────────

ALTER TABLE page_events
  ADD COLUMN IF NOT EXISTS metadata    JSONB,
  ADD COLUMN IF NOT EXISTS page_url    TEXT,
  ADD COLUMN IF NOT EXISTS device_type TEXT;


-- ─────────────────────────────────────────────────────────────
-- 8. Helper RPCs
-- ─────────────────────────────────────────────────────────────

-- get_marketing_summary: dashboard KPIs
CREATE OR REPLACE FUNCTION get_marketing_summary()
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error','unauthorized');
  END IF;
  RETURN json_build_object(
    'total_segments',       (SELECT COUNT(*) FROM marketing_segments WHERE is_active),
    'total_campaigns',      (SELECT COUNT(*) FROM marketing_campaigns),
    'sent_campaigns',       (SELECT COUNT(*) FROM marketing_campaigns WHERE status = 'sent'),
    'active_rules',         (SELECT COUNT(*) FROM automation_rules   WHERE is_active),
    'pending_abandoned',    (SELECT COUNT(*) FROM abandoned_bookings  WHERE recovery_status = 'new'),
    'newsletter_active',    (SELECT COUNT(*) FROM newsletter_subscribers WHERE is_active),
    'executions_today',     (SELECT COUNT(*) FROM automation_executions
                             WHERE executed_at >= date_trunc('day', now())
                               AND status = 'completed'),
    'campaign_total_sent',  (SELECT COALESCE(SUM(sent_count),0) FROM marketing_campaigns)
  );
END;$$;
GRANT EXECUTE ON FUNCTION get_marketing_summary() TO authenticated;


-- evaluate_segment: compute member count for a segment
-- Returns count + sample emails for preview
CREATE OR REPLACE FUNCTION evaluate_segment(p_segment_id UUID)
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_seg    marketing_segments%ROWTYPE;
  v_count  INT := 0;
  v_sample TEXT[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()) THEN
    RETURN json_build_object('error','unauthorized');
  END IF;

  SELECT * INTO v_seg FROM marketing_segments WHERE id = p_segment_id;
  IF NOT FOUND THEN RETURN json_build_object('error','not_found'); END IF;

  -- Count based on segment_type + filters
  IF v_seg.segment_type = 'customers' THEN
    SELECT COUNT(*), array_agg(email ORDER BY created_at DESC) FILTER (WHERE email IS NOT NULL)
    INTO v_count, v_sample
    FROM (
      SELECT email, created_at FROM customers
      WHERE is_active
        AND (v_seg.filters->>'customer_type' IS NULL
             OR customer_type = v_seg.filters->>'customer_type')
        AND (v_seg.filters->>'language' IS NULL
             OR language = v_seg.filters->>'language')
        AND (v_seg.filters->>'vip' IS NULL
             OR vip = (v_seg.filters->>'vip')::boolean)
      LIMIT 1000
    ) s;

  ELSIF v_seg.segment_type = 'leads' THEN
    SELECT COUNT(*)
    INTO v_count
    FROM leads
    WHERE (v_seg.filters->>'status' IS NULL
           OR status = v_seg.filters->>'status')
      AND (v_seg.filters->>'source' IS NULL
           OR source = v_seg.filters->>'source');

  ELSIF v_seg.segment_type = 'newsletter' THEN
    SELECT COUNT(*) INTO v_count
    FROM newsletter_subscribers WHERE is_active;

  ELSIF v_seg.segment_type = 'all' THEN
    SELECT COUNT(*) INTO v_count FROM customers WHERE is_active;

  END IF;

  -- Update snapshot
  UPDATE marketing_segments
  SET member_count  = v_count,
      last_computed = now()
  WHERE id = p_segment_id;

  RETURN json_build_object(
    'count',  v_count,
    'sample', v_sample
  );
END;$$;
GRANT EXECUTE ON FUNCTION evaluate_segment(UUID) TO authenticated;


-- check_automation_cooldown: prevents duplicate executions
CREATE OR REPLACE FUNCTION check_automation_cooldown(
  p_rule_id    UUID,
  p_entity_id  UUID
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_rule     automation_rules%ROWTYPE;
  v_exec_cnt INT;
BEGIN
  SELECT * INTO v_rule FROM automation_rules WHERE id = p_rule_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  SELECT COUNT(*) INTO v_exec_cnt
  FROM automation_executions
  WHERE rule_id   = p_rule_id
    AND entity_id = p_entity_id
    AND executed_at >= now() - (v_rule.cooldown_hours || ' hours')::INTERVAL;

  -- Allowed if: under max_executions and past cooldown
  RETURN v_exec_cnt < v_rule.max_executions_per_entity;
END;$$;
GRANT EXECUTE ON FUNCTION check_automation_cooldown(UUID,UUID) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 9. Seed default automation rules
-- ─────────────────────────────────────────────────────────────

INSERT INTO automation_rules (name, trigger_event, trigger_delay_hours, action_type, action_config, description, cooldown_hours)
VALUES
  (
    'متابعة عرض السعر — 24 ساعة',
    'quote_no_response', 24,
    'create_task',
    '{"title":"متابعة عرض السعر المرسل","priority":"high","assign_to":"lead_owner","notes":"مر 24 ساعة على إرسال العرض بدون رد من العميل"}',
    'إنشاء مهمة للمبيعات إذا لم يرد العميل على عرض السعر خلال 24 ساعة',
    24
  ),
  (
    'تذكير العميل المحتمل الجديد',
    'lead_no_contact', 4,
    'create_task',
    '{"title":"التواصل مع العميل المحتمل الجديد","priority":"urgent","assign_to":"assigned_to","notes":"عميل محتمل جديد لم يتم التواصل معه خلال 4 ساعات"}',
    'تنبيه المبيعات بعميل محتمل لم يتم التواصل معه خلال 4 ساعات من الإنشاء',
    8
  ),
  (
    'تذكير الحجز المهجور',
    'booking_abandoned', 2,
    'create_task',
    '{"title":"استعادة حجز مهجور","priority":"high","assign_to":"auto","notes":"عميل بدأ عملية الحجز ولم يكملها"}',
    'إنشاء مهمة لاستعادة عميل توقف في منتصف عملية الحجز',
    48
  ),
  (
    'تهنئة بتأكيد الحجز',
    'booking_confirmed', 0,
    'send_email',
    '{"subject":"تم تأكيد حجزك مع Flow Travel ✓","template":"booking_confirmed","channel":"email"}',
    'إرسال بريد إلكتروني تأكيد للعميل فور تأكيد الحجز',
    72
  ),
  (
    'تذكير قبل الرحلة بـ 3 أيام',
    'trip_upcoming', 0,
    'send_email',
    '{"subject":"رحلتك تبدأ خلال 3 أيام — تذكير مهم","template":"trip_reminder","channel":"email"}',
    'إرسال تذكير للمسافر قبل 3 أيام من موعد الرحلة',
    72
  ),
  (
    'طلب التقييم بعد الرحلة',
    'post_trip', 48,
    'send_email',
    '{"subject":"كيف كانت رحلتك؟ شاركنا تجربتك","template":"post_trip_review","channel":"email"}',
    'طلب تقييم من العميل بعد 48 ساعة من إتمام الرحلة',
    168
  ),
  (
    'تنشيط العملاء غير النشطين',
    'customer_dormant', 0,
    'add_to_campaign',
    '{"campaign_tag":"re_engagement","segment_tag":"dormant"}',
    'إضافة العملاء غير النشطين (لا نشاط +180 يوم) لحملة إعادة تفعيل',
    720
  )
ON CONFLICT DO NOTHING;

-- ══ END PHASE 14 MIGRATION ═══════════════════════════════════
-- Verify:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_name IN (
--     'marketing_segments','marketing_campaigns','campaign_members',
--     'automation_rules','automation_executions','abandoned_bookings'
--   );
--   → 6 rows
--
--   SELECT COUNT(*) FROM automation_rules;
--   → 7 rows (seeds)
