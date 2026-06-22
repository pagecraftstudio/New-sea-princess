-- ═══════════════════════════════════════════════════════════════
-- ADMIN ROLE TIERS MIGRATION — نظام أدوار متعدد المستويات
-- نفّذ هذا الملف كاملاً في Supabase SQL Editor مرة واحدة
-- ═══════════════════════════════════════════════════════════════

-- ── STEP 1: إضافة عمود role لجدول admin_users الموجود ──
ALTER TABLE admin_users
  ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'admin';

-- قيود الدور المسموح بها
ALTER TABLE admin_users
  DROP CONSTRAINT IF EXISTS admin_users_role_check;
ALTER TABLE admin_users
  ADD CONSTRAINT admin_users_role_check
  CHECK (role IN ('super_admin', 'admin', 'viewer'));

-- ── STEP 2: رفع الأدمن الحاليين إلى super_admin ──
-- (كل من هو في الجدول الآن هو super_admin بالفعل)
UPDATE admin_users SET role = 'super_admin';

-- ── STEP 3: دالة get_admin_role() ──
CREATE OR REPLACE FUNCTION public.get_admin_role()
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER SET search_path = public
STABLE
AS $$
  SELECT role FROM public.admin_users WHERE id = auth.uid();
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_role() TO authenticated, anon;

-- ── STEP 4: دوال مساعدة للتحقق من كل مستوى ──
CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid() AND role = 'super_admin'); $$;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO authenticated, anon;

CREATE OR REPLACE FUNCTION public.is_admin_or_above()
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid() AND role IN ('admin', 'super_admin')); $$;
GRANT EXECUTE ON FUNCTION public.is_admin_or_above() TO authenticated, anon;

-- ── STEP 5: تحديث RLS لتعكس الأدوار ──

-- packages: viewer يقرأ، admin+ يعدّل، super_admin يحذف
DROP POLICY IF EXISTS "Admin insert packages"  ON packages;
DROP POLICY IF EXISTS "Admin update packages"  ON packages;
DROP POLICY IF EXISTS "Admin delete packages"  ON packages;
DROP POLICY IF EXISTS "Admin select packages"  ON packages;

CREATE POLICY "Admin select packages"  ON packages FOR SELECT  USING (public.is_admin());
CREATE POLICY "Admin insert packages"  ON packages FOR INSERT  WITH CHECK (public.is_admin_or_above());
CREATE POLICY "Admin update packages"  ON packages FOR UPDATE  USING (public.is_admin_or_above());
CREATE POLICY "Admin delete packages"  ON packages FOR DELETE  USING (public.is_super_admin());

-- bookings: viewer يقرأ، admin+ يعدّل حالة، super_admin يحذف
DROP POLICY IF EXISTS "Admin insert bookings"  ON bookings;
DROP POLICY IF EXISTS "Admin update bookings"  ON bookings;
DROP POLICY IF EXISTS "Admin delete bookings"  ON bookings;
DROP POLICY IF EXISTS "Admin select bookings"  ON bookings;

CREATE POLICY "Admin select bookings"  ON bookings FOR SELECT  USING (public.is_admin());
CREATE POLICY "Admin insert bookings"  ON bookings FOR INSERT  WITH CHECK (public.is_admin_or_above());
CREATE POLICY "Admin update bookings"  ON bookings FOR UPDATE  USING (public.is_admin_or_above());
CREATE POLICY "Admin delete bookings"  ON bookings FOR DELETE  USING (public.is_super_admin());

-- reviews: viewer يقرأ، admin+ يعتمد/يلغي، super_admin يحذف
DROP POLICY IF EXISTS "Admin insert reviews"   ON reviews;
DROP POLICY IF EXISTS "Admin update reviews"   ON reviews;
DROP POLICY IF EXISTS "Admin delete reviews"   ON reviews;
DROP POLICY IF EXISTS "Admin select reviews"   ON reviews;

CREATE POLICY "Admin select reviews"   ON reviews FOR SELECT  USING (public.is_admin());
CREATE POLICY "Admin insert reviews"   ON reviews FOR INSERT  WITH CHECK (public.is_admin_or_above());
CREATE POLICY "Admin update reviews"   ON reviews FOR UPDATE  USING (public.is_admin_or_above());
CREATE POLICY "Admin delete reviews"   ON reviews FOR DELETE  USING (public.is_super_admin());

-- admin_users: super_admin فقط يقرأ ويعدّل
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Super admin manages admins" ON admin_users;
DROP POLICY IF EXISTS "Super admin reads admins"   ON admin_users;
CREATE POLICY "Super admin reads admins"   ON admin_users FOR SELECT USING (public.is_super_admin());
CREATE POLICY "Super admin manages admins" ON admin_users FOR ALL   USING (public.is_super_admin());

-- ── STEP 6: منح super_admin الوصول لإدارة حسابات المستخدمين من profiles ──
DROP POLICY IF EXISTS "Super admin manages profiles" ON profiles;
CREATE POLICY "Super admin manages profiles" ON profiles FOR ALL USING (public.is_super_admin());

-- ── Done ──
-- الأدوار بعد التنفيذ:
--   super_admin : قراءة + تعديل + حذف + إدارة الأدمن + إيقاف المستخدمين
--   admin       : قراءة + تعديل حالة الحجز + اعتماد تقييمات + إضافة باقات
--   viewer      : قراءة فقط بدون أي تعديل
