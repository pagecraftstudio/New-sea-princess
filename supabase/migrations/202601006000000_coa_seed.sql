-- ══════════════════════════════════════════════════════════════
--  NSP Migration v6 — Chart of Accounts Seed Data
--  Run AFTER v5. Seeds default CoA for NSP Tourism.
-- ══════════════════════════════════════════════════════════════

-- ─── ACCOUNT CATEGORIES ──────────────────────────────────────
INSERT INTO account_categories (code, name_ar, name_en, type, normal_balance, display_order) VALUES
  ('ASSET',       'الأصول',             'Assets',           'asset',       'debit',  1),
  ('LIABILITY',   'الالتزامات',         'Liabilities',      'liability',   'credit', 2),
  ('EQUITY',      'حقوق الملكية',       'Equity',           'equity',      'credit', 3),
  ('REVENUE',     'الإيرادات',          'Revenue',          'revenue',     'credit', 4),
  ('DIRECT_COST', 'التكاليف المباشرة',  'Direct Costs',     'direct_cost', 'debit',  5),
  ('EXPENSE',     'مصروفات التشغيل',    'Operating Expenses','expense',    'debit',  6)
ON CONFLICT (code) DO NOTHING;

-- ─── CHART OF ACCOUNTS ───────────────────────────────────────
-- ASSETS (1xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'debit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'ASSET')
FROM (VALUES
  ('1000', 'الأصول المتداولة',           'Current Assets',         'asset'),
  ('1100', 'النقدية والبنوك',            'Cash & Banks',           'asset'),
  ('1101', 'الصندوق الرئيسي',           'Main Cash',              'asset'),
  ('1102', 'البنك الأهلي',              'National Bank',          'asset'),
  ('1103', 'فودافون كاش',               'Vodafone Cash',          'asset'),
  ('1104', 'انستاباي',                  'InstaPay',               'asset'),
  ('1200', 'ذمم مدينة - عملاء',         'Accounts Receivable',    'asset'),
  ('1201', 'دفعات مقدمة من عملاء',      'Customer Advances',      'asset'),
  ('1300', 'الأصول الثابتة',            'Fixed Assets',           'asset'),
  ('1301', 'أثاث ومعدات',              'Furniture & Equipment',   'asset')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- LIABILITIES (2xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'credit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'LIABILITY')
FROM (VALUES
  ('2000', 'الالتزامات المتداولة',       'Current Liabilities',    'liability'),
  ('2100', 'ذمم دائنة - موردون',        'Accounts Payable',       'liability'),
  ('2200', 'دفعات مقدمة من عملاء',      'Customer Advances Liab', 'liability'),
  ('2300', 'مصروفات مستحقة',           'Accrued Expenses',       'liability'),
  ('2400', 'ضريبة مستحقة',             'Taxes Payable',          'liability')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- EQUITY (3xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'credit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'EQUITY')
FROM (VALUES
  ('3000', 'حقوق الملكية',             'Equity',                  'equity'),
  ('3100', 'رأس المال',               'Capital',                  'equity'),
  ('3200', 'الأرباح المحتجزة',         'Retained Earnings',       'equity'),
  ('3300', 'صافي ربح / خسارة الفترة', 'Current Period P&L',      'equity')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- REVENUE (4xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'credit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'REVENUE')
FROM (VALUES
  ('4000', 'الإيرادات',               'Revenue',                  'revenue'),
  ('4100', 'إيرادات العمرة',           'Umrah Revenue',           'revenue'),
  ('4200', 'إيرادات الحج',             'Hajj Revenue',            'revenue'),
  ('4300', 'إيرادات السياحة',          'Tourism Revenue',         'revenue'),
  ('4400', 'تذاكر الطيران',            'Airline Tickets',         'revenue'),
  ('4500', 'خدمات التأشيرة',           'Visa Services',           'revenue'),
  ('4600', 'إيرادات الفنادق',          'Hotel Revenue',           'revenue'),
  ('4700', 'إيرادات النقل',            'Transport Revenue',       'revenue'),
  ('4900', 'إيرادات أخرى',             'Other Revenue',           'revenue')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- DIRECT COSTS (5xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'debit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'DIRECT_COST')
FROM (VALUES
  ('5000', 'التكاليف المباشرة',         'Direct Costs',            'direct_cost'),
  ('5100', 'تكلفة الفنادق',            'Hotel Costs',             'direct_cost'),
  ('5200', 'تكلفة الطيران',            'Airline Costs',           'direct_cost'),
  ('5300', 'تكلفة التأشيرات',          'Visa Costs',              'direct_cost'),
  ('5400', 'تكلفة النقل',              'Transport Costs',         'direct_cost'),
  ('5500', 'تكلفة الباقة من الموردين', 'Supplier Package Costs',  'direct_cost'),
  ('5900', 'تكاليف مباشرة أخرى',       'Other Direct Costs',      'direct_cost')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- OPERATING EXPENSES (6xxx)
INSERT INTO accounts (code, name_ar, name_en, type, normal_balance, is_system, category_id)
SELECT code, name_ar, name_en, type, 'debit', TRUE,
  (SELECT id FROM account_categories WHERE code = 'EXPENSE')
FROM (VALUES
  ('6000', 'مصروفات التشغيل',          'Operating Expenses',      'expense'),
  ('6100', 'الرواتب والأجور',          'Salaries & Wages',        'expense'),
  ('6200', 'الإيجار',                  'Rent',                    'expense'),
  ('6300', 'المرافق',                  'Utilities',               'expense'),
  ('6400', 'التسويق والإعلان',         'Marketing',               'expense'),
  ('6500', 'الاتصالات',               'Communications',           'expense'),
  ('6600', 'البرمجيات والتكنولوجيا',   'Software & IT',           'expense'),
  ('6700', 'رسوم بنكية',               'Bank Fees',               'expense'),
  ('6800', 'العمولات',                 'Commissions',             'expense'),
  ('6900', 'مصروفات مكتبية',           'Office Expenses',         'expense'),
  ('6999', 'مصروفات أخرى',             'Other Expenses',          'expense')
) AS t(code, name_ar, name_en, type)
ON CONFLICT (code) DO NOTHING;

-- ─── DEFAULT ACCOUNTING MAPPINGS ─────────────────────────────
INSERT INTO accounting_mappings (mapping_key, account_id, description)
SELECT key, (SELECT id FROM accounts WHERE code = acct_code), description
FROM (VALUES
  ('ar_account',           '1200', 'ذمم مدينة عملاء'),
  ('cash_account',         '1101', 'الصندوق الرئيسي'),
  ('revenue_umrah',        '4100', 'إيرادات العمرة'),
  ('revenue_hajj',         '4200', 'إيرادات الحج'),
  ('revenue_tourism',      '4300', 'إيرادات السياحة'),
  ('revenue_default',      '4000', 'إيرادات عامة'),
  ('ap_account',           '2100', 'ذمم دائنة موردون'),
  ('cost_hotel',           '5100', 'تكلفة الفنادق'),
  ('cost_flight',          '5200', 'تكلفة الطيران'),
  ('cost_visa',            '5300', 'تكلفة التأشيرات'),
  ('cost_transport',       '5400', 'تكلفة النقل'),
  ('cost_other',           '5900', 'تكاليف مباشرة أخرى'),
  ('bank_fees',            '6700', 'رسوم بنكية'),
  ('expense_general',      '6000', 'مصروفات تشغيل عامة'),
  ('customer_advances',    '2200', 'مقدمات عملاء')
) AS t(key, acct_code, description)
WHERE (SELECT id FROM accounts WHERE code = acct_code) IS NOT NULL
ON CONFLICT (mapping_key) DO NOTHING;

-- ─── DEFAULT FISCAL PERIOD (current year) ────────────────────
INSERT INTO fiscal_periods (name, start_date, end_date, status)
VALUES (
  'السنة المالية ' || TO_CHAR(now(), 'YYYY'),
  DATE_TRUNC('year', now())::DATE,
  (DATE_TRUNC('year', now()) + INTERVAL '1 year - 1 day')::DATE,
  'open'
)
ON CONFLICT DO NOTHING;

-- ─── DEFAULT COST CENTER ─────────────────────────────────────
INSERT INTO cost_centers (code, name_ar, name_en)
VALUES ('MAIN', 'الإدارة الرئيسية', 'Head Office')
ON CONFLICT (code) DO NOTHING;

-- Verify
SELECT COUNT(*) AS accounts_count FROM accounts;
SELECT COUNT(*) AS mappings_count FROM accounting_mappings;
