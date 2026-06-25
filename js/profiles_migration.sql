-- ═══════════════════════════════════════════════════════
-- PROFILES — سجل المستخدمين المسجّلين (العملاء)
-- نفّذ هذا الكود في Supabase SQL Editor مرة واحدة فقط
-- ═══════════════════════════════════════════════════════

-- ملاحظة هامة: auth.users جدول داخلي لا يمكن قراءته مباشرة من المتصفح
-- بمفتاح anon. هذا الجدول (profiles) نسخة عامة آمنة منه، تتحدّث تلقائياً
-- عند تسجيل أي عميل جديد عبر login.html.

CREATE TABLE profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           TEXT,
  full_name       TEXT,
  phone           TEXT,
  is_blocked      BOOLEAN DEFAULT false,
  sign_in_count   INTEGER DEFAULT 0,
  last_sign_in_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_profiles_created_at ON profiles (created_at DESC);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- العميل يقدر يشوف بياناته هو بس
CREATE POLICY "Users can view own profile" ON profiles
  FOR SELECT USING (auth.uid() = id);

-- الأدمن (أي مستخدم authenticated — نفس قاعدة باقي الجداول في المشروع)
-- يقدر يشوف ويعدّل كل البروفايلات (تفعيل/إيقاف الحساب)
CREATE POLICY "Admin select all profiles" ON profiles
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin update profiles" ON profiles
  FOR UPDATE USING (auth.role() = 'authenticated');

-- ─── إنشاء البروفايل تلقائياً عند تسجيل عميل جديد ───
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, phone)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'phone'
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ─── تسجيل وقت/عدد مرات الدخول عند كل تسجيل دخول ───
-- (دالة SECURITY DEFINER بدل ما نفتح صلاحية UPDATE عامة للعميل على جدول profiles؛
--  هي بتحدّث صف المستخدم الحالي بس، مفيش طريقة للعميل يعدّل أي حقل تاني زي is_blocked)
CREATE OR REPLACE FUNCTION public.track_user_login()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles
  SET sign_in_count   = COALESCE(sign_in_count, 0) + 1,
      last_sign_in_at = now()
  WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.track_user_login() TO authenticated;
