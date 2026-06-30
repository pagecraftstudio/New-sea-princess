-- ═══════════════════════════════
-- TABLE 1: packages (Travel Packages)
-- ═══════════════════════════════
CREATE TABLE packages (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('اقتصادي', 'متميز', 'VIP', 'عائلي')),
  season TEXT,
  departure_date DATE NOT NULL,
  return_date DATE NOT NULL,
  duration_nights INTEGER NOT NULL,
  price_per_person DECIMAL(10,2) NOT NULL,
  price_child DECIMAL(10,2),
  max_seats INTEGER NOT NULL DEFAULT 40,
  available_seats INTEGER NOT NULL,
  departure_city TEXT NOT NULL,
  flight_type TEXT,
  airline TEXT,
  mecca_hotel TEXT NOT NULL,
  mecca_hotel_stars INTEGER CHECK (mecca_hotel_stars BETWEEN 3 AND 5),
  mecca_hotel_distance TEXT,
  medina_hotel TEXT NOT NULL,
  medina_hotel_stars INTEGER CHECK (medina_hotel_stars BETWEEN 3 AND 5),
  medina_hotel_distance TEXT,
  nights_mecca INTEGER NOT NULL,
  nights_medina INTEGER NOT NULL,
  transport_type TEXT,
  includes JSONB DEFAULT '[]',
  excludes JSONB DEFAULT '[]',
  itinerary JSONB DEFAULT '[]',
  images JSONB DEFAULT '[]',
  thumbnail_url TEXT,
  discount_percent INTEGER DEFAULT 0,
  coupon_code TEXT,
  is_featured BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  visa_included BOOLEAN DEFAULT true,
  notes TEXT,
  meta_description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════
-- TABLE 2: bookings (Customer Bookings)
-- ═══════════════════════════════
CREATE TABLE bookings (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  booking_number TEXT UNIQUE NOT NULL,
  package_id UUID REFERENCES packages(id) ON DELETE SET NULL,
  package_title TEXT NOT NULL,
  package_departure DATE NOT NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT NOT NULL,
  customer_email TEXT,
  customer_national_id TEXT,
  customer_passport_number TEXT,
  adults_count INTEGER NOT NULL DEFAULT 1 CHECK (adults_count >= 1),
  children_count INTEGER NOT NULL DEFAULT 0 CHECK (children_count >= 0),
  travelers JSONB DEFAULT '[]',
  total_price DECIMAL(10,2) NOT NULL,
  paid_amount DECIMAL(10,2) DEFAULT 0,
  remaining_amount DECIMAL(10,2),
  coupon_code TEXT,
  discount_amount DECIMAL(10,2) DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('awaiting_payment', 'pending', 'confirmed', 'visa_processing', 'tickets_issued', 'travelling', 'completed', 'cancelled')),
  status_details TEXT,
  visa_status TEXT DEFAULT 'not_started'
    CHECK (visa_status IN ('not_started', 'under_review', 'approved', 'rejected')),
  tickets_status TEXT DEFAULT 'not_issued'
    CHECK (tickets_status IN ('not_issued', 'issued', 'sent_to_customer')),
  documents JSONB DEFAULT '[]',
  special_requests TEXT,
  admin_notes TEXT,
  whatsapp_sent BOOLEAN DEFAULT false,
  booking_date TIMESTAMPTZ DEFAULT NOW(),
  confirmed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════
