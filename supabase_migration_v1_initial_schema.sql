-- ══════════════════════════════════════════════════════════════
--  NSP Migration v1 — Initial Schema
--  Run FIRST in Supabase SQL Editor before all other migrations.
--  Creates: packages, bookings, reviews, profiles, admin_users,
--           audit_logs, page_events, newsletter_subscribers
-- ══════════════════════════════════════════════════════════════

-- ─── 1. PACKAGES ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS packages (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title                 TEXT NOT NULL,
  category              TEXT,
  season                TEXT,
  departure_date        DATE,
  return_date           DATE,
  duration_nights       INT DEFAULT 0,
  departure_city        TEXT,
  price_per_person      NUMERIC(12,2) NOT NULL DEFAULT 0,
  price_child           NUMERIC(12,2),
  price_infant          NUMERIC(12,2),
  max_seats             INT DEFAULT 40,
  available_seats       INT DEFAULT 40,
  discount_percent      INT DEFAULT 0,
  mecca_hotel           TEXT,
  mecca_hotel_stars     INT,
  nights_mecca          INT DEFAULT 0,
  mecca_hotel_distance  TEXT,
  medina_hotel          TEXT,
  medina_hotel_stars    INT,
  nights_medina         INT DEFAULT 0,
  medina_hotel_distance TEXT,
  flight_type           TEXT,
  airline               TEXT,
  flight_ticket_price   NUMERIC(10,2) DEFAULT 0,
  transport_type        TEXT,
  thumbnail_url         TEXT,
  includes              JSONB,
  excludes              JSONB,
  itinerary             JSONB,
  mecca_hotels          JSONB,
  madina_hotels         JSONB,
  notes                 TEXT,
  visa_included         BOOLEAN DEFAULT TRUE,
  is_featured           BOOLEAN DEFAULT FALSE,
  is_active             BOOLEAN DEFAULT TRUE,
  is_preorder           BOOLEAN DEFAULT FALSE,
  preorder_note         TEXT,
  doc_conditions        TEXT,
  documents_config      JSONB,
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_packages_category ON packages(category);
CREATE INDEX IF NOT EXISTS idx_packages_active ON packages(is_active);
ALTER TABLE packages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read" ON packages FOR SELECT USING (is_active = TRUE);
CREATE POLICY "admins_all" ON packages FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 2. BOOKINGS ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_number           TEXT UNIQUE,
  package_id               UUID REFERENCES packages(id),
  package_title            TEXT,
  package_departure        DATE,
  user_id                  UUID REFERENCES auth.users(id),
  customer_name            TEXT NOT NULL,
  customer_phone           TEXT,
  customer_email           TEXT,
  customer_national_id     TEXT,
  customer_passport_number TEXT,
  adults_count             INT DEFAULT 1,
  children_count           INT DEFAULT 0,
  infants_count            INT DEFAULT 0,
  travelers                JSONB,
  total_price              NUMERIC(12,2) NOT NULL DEFAULT 0,
  paid_amount              NUMERIC(12,2) DEFAULT 0,
  remaining_amount         NUMERIC(12,2) DEFAULT 0,
  coupon_code              TEXT,
  discount_amount          NUMERIC(12,2) DEFAULT 0,
  documents                JSONB,
  doc_warnings             JSONB,
  special_requests         TEXT,
  booking_type             TEXT DEFAULT 'standard',
  status                   TEXT DEFAULT 'pending' CHECK (status IN ('pending','confirmed','cancelled','completed')),
  status_details           TEXT,
  visa_status              TEXT,
  tickets_status           TEXT,
  dates_unknown            BOOLEAN DEFAULT FALSE,
  mecca_hotel              JSONB,
  madina_hotel             JSONB,
  mecca_rooms              JSONB,
  madina_rooms             JSONB,
  mecca_room_tier          TEXT,
  madina_room_tier         TEXT,
  flight_ticket_price      NUMERIC(10,2) DEFAULT 0,
  is_preorder              BOOLEAN DEFAULT FALSE,
  created_at               TIMESTAMPTZ DEFAULT now(),
  updated_at               TIMESTAMPTZ DEFAULT now()
);
-- Auto-generate booking_number: NSP-YYYY-NNNNN
CREATE SEQUENCE IF NOT EXISTS booking_seq START 1;
CREATE OR REPLACE FUNCTION set_booking_number()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.booking_number IS NULL OR NEW.booking_number = '' THEN
    NEW.booking_number := 'NSP-' || TO_CHAR(now(), 'YYYY') || '-' || LPAD(nextval('booking_seq')::TEXT, 5, '0');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_booking_number ON bookings;
