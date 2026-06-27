-- ═══════════════════════════════════════════════════════
-- AUDIT LOG — سجل عمليات الإدارة
-- نفّذ هذا الكود في Supabase SQL Editor مرة واحدة فقط
-- ═══════════════════════════════════════════════════════

CREATE TABLE audit_logs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at    TIMESTAMPTZ DEFAULT now(),
  admin_email   TEXT NOT NULL,           -- بريد الأدمن اللي نفّذ العملية
  admin_id      UUID,                    -- auth.users.id (لو متاح)
  action        TEXT NOT NULL,           -- 'create' | 'update' | 'delete'
  table_name    TEXT NOT NULL,           -- 'packages' | 'bookings' | 'reviews' | 'newsletter_subscribers'
  record_id     TEXT,                    -- id السجل المتأثر
  record_label  TEXT,                    -- وصف مختصر يسهل القراءة (مثال: اسم البرنامج أو رقم الحجز)
  details       JSONB                    -- تفاصيل إضافية اختيارية (مثال: الحالة القديمة/الجديدة)
);

-- فهرس لتحسين سرعة الترتيب بالأحدث
CREATE INDEX idx_audit_logs_created_at ON audit_logs (created_at DESC);
CREATE INDEX idx_audit_logs_table_name ON audit_logs (table_name);

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- فقط الأدمن المسجل دخوله يقدر يضيف أو يقرأ سجلات اللوج
CREATE POLICY "Admin insert audit logs" ON audit_logs
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Admin read audit logs" ON audit_logs
  FOR SELECT USING (auth.role() = 'authenticated');

-- لا يوجد سياسة UPDATE أو DELETE عمداً — اللوج لا يُعدَّل ولا يُحذف أبداً (سجل ثابت للمراجعة)
