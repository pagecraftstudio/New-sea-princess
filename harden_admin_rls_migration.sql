-- ═══════════════════════════════════════════════════════
-- HARDEN ADMIN ACCESS — يحل مشكلة: أي عميل مسجل دخول له
-- نفس صلاحيات الأدمن في قاعدة البيانات.
-- نفّذ هذا الكود بالكامل في Supabase SQL Editor مرة واحدة.
-- ═══════════════════════════════════════════════════════

-- ───────────────────────────────────────────────
-- STEP 0 (مهم جداً، نفّذه أولاً واقرأ النتيجة):
-- شوف كل الحسابات الموجودة عندك في auth.users عشان تعرف
-- إيميل/إيميلات الأدمن الحقيقيين قبل ما تكمل.
-- ───────────────────────────────────────────────
-- SELECT id, email, created_at FROM auth.users ORDER BY created_at;

-- ═══════════════════════════════════════════════
-- STEP 1: جدول قائمة الأدمن المعتمدين (Allow-list)
-- جدول مقفول تماماً من أي وصول عن طريق الموقع —
-- التعديل عليه يتم فقط من Supabase SQL Editor مباشرة
-- ═══════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS admin_users (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
-- ملاحظة: مفيش أي CREATE POLICY هنا عمداً — يعني محدّش (مش عميل ولا حتى أدمن)
-- يقدر يقرأ أو يعدّل الجدول ده من المتصفح. الإدارة بتتم فقط من SQL Editor.

-- ───────────────────────────────────────────────
-- STEP 2: ضيف حساب/حسابات الأدمن هنا (غيّر الإيميل)
-- ───────────────────────────────────────────────
INSERT INTO admin_users (id, email)
SELECT id, email FROM auth.users WHERE email = 'PUT_YOUR_ADMIN_EMAIL_HERE@example.com'
ON CONFLICT (id) DO NOTHING;

-- لو عندك أكتر من حساب أدمن، كرر السطر فوق بإيميل مختلف كل مرة.

-- ═══════════════════════════════════════════════
-- STEP 3: دالة is_admin() — الفحص الحقيقي
-- ═══════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER SET search_path = public
STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid());
$$;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, anon;

-- ═══════════════════════════════════════════════
-- STEP 4: استبدال كل سياسات "auth.role() = 'authenticated'"
-- بفحص is_admin() الحقيقي — لكل جدول
-- ═══════════════════════════════════════════════

-- packages
DROP POLICY IF EXISTS "Admin insert packages" ON packages;
DROP POLICY IF EXISTS "Admin update packages" ON packages;
DROP POLICY IF EXISTS "Admin delete packages" ON packages;
DROP POLICY IF EXISTS "Admin select packages" ON packages;
CREATE POLICY "Admin insert packages" ON packages FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update packages" ON packages FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete packages" ON packages FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select packages" ON packages FOR SELECT USING (public.is_admin());

-- bookings
DROP POLICY IF EXISTS "Admin insert bookings" ON bookings;
DROP POLICY IF EXISTS "Admin update bookings" ON bookings;
DROP POLICY IF EXISTS "Admin delete bookings" ON bookings;
DROP POLICY IF EXISTS "Admin select bookings" ON bookings;
CREATE POLICY "Admin insert bookings" ON bookings FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update bookings" ON bookings FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete bookings" ON bookings FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select bookings" ON bookings FOR SELECT USING (public.is_admin());

-- reviews
DROP POLICY IF EXISTS "Admin insert reviews" ON reviews;
DROP POLICY IF EXISTS "Admin update reviews" ON reviews;
DROP POLICY IF EXISTS "Admin delete reviews" ON reviews;
DROP POLICY IF EXISTS "Admin select reviews" ON reviews;
CREATE POLICY "Admin insert reviews" ON reviews FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update reviews" ON reviews FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete reviews" ON reviews FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select reviews" ON reviews FOR SELECT USING (public.is_admin());