CREATE TRIGGER trg_booking_number
  BEFORE INSERT ON bookings
  FOR EACH ROW EXECUTE FUNCTION set_booking_number();

CREATE INDEX IF NOT EXISTS idx_bookings_package ON bookings(package_id);
CREATE INDEX IF NOT EXISTS idx_bookings_user ON bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);
CREATE INDEX IF NOT EXISTS idx_bookings_number ON bookings(booking_number);
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON bookings FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "owner_read" ON bookings FOR SELECT
  USING (user_id = auth.uid());
CREATE POLICY "public_insert" ON bookings FOR INSERT WITH CHECK (TRUE);

-- ─── 3. PROFILES (mirrors auth.users) ────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT,
  full_name  TEXT,
  phone      TEXT,
  is_blocked BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON profiles FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "owner_read" ON profiles FOR SELECT
  USING (id = auth.uid());

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_new_user ON auth.users;
CREATE TRIGGER trg_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ─── 4. ADMIN USERS ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_users (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  role       TEXT DEFAULT 'admin' CHECK (role IN ('admin','super_admin')),
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_read" ON admin_users FOR SELECT
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));
CREATE POLICY "super_admin_all" ON admin_users FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid() AND role = 'super_admin'));

-- ─── 5. REVIEWS ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reviews (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name TEXT NOT NULL,
  customer_city TEXT,
  customer_phone TEXT,
  package_title TEXT,
  travel_year   INT,
  rating        INT CHECK (rating BETWEEN 1 AND 5),
  review_text   TEXT NOT NULL,
  is_approved   BOOLEAN DEFAULT FALSE,
  is_featured   BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read_approved" ON reviews FOR SELECT USING (is_approved = TRUE);
CREATE POLICY "public_insert" ON reviews FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "admins_all" ON reviews FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 6. AUDIT LOGS ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id     UUID REFERENCES auth.users(id),
  admin_email  TEXT,
  action       TEXT NOT NULL,
  table_name   TEXT,
  record_id    TEXT,
  record_label TEXT,
  details      JSONB,
  created_at   TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admins_all" ON audit_logs FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 7. PAGE EVENTS (analytics) ──────────────────────────────
CREATE TABLE IF NOT EXISTS page_events (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type   TEXT NOT NULL,
  session_id   TEXT,
  user_id      UUID REFERENCES auth.users(id),
  referrer     TEXT,
  package_id   UUID REFERENCES packages(id),
  package_title TEXT,
  step_number  INT,
  created_at   TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE page_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_insert" ON page_events FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "admins_all" ON page_events FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── 8. NEWSLETTER SUBSCRIBERS ───────────────────────────────
CREATE TABLE IF NOT EXISTS newsletter_subscribers (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT,
  email         TEXT UNIQUE,
  phone         TEXT,
  is_active     BOOLEAN DEFAULT TRUE,
  subscribed_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE newsletter_subscribers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_insert" ON newsletter_subscribers FOR INSERT WITH CHECK (TRUE);
CREATE POLICY "admins_all" ON newsletter_subscribers FOR ALL
  USING (EXISTS (SELECT 1 FROM admin_users WHERE id = auth.uid()));

-- ─── VERIFY ──────────────────────────────────────────────────
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