-- TABLE 3: reviews (Customer Reviews)
-- ═══════════════════════════════
CREATE TABLE reviews (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  customer_name TEXT NOT NULL,
  customer_city TEXT,
  customer_phone TEXT,                        -- for WhatsApp approval notification
  package_title TEXT,
  travel_year INTEGER,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review_text TEXT NOT NULL,
  media_urls JSONB DEFAULT '[]',
  is_featured BOOLEAN DEFAULT false,
  is_approved BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Migration (run if table already exists):
-- ALTER TABLE reviews ADD COLUMN IF NOT EXISTS customer_phone TEXT;

-- ═══════════════════════════════
-- TABLE: page_events (Funnel Analytics)
-- ═══════════════════════════════
CREATE TABLE page_events (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  event_type    TEXT NOT NULL,   -- 'page_view'|'package_view'|'booking_start'|'booking_step'|'booking_complete'|'booking_abandon'
  package_id    UUID REFERENCES packages(id) ON DELETE SET NULL,
  package_title TEXT,
  step_number   INT,             -- booking step (1,2,3) for booking_step / booking_abandon
  session_id    TEXT,            -- random UUID kept in sessionStorage
  user_id       UUID,            -- null for anonymous visitors
  referrer      TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE page_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anyone can insert events" ON page_events FOR INSERT WITH CHECK (true);
CREATE POLICY "admin can read events"    ON page_events FOR SELECT USING (auth.role() = 'authenticated');

-- Migration (run if table already exists):
-- (just run the full CREATE TABLE above; use IF NOT EXISTS to be safe)
-- CREATE TABLE IF NOT EXISTS page_events ( ... );

-- ═══════════════════════════════
-- TABLE 4: religious_guides (Umrah & Hajj Guides)
-- ═══════════════════════════════
CREATE TABLE religious_guides (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  title TEXT NOT NULL,
  category TEXT NOT NULL
    CHECK (category IN ('مناسك العمرة', 'مناسك الحج', 'المزارات', 'نصائح وتحضيرات', 'أدعية ومأثورات')),
  content TEXT NOT NULL,
  video_url TEXT,
  thumbnail_url TEXT,
  reading_time_minutes INTEGER,
  sort_order INTEGER DEFAULT 0,
  is_published BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════
-- TABLE 5: faqs (Frequently Asked Questions)
-- ═══════════════════════════════
CREATE TABLE faqs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  question TEXT NOT NULL,
  answer TEXT NOT NULL,
  category TEXT DEFAULT 'عام'
    CHECK (category IN ('عام', 'التأشيرة', 'الحجز والإلغاء', 'التطعيمات', 'الفنادق', 'الطيران')),
  sort_order INTEGER DEFAULT 0,
  is_published BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════
-- TABLE 6: newsletter_subscribers
-- ═══════════════════════════════
CREATE TABLE newsletter_subscribers (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  phone TEXT UNIQUE,
  email TEXT UNIQUE,
  name TEXT,
  is_active BOOLEAN DEFAULT true,
  subscribed_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════
-- TABLE 7: site_settings (Global Settings)
-- ═══════════════════════════════
CREATE TABLE site_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT
);

INSERT INTO site_settings (key, value, description) VALUES
('whatsapp_primary', '201555154996', 'رقم واتساب الحجز الرئيسي'),
('whatsapp_support', '201031777295', 'رقم واتساب الدعم'),
('phone_1', '01555154996', 'رقم هاتف 1'),
('phone_2', '01031777295', 'رقم هاتف 2'),
('phone_3', '01093475254', 'رقم هاتف 3'),
('company_name', 'نيو سي برنسيس فرع الزقازيق فرع الزقازيق فرع الزقازيق', 'اسم الشركة'),
('director_name', 'د. شيماء السعداوي', 'مدير الشركة'),
('license_type', 'شركة سياحة (أ)', 'نوع الترخيص'),
('license_number', '926', 'رقم ترخيص وزارة السياحة'),
('facebook_url', 'https://www.facebook.com/mohamed.ghanam.526', 'رابط فيسبوك'),
('hero_title', 'رحلتك المقدسة تبدأ من هنا', 'عنوان الهيرو'),
('hero_subtitle', 'برامج عمرة وحج متكاملة بأعلى مستوى من الخدمة', 'وصف الهيرو');

-- ═══════════════════════════════
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ═══════════════════════════════
ALTER TABLE packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE religious_guides ENABLE ROW LEVEL SECURITY;
ALTER TABLE faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE newsletter_subscribers ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read active packages" ON packages FOR SELECT USING (is_active = true);
CREATE POLICY "Public read approved reviews" ON reviews FOR SELECT USING (is_approved = true);
CREATE POLICY "Public read guides" ON religious_guides FOR SELECT USING (is_published = true);
CREATE POLICY "Public read faqs" ON faqs FOR SELECT USING (is_published = true);
CREATE POLICY "Public read settings" ON site_settings FOR SELECT USING (true);
CREATE POLICY "Public insert bookings" ON bookings FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Public read own booking" ON bookings;
CREATE POLICY "Public read own booking" ON bookings FOR SELECT USING (
  user_id = auth.uid()
  OR public.is_admin()
);
CREATE POLICY "Public insert newsletter" ON newsletter_subscribers FOR INSERT WITH CHECK (true);
CREATE POLICY "Public insert reviews" ON reviews FOR INSERT WITH CHECK (true);

CREATE POLICY "Admin insert packages" ON packages FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update packages" ON packages FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete packages" ON packages FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert bookings" ON bookings FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update bookings" ON bookings FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete bookings" ON bookings FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert reviews" ON reviews FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update reviews" ON reviews FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete reviews" ON reviews FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert guides" ON religious_guides FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update guides" ON religious_guides FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete guides" ON religious_guides FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert faqs" ON faqs FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update faqs" ON faqs FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete faqs" ON faqs FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert settings" ON site_settings FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update settings" ON site_settings FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete settings" ON site_settings FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin insert newsletter" ON newsletter_subscribers FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Admin update newsletter" ON newsletter_subscribers FOR UPDATE USING (auth.role() = 'authenticated');
CREATE POLICY "Admin delete newsletter" ON newsletter_subscribers FOR DELETE USING (auth.role() = 'authenticated');

CREATE POLICY "Admin select packages" ON packages FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select bookings" ON bookings FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select reviews" ON reviews FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select guides" ON religious_guides FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select faqs" ON faqs FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select settings" ON site_settings FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Admin select newsletter" ON newsletter_subscribers FOR SELECT USING (auth.role() = 'authenticated');

-- ═══════════════════════════════
-- TRIGGERS & FUNCTIONS
-- ═══════════════════════════════
CREATE OR REPLACE FUNCTION update_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER packages_updated_at BEFORE UPDATE ON packages FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER bookings_updated_at BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE SEQUENCE booking_seq START 1;

CREATE OR REPLACE FUNCTION generate_booking_number() RETURNS TRIGGER AS $$
BEGIN
  NEW.booking_number = 'NSP-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD(nextval('booking_seq')::TEXT, 5, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_booking_number BEFORE INSERT ON bookings FOR EACH ROW EXECUTE FUNCTION generate_booking_number();

-- ═══════════════════════════════
-- SAMPLE DATA
-- ═══════════════════════════════
INSERT INTO packages (title, category, departure_date, return_date, duration_nights, price_per_person, available_seats, departure_city, mecca_hotel, mecca_hotel_stars, medina_hotel, medina_hotel_stars, nights_mecca, nights_medina, season, is_featured) VALUES
('برنامج العمرة الاقتصادي — رجب 2026', 'اقتصادي', '2026-01-15', '2026-01-22', 7, 8500, 40, 'القاهرة', 'فندق البركة', 3, 'فندق المدينة الاقتصادي', 3, 4, 3, 'رجب', false),
('برنامج VIP الفاخر — رمضان 2026', 'VIP', '2026-03-01', '2026-03-15', 14, 25000, 20, 'القاهرة', 'فندق كونكورد', 5, 'فندق أنوار المدينة', 5, 8, 6, 'رمضان', true),
('برنامج العمرة المتميز — شعبان 2026', 'متميز', '2026-02-10', '2026-02-21', 11, 14000, 30, 'الإسكندرية', 'فندق الحرم المميز', 4, 'فندق روف المدينة', 4, 6, 5, 'شعبان', true),
('البرنامج العائلي المتكامل — إجازة الصيف 2026', 'عائلي', '2026-07-01', '2026-07-14', 14, 12000, 40, 'القاهرة', 'فندق الأسرة بمكة', 4, 'فندق طيبة', 4, 8, 6, 'طوال العام', true);

INSERT INTO reviews (customer_name, customer_city, package_title, travel_year, rating, review_text, is_approved, is_featured) VALUES
('أحمد محمود', 'القاهرة', 'برنامج VIP الفاخر', 2025, 5, 'برنامج فاخر جداً والخدمة فوق الممتازة، شكراً د. شيماء', true, true),
('سعاد إبراهيم', 'الإسكندرية', 'برنامج العمرة الاقتصادي', 2025, 4, 'سعر مناسب وخدمة محترمة، أنصح بالتعامل مع نيو سي برنسيس فرع الزقازيق فرع الزقازيق', true, true),
('مصطفى السيد', 'المنصورة', 'البرنامج العائلي', 2024, 5, 'أفضل تنظيم لرحلة عمرة عائلية، المندوبين كانوا في قمة التعاون', true, true);

INSERT INTO faqs (question, answer, category, is_published) VALUES
('ما هي الأوراق المطلوبة لاستخراج تأشيرة العمرة؟', 'جواز سفر صالح لمدة 6 أشهر على الأقل، صورتين شخصيتين بخلفية بيضاء، وشهادة التطعيم.', 'التأشيرة', true),
('هل يمكن إلغاء الحجز واسترداد المبلغ؟', 'نعم، يمكن الإلغاء قبل السفر بـ 15 يوماً مع استرداد المبلغ مخصوماً منه رسوم إدارية.', 'الحجز والإلغاء', true),
('هل توفرون وسيلة نقل من المطار للفندق؟', 'جميع برامجنا تشمل النقل في باصات حديثة ومكيفة من المطارات إلى الفنادق.', 'الطيران', true);

INSERT INTO religious_guides (title, category, content, is_published) VALUES
('خطوات الإحرام للعمرة', 'مناسك العمرة', '<p>تبدأ العمرة بالإحرام من الميقات، والاغتسال والتطيب ولبس ملابس الإحرام ثم التلبية.</p>', true),
('كيفية الطواف حول الكعبة', 'مناسك العمرة', '<p>الطواف يبدأ من الحجر الأسود ويكون 7 أشواط، مع الدعاء والذكر.</p>', true),
('أدعية مستحبة في السعي', 'أدعية ومأثورات', '<p>من المستحب الدعاء على الصفا والمروة بما تيسر من الدعاء المأثور.</p>', true);

-- ═══════════════════════════════
-- STORAGE
-- ═══════════════════════════════
INSERT INTO storage.buckets (id, name, public) VALUES ('booking-documents', 'booking-documents', false);
CREATE POLICY "Authenticated users can upload" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'booking-documents');
CREATE POLICY "Admin can read documents" ON storage.objects FOR SELECT USING (bucket_id = 'booking-documents');