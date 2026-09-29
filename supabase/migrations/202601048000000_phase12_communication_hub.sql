-- =============================================================================
-- MIGRATION: 202601048000000_phase12_communication_hub.sql
-- Phase 12 — Traveler Communication Hub
-- Additive only. Builds on existing trip_communications table.
-- =============================================================================

-- ── 1. COMMUNICATION TEMPLATES ────────────────────────────────────────────────
-- Reusable message templates per trigger event and channel
CREATE TABLE IF NOT EXISTS communication_templates (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT        NOT NULL,
  trigger_event TEXT        NOT NULL
                            CHECK (trigger_event IN (
                              'booking_confirmed','payment_received','payment_reminder',
                              'document_missing','document_approved',
                              'hotel_confirmed','driver_assigned','guide_assigned',
                              'pickup_reminder','trip_starts_tomorrow',
                              'daily_itinerary','trip_completed',
                              'review_request','emergency_notice','custom'
                            )),
  channel       TEXT        NOT NULL
                            CHECK (channel IN ('email','whatsapp','sms','in_app')),
  subject       TEXT,                         -- email subject
  body_ar       TEXT        NOT NULL,          -- Arabic template body
  body_en       TEXT,                          -- English version (optional)
  -- Template variables: {{customer_name}}, {{booking_number}},
  -- {{destination}}, {{travel_date}}, {{hotel_name}}, {{driver_name}},
  -- {{driver_phone}}, {{guide_name}}, {{pickup_time}}, {{balance}}
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  is_default    BOOLEAN     NOT NULL DEFAULT FALSE, -- one default per trigger+channel
  created_by    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ct_trigger  ON communication_templates(trigger_event, channel);
CREATE INDEX IF NOT EXISTS idx_ct_active   ON communication_templates(is_active);

ALTER TABLE communication_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ct_read"   ON communication_templates FOR SELECT USING (is_any_admin());
CREATE POLICY "ct_write"  ON communication_templates FOR ALL   USING (is_any_admin());

DROP TRIGGER IF EXISTS trg_ct_updated_at ON communication_templates;
CREATE TRIGGER trg_ct_updated_at
  BEFORE UPDATE ON communication_templates
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ── 2. COMMUNICATION QUEUE ────────────────────────────────────────────────────
-- Scheduled / pending outbound messages (manual or automated)
CREATE TABLE IF NOT EXISTS communication_queue (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_file_id    UUID        REFERENCES trip_files(id) ON DELETE SET NULL,
  booking_id      UUID        REFERENCES bookings(id)   ON DELETE SET NULL,
  template_id     UUID        REFERENCES communication_templates(id) ON DELETE SET NULL,

  channel         TEXT        NOT NULL
                              CHECK (channel IN ('email','whatsapp','sms','in_app')),
  recipient_type  TEXT        NOT NULL DEFAULT 'customer'
                              CHECK (recipient_type IN ('customer','supplier','partner','b2b_partner')),
  recipient_name  TEXT,
  recipient_email TEXT,
  recipient_phone TEXT,

  subject         TEXT,
  body            TEXT        NOT NULL,         -- rendered body (vars already substituted)
  trigger_event   TEXT,
  is_automated    BOOLEAN     NOT NULL DEFAULT FALSE,

  status          TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending','sent','failed','cancelled','skipped')),
  scheduled_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at         TIMESTAMPTZ,
  error_msg       TEXT,
  retry_count     INT         NOT NULL DEFAULT 0,
  external_id     TEXT,                         -- Resend message ID or WhatsApp msg ID

  created_by      UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cq_status       ON communication_queue(status, scheduled_at);
CREATE INDEX IF NOT EXISTS idx_cq_trip_file    ON communication_queue(trip_file_id);
CREATE INDEX IF NOT EXISTS idx_cq_booking      ON communication_queue(booking_id);

ALTER TABLE communication_queue ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cq_admin" ON communication_queue FOR ALL USING (is_any_admin());

-- ── 3. EXTEND trip_communications with send_status ────────────────────────────
-- track if a log entry was auto-generated from the queue
ALTER TABLE trip_communications
  ADD COLUMN IF NOT EXISTS queue_id     UUID REFERENCES communication_queue(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS template_id  UUID REFERENCES communication_templates(id) ON DELETE SET NULL;

-- ── 4. SEED DEFAULT TEMPLATES ─────────────────────────────────────────────────
INSERT INTO communication_templates
  (name, trigger_event, channel, subject, body_ar, is_default)
VALUES

-- Booking confirmed - email
('تأكيد الحجز - بريد إلكتروني', 'booking_confirmed', 'email',
 'تأكيد حجزك رقم {{booking_number}} — Flow Travel',
 'عزيزنا {{customer_name}}،

يسعدنا إخبارك بأن حجزك قد تم تأكيده بنجاح! 🎉

📋 رقم الحجز: {{booking_number}}
🌍 الوجهة: {{destination}}
📅 تاريخ السفر: {{travel_date}}
👥 عدد المسافرين: {{pax_count}}

سيتواصل معك فريقنا قريباً لمتابعة تفاصيل رحلتك.

شكراً لثقتكم بـ Flow Travel 🙏',
 TRUE),

-- Booking confirmed - whatsapp
('تأكيد الحجز - واتساب', 'booking_confirmed', 'whatsapp', NULL,
 '✅ *تأكيد الحجز*

عزيزنا {{customer_name}}، تم تأكيد حجزك بنجاح!

📋 رقم الحجز: *{{booking_number}}*
🌍 الوجهة: {{destination}}
📅 تاريخ السفر: {{travel_date}}

سيتواصل معك فريق Flow Travel قريباً. شكراً لك! 🙏',
 TRUE),

-- Payment received - email
('تأكيد الدفع - بريد إلكتروني', 'payment_received', 'email',
 'تم استلام دفعتك — الحجز {{booking_number}}',
 'عزيزنا {{customer_name}}،

تم استلام دفعتك بنجاح.

💰 المبلغ المدفوع: {{amount_paid}}
💳 الرصيد المتبقي: {{balance}}
📋 رقم الحجز: {{booking_number}}

شكراً لك!
Flow Travel',
 TRUE),

-- Payment reminder - email
('تذكير بالدفع - بريد إلكتروني', 'payment_reminder', 'email',
 'تذكير: رصيد مستحق على الحجز {{booking_number}}',
 'عزيزنا {{customer_name}}،

نودّ تذكيركم بأن هناك رصيداً مستحقاً على حجزكم.

💳 الرصيد المتبقي: {{balance}}
📋 رقم الحجز: {{booking_number}}
📅 تاريخ السفر: {{travel_date}}

يرجى التواصل معنا لتسوية المبلغ في أقرب وقت.

Flow Travel',
 TRUE),

-- Driver assigned - whatsapp
('تعيين السائق - واتساب', 'driver_assigned', 'whatsapp', NULL,
 '🚗 *معلومات السائق الخاص بكم*

عزيزنا {{customer_name}}،

يسعدنا إخبارك بتفاصيل سائقكم:

👨 الاسم: *{{driver_name}}*
📞 الهاتف: *{{driver_phone}}*
🚙 نوع السيارة: {{vehicle_type}}
📍 موعد الاستلام: {{pickup_time}}
📍 مكان الاستلام: {{pickup_location}}

في حالة أي استفسار، تواصل معنا. ✨',
 TRUE),

-- Pickup reminder - whatsapp
('تذكير الاستلام - واتساب', 'pickup_reminder', 'whatsapp', NULL,
 '⏰ *تذكير: رحلتكم غداً!*

عزيزنا {{customer_name}}،

نذكّركم بأن رحلتكم ستبدأ *غداً* 🎉

🕐 موعد الاستلام: *{{pickup_time}}*
📍 مكان الاستلام: {{pickup_location}}
👨 السائق: {{driver_name}} — {{driver_phone}}

نتمنى لكم رحلة ممتعة! 🌟
Flow Travel',
 TRUE),

-- Trip starts tomorrow - email
('بداية الرحلة غداً - بريد إلكتروني', 'trip_starts_tomorrow', 'email',
 'رحلتكم تبدأ غداً! — {{destination}}',
 'عزيزنا {{customer_name}}،

استعدوا! رحلتكم إلى {{destination}} تبدأ *غداً* 🎊

📋 رقم الحجز: {{booking_number}}
🕐 موعد الاستلام: {{pickup_time}}
📍 مكان الاستلام: {{pickup_location}}
👨 السائق: {{driver_name}} | {{driver_phone}}

نتمنى لكم تجربة لا تُنسى!
فريق Flow Travel 💚',
 TRUE),

-- Trip completed - review request - email
('طلب تقييم بعد الرحلة - بريد إلكتروني', 'review_request', 'email',
 'كيف كانت تجربتكم؟ — {{destination}}',
 'عزيزنا {{customer_name}}،

نأمل أنكم استمتعتم برحلتكم إلى {{destination}} 🌟

رأيكم يهمنا كثيراً! يسعدنا لو شاركتمونا تقييمكم لتجربتكم.

شكراً لاختياركم Flow Travel 💚',
 TRUE),

-- Document missing - whatsapp
('وثيقة مفقودة - واتساب', 'document_missing', 'whatsapp', NULL,
 '📋 *وثيقة مطلوبة*

عزيزنا {{customer_name}}،

لاحظنا أن ملف حجزكم *{{booking_number}}* ينقصه بعض الوثائق المطلوبة.

يرجى التواصل معنا في أقرب وقت ممكن لاستكمال ملفكم.

Flow Travel 📞',
 TRUE),

-- Emergency notice - whatsapp
('إشعار طارئ - واتساب', 'emergency_notice', 'whatsapp', NULL,
 '🚨 *إشعار مهم*

عزيزنا {{customer_name}}،

{{message}}

للتواصل الفوري: {{emergency_contact}}

Flow Travel',
 TRUE)

ON CONFLICT DO NOTHING;

-- ── 5. RPC — render template with data ───────────────────────────────────────
CREATE OR REPLACE FUNCTION render_template(
  p_template_id UUID,
  p_vars        JSONB
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_body TEXT;
  v_key  TEXT;
  v_val  TEXT;
BEGIN
  SELECT body_ar INTO v_body
  FROM communication_templates
  WHERE id = p_template_id AND is_active = TRUE;

  IF v_body IS NULL THEN RETURN NULL; END IF;

  -- Replace {{key}} placeholders with values from p_vars JSON
  FOR v_key, v_val IN
    SELECT key, value::TEXT FROM jsonb_each_text(p_vars)
  LOOP
    v_body := replace(v_body, '{{' || v_key || '}}', COALESCE(v_val, ''));
  END LOOP;

  RETURN v_body;
END;
$$;

GRANT EXECUTE ON FUNCTION render_template(UUID, JSONB) TO authenticated;

-- ── 6. RPC — communication stats ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_communication_stats()
RETURNS JSON
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'total_sent_today',   (SELECT count(*) FROM communication_queue WHERE status='sent' AND sent_at >= current_date),
    'pending',            (SELECT count(*) FROM communication_queue WHERE status='pending'),
    'failed',             (SELECT count(*) FROM communication_queue WHERE status='failed'),
    'total_this_month',   (SELECT count(*) FROM communication_queue WHERE status='sent' AND sent_at >= date_trunc('month', now())),
    'by_channel',         (SELECT json_object_agg(channel, cnt) FROM (
                              SELECT channel, count(*) AS cnt
                              FROM communication_queue WHERE status='sent' AND sent_at >= current_date
                              GROUP BY channel
                           ) x),
    'templates_active',   (SELECT count(*) FROM communication_templates WHERE is_active=TRUE)
  );
$$;

GRANT EXECUTE ON FUNCTION get_communication_stats() TO authenticated;

-- ── 7. RPC — get trip communications timeline ────────────────────────────────
CREATE OR REPLACE FUNCTION get_trip_communications(p_trip_file_id UUID)
RETURNS TABLE (
  id             UUID,
  channel        TEXT,
  direction      TEXT,
  recipient_type TEXT,
  recipient_name TEXT,
  subject        TEXT,
  summary        TEXT,
  sent_at        TIMESTAMPTZ,
  is_automated   BOOLEAN,
  status         TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Auth check
  IF NOT is_any_admin() THEN RAISE EXCEPTION 'Access denied'; END IF;

  RETURN QUERY
  SELECT
    tc.id, tc.channel, tc.direction, tc.recipient_type,
    tc.recipient_name, tc.subject, tc.summary, tc.sent_at,
    tc.is_automated,
    COALESCE(cq.status, 'sent') AS status
  FROM trip_communications tc
  LEFT JOIN communication_queue cq ON cq.id = tc.queue_id
  WHERE tc.trip_file_id = p_trip_file_id
  ORDER BY tc.sent_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_trip_communications(UUID) TO authenticated;

-- ── 8. NAV PERMISSION ─────────────────────────────────────────────────────────
INSERT INTO permission_matrix (permission, name_ar, category_ar, roles) VALUES
  ('manage_communications', 'إدارة التواصل مع المسافرين', 'العمليات',
    ARRAY['super_admin','admin','sales_agent','booking_agent'])
ON CONFLICT (permission) DO UPDATE SET roles = EXCLUDED.roles;

-- =============================================================================
-- Phase 12 Communication Hub — COMPLETE
-- Tables:  communication_templates, communication_queue
-- Extends: trip_communications (queue_id, template_id columns)
-- RPCs:    render_template, get_communication_stats, get_trip_communications
-- Seed:    10 default templates (booking, payment, driver, pickup, review...)
-- =============================================================================