-- religious_guides
DROP POLICY IF EXISTS "Admin insert guides" ON religious_guides;
DROP POLICY IF EXISTS "Admin update guides" ON religious_guides;
DROP POLICY IF EXISTS "Admin delete guides" ON religious_guides;
DROP POLICY IF EXISTS "Admin select guides" ON religious_guides;
CREATE POLICY "Admin insert guides" ON religious_guides FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update guides" ON religious_guides FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete guides" ON religious_guides FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select guides" ON religious_guides FOR SELECT USING (public.is_admin());

-- faqs
DROP POLICY IF EXISTS "Admin insert faqs" ON faqs;
DROP POLICY IF EXISTS "Admin update faqs" ON faqs;
DROP POLICY IF EXISTS "Admin delete faqs" ON faqs;
DROP POLICY IF EXISTS "Admin select faqs" ON faqs;
CREATE POLICY "Admin insert faqs" ON faqs FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update faqs" ON faqs FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete faqs" ON faqs FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select faqs" ON faqs FOR SELECT USING (public.is_admin());

-- site_settings
DROP POLICY IF EXISTS "Admin insert settings" ON site_settings;
DROP POLICY IF EXISTS "Admin update settings" ON site_settings;
DROP POLICY IF EXISTS "Admin delete settings" ON site_settings;
DROP POLICY IF EXISTS "Admin select settings" ON site_settings;
CREATE POLICY "Admin insert settings" ON site_settings FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update settings" ON site_settings FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete settings" ON site_settings FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select settings" ON site_settings FOR SELECT USING (public.is_admin());

-- newsletter_subscribers
DROP POLICY IF EXISTS "Admin insert newsletter" ON newsletter_subscribers;
DROP POLICY IF EXISTS "Admin update newsletter" ON newsletter_subscribers;
DROP POLICY IF EXISTS "Admin delete newsletter" ON newsletter_subscribers;
DROP POLICY IF EXISTS "Admin select newsletter" ON newsletter_subscribers;
CREATE POLICY "Admin insert newsletter" ON newsletter_subscribers FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin update newsletter" ON newsletter_subscribers FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admin delete newsletter" ON newsletter_subscribers FOR DELETE USING (public.is_admin());
CREATE POLICY "Admin select newsletter" ON newsletter_subscribers FOR SELECT USING (public.is_admin());

-- audit_logs (لا يُعدَّل ولا يُحذف عمداً — هنا بس insert/select)
DROP POLICY IF EXISTS "Admin insert audit logs" ON audit_logs;
DROP POLICY IF EXISTS "Admin read audit logs" ON audit_logs;
CREATE POLICY "Admin insert audit logs" ON audit_logs FOR INSERT WITH CHECK (public.is_admin());
CREATE POLICY "Admin read audit logs" ON audit_logs FOR SELECT USING (public.is_admin());

-- profiles (بيانات العملاء المسجلين — أهم جدول هنا لأنه بيانات شخصية)
DROP POLICY IF EXISTS "Admin select all profiles" ON profiles;
DROP POLICY IF EXISTS "Admin update profiles" ON profiles;
CREATE POLICY "Admin select all profiles" ON profiles FOR SELECT USING (public.is_admin());
CREATE POLICY "Admin update profiles" ON profiles FOR UPDATE USING (public.is_admin());
-- ("Users can view own profile" تفضل زي ما هي — العميل لسه يقدر يشوف بياناته هو بس)

-- ═══════════════════════════════════════════════
-- STEP 5: حماية صور/مستندات جوازات السفر
-- السياسة القديمة كانت بتسمح لأي حد (حتى بدون تسجيل دخول)
-- يقرأ مستندات الحجز المرفوعة — دي كانت أخطر نقطة في المشروع كله
-- ═══════════════════════════════════════════════
DROP POLICY IF EXISTS "Admin can read documents" ON storage.objects;
CREATE POLICY "Admin can read documents" ON storage.objects
  FOR SELECT USING (bucket_id = 'booking-documents' AND public.is_admin());
-- سياسة الرفع "Authenticated users can upload" فضلت زي ما هي عمداً —
-- لازم تفضل عامة عشان نموذج الحجز للعملاء (غير المسجلين) يقدر يرفع جواز السفر.
