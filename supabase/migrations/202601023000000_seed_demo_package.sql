-- ============================================================
-- Migration v23: Seed a complete demo Umrah package
-- Adds missing columns first if they don't exist, then inserts.
-- ============================================================

-- Ensure columns exist (safe if already present)
ALTER TABLE packages ADD COLUMN IF NOT EXISTS doc_conditions   TEXT;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS documents_config JSONB;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS mecca_hotels     JSONB;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS madina_hotels    JSONB;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS flight_ticket_price NUMERIC(10,2) DEFAULT 0;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS is_preorder      BOOLEAN DEFAULT FALSE;
ALTER TABLE packages ADD COLUMN IF NOT EXISTS preorder_note    TEXT;

DO $$
DECLARE
  pkg_id UUID;
BEGIN

  IF EXISTS (
    SELECT 1 FROM packages
    WHERE title = 'برنامج العمرة المتميز — 14 ليلة (نموذج)'
  ) THEN
    RAISE NOTICE 'Demo package already exists — skipping.';
    RETURN;
  END IF;

  INSERT INTO packages (
    title, category, season,
    departure_date, return_date, duration_nights, departure_city,
    price_per_person, price_child, price_infant,
    max_seats, available_seats, discount_percent,
    mecca_hotel, mecca_hotel_stars, nights_mecca, mecca_hotel_distance,
    medina_hotel, medina_hotel_stars, nights_medina, medina_hotel_distance,
    flight_type, airline, flight_ticket_price, transport_type,
    thumbnail_url, includes, excludes, itinerary, notes,
    visa_included, is_featured, is_active, is_preorder,
    doc_conditions, documents_config,
    mecca_hotels, madina_hotels
  )
  VALUES (
    'برنامج العمرة المتميز — 14 ليلة (نموذج)',
    'متميز', 'رجب',
    '2026-11-01', '2026-11-15', 14, 'الزقازيق',
    18500.00, 12000.00, 2000.00,
    40, 36, 5,
    'فندق أبراج البيت كونراد', 5, 7, '50 متر من المسجد الحرام',
    'فندق موفنبيك المدينة', 5, 7, '200 متر من المسجد النبوي',
    'مباشر', 'مصر للطيران', 2800.00, 'باص VIP',
    'https://images.unsplash.com/photo-1580418827493-f2b22c0a76cb?w=800',

    '["تذاكر طيران ذهاب وإياب مصر للطيران درجة سياحية","تأشيرة العمرة","إقامة فندقية 5 نجوم في مكة والمدينة","وجبة الإفطار يومياً","مواصلات VIP بين المطار والفنادق","مواصلات بين مكة والمدينة","مرشد ديني طوال الرحلة","جولة في المشاعر المقدسة","زيارة المدينة المنورة والمواقع الأثرية","حقيبة العمرة (مصحف، سجادة، هدايا)","تأمين سفر شامل"]'::jsonb,

    '["وجبات الغداء والعشاء","المصاريف الشخصية","الزيارات الاختيارية الإضافية","رسوم الأمتعة الزائدة","أي خدمات غير مذكورة في البرنامج"]'::jsonb,

    '[
      {"day":1,"title":"المغادرة من الزقازيق","description":"التجمع في مطار القاهرة الدولي، إجراءات السفر، الرحلة إلى جدة، الانتقال إلى مكة، تسجيل الوصول، أداء العمرة."},
      {"day":2,"title":"مكة — العبادة والطواف","description":"صلاة الفجر في المسجد الحرام، إفطار في الفندق، وقت حر للعبادة والتطوع."},
      {"day":3,"title":"مكة — جولة المشاعر المقدسة","description":"زيارة مسجد عائشة، جبل النور وغار حراء، مسجد الجن، المدينة القديمة."},
      {"day":4,"title":"مكة — وقت حر وعبادة","description":"وقت حر للعبادة والتسوق في برج ساعة مكة وأسواق الجوار."},
      {"day":5,"title":"مكة — زيارات إضافية","description":"زيارة مقبرة المعلا، مسجد بلال، بئر زمزم، الطواف المسائي."},
      {"day":6,"title":"مكة — ليلة الجمعة","description":"إحياء ليلة الجمعة بالقرآن والدعاء، درس ديني مع المرشد."},
      {"day":7,"title":"الانتقال إلى المدينة المنورة","description":"بعد الفجر، انتقال بالباص VIP إلى المدينة، تسجيل الوصول، زيارة المسجد النبوي والسلام على النبي ﷺ."},
      {"day":8,"title":"المدينة — المسجد النبوي","description":"الصلوات الخمس في المسجد النبوي، زيارة الروضة الشريفة، قراءة القرآن."},
      {"day":9,"title":"المدينة — الجولة الأثرية","description":"زيارة مسجد قباء، المساجد السبعة، بئر أريس، جبل أحد ومقبرة الشهداء."},
      {"day":10,"title":"المدينة — وقت حر وتسوق","description":"وقت حر للتسوق من الأسواق المركزية والتمور والهدايا."},
      {"day":11,"title":"المدينة — زيارات دينية","description":"زيارة مسجد القبلتين، مسجد الغمامة، حديقة الهجرة."},
      {"day":12,"title":"المدينة — يوم حر","description":"وقت حر للعبادة والراحة والتسوق الأخير."},
      {"day":13,"title":"العودة إلى مكة والمطار","description":"الانتقال إلى مطار جدة، إجراءات المغادرة، الرحلة العائدة إلى القاهرة."},
      {"day":14,"title":"الوصول إلى الزقازيق","description":"الوصول إلى مطار القاهرة، الانتقال إلى الزقازيق."}
    ]'::jsonb,

    'يُرجى التأكد من صلاحية جواز السفر لمدة لا تقل عن 6 أشهر. الفنادق قابلة للتغيير بما يعادلها أو أفضل حسب التوفر.',
    TRUE, TRUE, TRUE, FALSE,

    'جواز سفر ساري لا يقل عن 6 أشهر — صورة شخصية بخلفية بيضاء — شهادة تطعيم الحمى الشوكية — بطاقة رقم قومي سارية',

    '{"passport":"required","national_id":"required","personal_photo":"required","meningitis":"required","covid":"optional","birth_cert":"hidden","adult":{"passport":"required","national_id":"required","personal_photo":"required","meningitis":"required","covid":"optional","birth_cert":"hidden"},"child":{"passport":"required","national_id":"hidden","personal_photo":"required","meningitis":"required","covid":"optional","birth_cert":"required"},"infant":{"passport":"optional","national_id":"hidden","personal_photo":"optional","meningitis":"hidden","covid":"hidden","birth_cert":"required"},"custom_docs":[]}'::jsonb,

    '[
      {"name":"فندق أبراج البيت كونراد","stars":5,"nights":7,"distance":"50 متر من المسجد الحرام","description":"فندق 5 نجوم بإطلالة مباشرة على الكعبة المشرفة. مطعم بوفيه فطور فاخر، خدمة الغرف 24 ساعة.","room_tiers":[
        {"label":"غرفة مزدوجة (شخصان)","description":"غرفة واسعة بسريرين منفصلين، إطلالة على الحرم","capacity":2,"price":3200},
        {"label":"غرفة ثلاثية (3 أشخاص)","description":"غرفة بسرير كبير وسرير إضافي، مناسبة للعائلات الصغيرة","capacity":3,"price":4500},
        {"label":"غرفة رباعية (4 أشخاص)","description":"جناح عائلي بغرفتين متصلتين","capacity":4,"price":5800}
      ]},
      {"name":"فندق هيلتون مكة كونفنشن","stars":5,"nights":7,"distance":"300 متر من المسجد الحرام","description":"فندق هيلتون الراقي، مسبح على السطح، مركز لياقة، مواصلات مجانية للحرم.","room_tiers":[
        {"label":"غرفة مزدوجة اقتصادية","description":"غرفة مريحة بسريرين، مناسبة للزوجين","capacity":2,"price":2400},
        {"label":"غرفة ثلاثية","description":"غرفة عائلية مع سرير إضافي قابل للطي","capacity":3,"price":3400},
        {"label":"جناح عائلي كبير (5 أشخاص)","description":"جناح فاخر بصالة جلوس وغرفتين نوم","capacity":5,"price":6800}
      ]},
      {"name":"فندق موفنبيك أبراج البيت","stars":4,"nights":7,"distance":"100 متر من المسجد الحرام","description":"فندق 4 نجوم بموقع ممتاز وأسعار معقولة. إفطار بوفيه يومي.","room_tiers":[
        {"label":"غرفة مزدوجة اقتصادية","description":"غرفة مريحة بسريرين مفردين أو سرير مزدوج","capacity":2,"price":1800},
        {"label":"غرفة ثلاثية","description":"غرفة موسعة بثلاثة أسرة","capacity":3,"price":2600},
        {"label":"غرفة رباعية","description":"غرفة كبيرة بأربعة أسرة، اقتصادية للمجموعات","capacity":4,"price":3300}
      ]}
    ]'::jsonb,

    '[
      {"name":"فندق موفنبيك المدينة المنورة","stars":5,"nights":7,"distance":"200 متر من المسجد النبوي","description":"فندق 5 نجوم مطل على المسجد النبوي الشريف. مطعم عالمي، خدمة غرف 24 ساعة.","room_tiers":[
        {"label":"غرفة مزدوجة فاخرة","description":"غرفة بإطلالة على المسجد النبوي، سريران مفردان أو مزدوج","capacity":2,"price":3000},
        {"label":"غرفة ثلاثية فاخرة","description":"غرفة عائلية واسعة بثلاثة أسرة","capacity":3,"price":4200},
        {"label":"جناح عائلي (4 أشخاص)","description":"جناح بغرفتين متصلتين وصالة جلوس صغيرة","capacity":4,"price":5500}
      ]},
      {"name":"فندق أنوار المدينة موفنبيك","stars":4,"nights":7,"distance":"500 متر من المسجد النبوي","description":"فندق 4 نجوم بأسعار مناسبة. باص مكوك مجاني للمسجد النبوي كل ساعة.","room_tiers":[
        {"label":"غرفة مزدوجة اقتصادية","description":"غرفة مريحة بسريرين، مثالية للزوجين","capacity":2,"price":1600},
        {"label":"غرفة ثلاثية","description":"غرفة عائلية بثلاثة أسرة","capacity":3,"price":2300},
        {"label":"غرفة رباعية اقتصادية","description":"غرفة كبيرة بأربعة أسرة","capacity":4,"price":2900},
        {"label":"جناح خماسي (5 أشخاص)","description":"جناح موسع مناسب للعائلات الكبيرة","capacity":5,"price":3700}
      ]}
    ]'::jsonb
  )
  RETURNING id INTO pkg_id;

  RAISE NOTICE '✅ Demo package inserted — ID: %', pkg_id;

END $$;
