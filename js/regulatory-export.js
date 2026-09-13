/**
 * regulatory-export.js — New Sea Princess Tourism
 * One-Click Ministry of Tourism (Egypt) & Nusuk Platform Report Exporter
 *
 * Exports confirmed bookings (primary traveler + companions) to:
 *   1. وزارة السياحة المصرية — Excel/CSV
 *   2. منصة نسك (Nusuk)     — Excel/CSV
 *
 * Triggered from:
 *   - Top toolbar button in bookings.html (bulk export with scope selector)
 *   - Modal footer inside each individual booking (single booking export)
 *
 * © 2026 New Sea Princess Tourism. All rights reserved.
 */

// ─────────────────────────────────────────────────────────
//  CONSTANTS
// ─────────────────────────────────────────────────────────
const REG_COMPANY = {
  name:       'نيو سي برنسيس فرع الزقازيق فرع الزقازيق',
  license:    '926',
  type:       'شركة سياحة (أ)',
  director:   'د. شيماء السعداوي',
  phone1:     '01555154996',
  phone2:     '01031777295',
};

const REG_STATUS_CONFIRMED = 'confirmed';

// ─────────────────────────────────────────────────────────
//  ENTRY POINT — open the export dialog modal
//  scope: 'all' | 'filtered' | booking-object (single booking)
// ─────────────────────────────────────────────────────────
function openRegulatoryExportModal(scope) {
  // Remove any stale modal
  const old = document.getElementById('regExportModal');
  if (old) old.remove();

  // Determine available data for display counts
  const allData      = window.allBookings      || [];
  const filteredData = window.filteredBookings || [];
  const confirmedAll      = allData.filter(b => b.status === REG_STATUS_CONFIRMED);
  const confirmedFiltered = filteredData.filter(b => b.status === REG_STATUS_CONFIRMED);

  const isSingle = scope && typeof scope === 'object' && scope.id;

  // Build scope options HTML (only for bulk export)
  const scopeOptionsHtml = isSingle ? '' : `
    <div class="reg-section">
      <div class="reg-section-title">
        <i class="fa-solid fa-database"></i> نطاق التصدير
      </div>
      <div class="reg-scope-grid">
        <label class="reg-scope-card" id="scopeCardFiltered">
          <input type="radio" name="regScope" value="filtered" checked>
          <div class="reg-scope-body">
            <i class="fa-solid fa-filter text-blue-500 text-xl mb-1"></i>
            <div class="reg-scope-count">${confirmedFiltered.length}</div>
            <div class="reg-scope-label">الحجوزات المفلترة الحالية<br><span class="text-xs text-gray-400">(confirmed فقط)</span></div>
          </div>
        </label>
        <label class="reg-scope-card" id="scopeCardAll">
          <input type="radio" name="regScope" value="all">
          <div class="reg-scope-body">
            <i class="fa-solid fa-database text-green-600 text-xl mb-1"></i>
            <div class="reg-scope-count">${confirmedAll.length}</div>
            <div class="reg-scope-label">كل الحجوزات المؤكدة<br><span class="text-xs text-gray-400">(قاعدة البيانات كاملة)</span></div>
          </div>
        </label>
      </div>
    </div>`;

  // Name split option
  const nameSplitHtml = `
    <div class="reg-section">
      <div class="reg-section-title">
        <i class="fa-solid fa-user-tag"></i> صيغة الاسم في التقرير
      </div>
      <div class="reg-radio-group">
        <label class="reg-radio-opt">
          <input type="radio" name="regNameSplit" value="full" checked>
          <span>الاسم كاملاً في عمود واحد</span>
        </label>
        <label class="reg-radio-opt">
          <input type="radio" name="regNameSplit" value="split3">
          <span>تقسيم تلقائي — اسم ثلاثي (الاسم / الأب / الجد)</span>
        </label>
        <label class="reg-radio-opt">
          <input type="radio" name="regNameSplit" value="split4">
          <span>تقسيم تلقائي — اسم رباعي (الاسم / الأب / الجد / القبيلة)</span>
        </label>
      </div>
    </div>`;

  // Report type selector
  const reportTypeHtml = `
    <div class="reg-section">
      <div class="reg-section-title">
        <i class="fa-solid fa-file-export"></i> نوع التقرير
      </div>
      <div class="reg-report-grid">
        <label class="reg-report-card" id="rptMinistry">
          <input type="checkbox" name="regReport" value="ministry" checked>
          <div class="reg-report-body">
            <div class="reg-report-icon" style="background:#fff7e0;border-color:#f59e0b">
              <i class="fa-solid fa-landmark text-amber-500 text-2xl"></i>
            </div>
            <div class="reg-report-name">وزارة السياحة المصرية</div>
            <div class="reg-report-desc">كشف المسافرين الرسمي — CSV</div>
          </div>
        </label>
        <label class="reg-report-card" id="rptNusuk">
          <input type="checkbox" name="regReport" value="nusuk" checked>
          <div class="reg-report-body">
            <div class="reg-report-icon" style="background:#f0fdf4;border-color:#22c55e">
              <i class="fa-solid fa-kaaba text-green-600 text-2xl"></i>
            </div>
            <div class="reg-report-name">منصة نسك (Nusuk)</div>
            <div class="reg-report-desc">قائمة المعتمرين — CSV</div>
          </div>
        </label>
      </div>
    </div>`;

  const singleBadgeHtml = isSingle ? `
    <div class="reg-single-badge">
      <i class="fa-solid fa-receipt text-primary ml-2"></i>
      تصدير الحجز <strong>${scope.booking_number}</strong> — ${scope.customer_name}
    </div>` : '';

  const modal = document.createElement('div');
  modal.id = 'regExportModal';
  modal.className = 'reg-modal-overlay';
  modal.innerHTML = `
    <div class="reg-modal-box">

      <!-- Header -->
      <div class="reg-modal-header">
        <div class="flex items-center gap-3">
          <div class="reg-header-icon">
            <i class="fa-solid fa-file-shield text-2xl text-white"></i>
          </div>
          <div>
            <h2 class="reg-modal-title">التصدير التنظيمي الرسمي</h2>
            <p class="reg-modal-sub">وزارة السياحة المصرية & منصة نسك</p>
          </div>
        </div>
        <button onclick="closeRegulatoryModal()" class="reg-close-btn">
          <i class="fa-solid fa-xmark text-lg"></i>
        </button>
      </div>

      <!-- Body -->
      <div class="reg-modal-body">
        ${singleBadgeHtml}
        ${scopeOptionsHtml}
        ${nameSplitHtml}
        ${reportTypeHtml}

        <!-- Info notice -->
        <div class="reg-notice">
          <i class="fa-solid fa-circle-info text-blue-500 mt-0.5 shrink-0"></i>
          <div class="text-xs text-blue-700 leading-relaxed">
            يُصدَّر <strong>المسافر الرئيسي + المرافقون</strong> في صفوف منفصلة.
            الملف بصيغة CSV بترميز UTF-8 مع BOM لدعم اللغة العربية في Excel.
            <strong>الحجوزات المؤكدة (confirmed) فقط</strong> هي التي تُضمَّن في التقرير.
          </div>
        </div>
      </div>

      <!-- Footer actions -->
      <div class="reg-modal-footer">
        <button onclick="closeRegulatoryModal()"
                class="reg-btn-cancel">
          <i class="fa-solid fa-xmark ml-1"></i> إلغاء
        </button>
        <button onclick="executeRegulatoryExport('${isSingle ? 'single' : 'bulk'}', ${isSingle ? JSON.stringify(scope?.id || '') : 'null'})"
                class="reg-btn-export">
          <i class="fa-solid fa-cloud-arrow-down ml-2"></i>
          تحميل التقارير المحددة
        </button>
      </div>

    </div>`;

  document.body.appendChild(modal);

  // Sync scope card highlight on radio change
  modal.querySelectorAll('input[name="regScope"]').forEach(r => {
    r.addEventListener('change', () => {
      document.getElementById('scopeCardFiltered')?.classList.toggle('reg-scope-active', r.value === 'filtered' && r.checked);
      document.getElementById('scopeCardAll')?.classList.toggle('reg-scope-active', r.value === 'all' && r.checked);
    });
  });
  // Sync report card highlight on checkbox change
  modal.querySelectorAll('input[name="regReport"]').forEach(cb => {
    cb.addEventListener('change', () => {
      document.getElementById('rptMinistry')?.classList.toggle('reg-report-active',
        modal.querySelector('input[value="ministry"]')?.checked);
      document.getElementById('rptNusuk')?.classList.toggle('reg-report-active',
        modal.querySelector('input[value="nusuk"]')?.checked);
    });
  });

  // Set initial active states
  document.getElementById('scopeCardFiltered')?.classList.add('reg-scope-active');
  document.getElementById('rptMinistry')?.classList.add('reg-report-active');
  document.getElementById('rptNusuk')?.classList.add('reg-report-active');

  // Prevent background scroll
  document.body.style.overflow = 'hidden';
}

function closeRegulatoryModal() {
  const m = document.getElementById('regExportModal');
  if (m) m.remove();
  document.body.style.overflow = '';
}

// ─────────────────────────────────────────────────────────
//  EXECUTE EXPORT
// ─────────────────────────────────────────────────────────
function executeRegulatoryExport(mode, singleId) {
  const modal = document.getElementById('regExportModal');

  // Read report type selections
  const wantMinistry = modal?.querySelector('input[value="ministry"]')?.checked ?? true;
  const wantNusuk    = modal?.querySelector('input[value="nusuk"]')?.checked    ?? true;

  if (!wantMinistry && !wantNusuk) {
    showRegToast('يرجى اختيار نوع تقرير واحد على الأقل', 'red');
    return;
  }

  // Read name split mode
  const nameSplit = modal?.querySelector('input[name="regNameSplit"]:checked')?.value || 'full';

  // Gather data
  let data = [];
  if (mode === 'single') {
    const b = (window.allBookings || []).find(x => x.id === singleId);
    data = b ? [b] : [];
  } else {
    const scopeVal = modal?.querySelector('input[name="regScope"]:checked')?.value || 'filtered';
    const pool = scopeVal === 'all'
      ? (window.allBookings      || [])
      : (window.filteredBookings || []);
    data = pool.filter(b => b.status === REG_STATUS_CONFIRMED);
  }

  if (!data.length) {
    showRegToast('لا توجد حجوزات مؤكدة للتصدير في النطاق المحدد', 'red');
    return;
  }

  // Explode bookings → one row per traveler
  const rows = buildTravelerRows(data, nameSplit);

  closeRegulatoryModal();

  // Trigger downloads
  if (wantMinistry) downloadMinistryCSV(rows, data);
  if (wantNusuk)    downloadNusukCSV(rows, data);

  const count = rows.length;
  const types = [wantMinistry && 'وزارة السياحة', wantNusuk && 'نسك'].filter(Boolean).join(' + ');
  showRegToast(`✓ تم تصدير ${count} مسافر — ${types}`, 'green');
}

// ─────────────────────────────────────────────────────────
//  BUILD TRAVELER ROWS
//  Returns array of flat objects, one per traveler
// ─────────────────────────────────────────────────────────
function buildTravelerRows(bookings, nameSplit) {
  const rows = [];
  const today = new Date().toLocaleDateString('ar-EG');

  // Build a package lookup map from cached allPackages if available
  const pkgMap = {};
  (window.allPackages || []).forEach(p => { pkgMap[p.id] = p; });

  bookings.forEach(b => {
    const pkg = pkgMap[b.package_id] || {};
    // Attach pkg to booking for makeTravelerRow
    b._pkg = pkg;

    // Primary traveler — pull from booking root
    rows.push(makeTravelerRow(b, {
      name:                   b.customer_name || '—',
      type:                   'adult',
      national_id:            b.customer_national_id || '',
      passport:               b.customer_passport_number || '',
      passport_expiry:        '',   // not stored at booking root; companions have it
      gender:                 '',
      nationality:            'مصري',
      place_of_birth:         '',
      date_of_birth:          '',
      vaccination_meningitis: false,
      isPrimary:              true,
    }, nameSplit, today));

    // Companions from travelers JSONB array
    const companions = Array.isArray(b.travelers) ? b.travelers : [];
    companions.forEach(t => {
      rows.push(makeTravelerRow(b, {
        name:                   t.name        || '—',
        type:                   t.type        || 'adult',
        national_id:            t.national_id || '',
        passport:               t.passport    || '',
        passport_expiry:        t.passport_expiry || '',
        gender:                 t.gender      || '',
        nationality:            t.nationality || 'مصري',
        place_of_birth:         t.place_of_birth || '',
        date_of_birth:          t.date_of_birth  || '',
        vaccination_meningitis: t.vaccination_meningitis || false,
        isPrimary:              false,
      }, nameSplit, today));
    });
  });

  return rows;
}

function makeTravelerRow(booking, traveler, nameSplit, exportDate) {
  const nameParts = splitName(traveler.name, nameSplit);
  const pkg = booking._pkg || {};          // package-level data attached in buildTravelerRows
  return {
    // Booking meta
    booking_number:        booking.booking_number  || '—',
    package_title:         booking.package_title   || '—',
    departure_date:        fmtDateSimple(booking.package_departure),
    return_date:           fmtDateSimple(pkg.return_date),
    booking_date:          fmtDateSimple(booking.booking_date),
    export_date:           exportDate,
    // Traveler identity
    full_name:             traveler.name,
    first_name:            nameParts[0] || '',
    father_name:           nameParts[1] || '',
    grandfather_name:      nameParts[2] || '',
    family_name:           nameParts[3] || '',
    traveler_type:         traveler.type === 'child' ? 'طفل' : 'بالغ',
    is_primary:            traveler.isPrimary ? 'رئيسي' : 'مرافق',
    gender:                traveler.gender === 'male' ? 'M' : (traveler.gender === 'female' ? 'F' : ''),
    nationality:           traveler.nationality || 'مصري',
    place_of_birth:        traveler.place_of_birth || '',
    date_of_birth:         traveler.date_of_birth  || '',
    // IDs
    national_id:           traveler.national_id,
    passport_number:       traveler.passport,
    passport_expiry:       traveler.passport_expiry || '',
    // Vaccination
    vaccination_meningitis: traveler.vaccination_meningitis ? 'نعم' : 'لا',
    // Contact (primary only)
    phone:                 traveler.isPrimary ? (booking.customer_phone || '') : '',
    email:                 traveler.isPrimary ? (booking.customer_email || '') : '',
    // Financial (booking level)
    total_price:           booking.total_price    || 0,
    paid_amount:           booking.paid_amount    || 0,
    remaining_amount:      booking.remaining_amount ?? (booking.total_price - booking.paid_amount),
    // Accommodation
    mecca_hotel:           pkg.mecca_hotel           || '',
    mecca_hotel_stars:     pkg.mecca_hotel_stars     || '',
    mecca_hotel_distance:  pkg.mecca_hotel_distance  || '',
    medina_hotel:          pkg.medina_hotel          || '',
    medina_hotel_stars:    pkg.medina_hotel_stars    || '',
    medina_hotel_distance: pkg.medina_hotel_distance || '',
    // Transport & Flight
    airline:               pkg.airline               || '',
    transport_type:        pkg.transport_type        || '',
    // Regulatory
    brn_reference:         pkg.brn_reference         || '',
    religious_supervisor:  pkg.religious_supervisor  || '',
    // Adults / children counts
    adults_count:          booking.adults_count   || 0,
    children_count:        booking.children_count || 0,
    // Company
    company_name:          REG_COMPANY.name,
    license_number:        REG_COMPANY.license,
    license_type:          REG_COMPANY.type,
  };
}

// ─────────────────────────────────────────────────────────
//  NAME SPLITTER
// ─────────────────────────────────────────────────────────
function splitName(fullName, mode) {
  if (mode === 'full') return [fullName, '', '', ''];
  const parts = (fullName || '').trim().split(/\s+/);
  if (mode === 'split3') {
    return [parts[0]||'', parts[1]||'', parts.slice(2).join(' ')||'', ''];
  }
  if (mode === 'split4') {
    return [parts[0]||'', parts[1]||'', parts[2]||'', parts.slice(3).join(' ')||''];
  }
  return [fullName, '', '', ''];
}

// ─────────────────────────────────────────────────────────
//  MINISTRY OF TOURISM CSV  (بوابة العمرة المصرية)
//  Fields per: Law No. 72/2021 Safar Barcode schema
// ─────────────────────────────────────────────────────────
function downloadMinistryCSV(rows, bookings) {
  const dateStr  = new Date().toISOString().slice(0,10);
  const totalPax = rows.length;

  const metaRows = [
    ['شركة السياحة', REG_COMPANY.name, 'رقم الترخيص', REG_COMPANY.license, 'نوع الترخيص', REG_COMPANY.type],
    ['اسم المسؤول', REG_COMPANY.director, 'تاريخ التصدير', dateStr, 'إجمالي المسافرين', totalPax],
    [],
  ];

  // A. بيانات المعتمرين + B. بيانات البرنامج + C. accountability
  const headers = [
    'م',
    // A — Pilgrim Personal Manifest
    'رقم الحجز',
    'الاسم الرباعي الكامل',
    'الاسم الأول', 'اسم الأب', 'اسم الجد', 'اسم العائلة',
    'الرقم القومي',
    'رقم جواز السفر',
    'تاريخ انتهاء الجواز',
    'الجنس',
    'الجنسية',
    'محل الميلاد',
    'تاريخ الميلاد',
    'تطعيم الحمى الشوكية (MenACYW)',
    // B — Program & Itinerary
    'البرنامج السياحي',
    'تاريخ المغادرة',
    'تاريخ العودة',
    'فندق مكة المكرمة',
    'نجوم فندق مكة',
    'بعد فندق مكة عن الحرم',
    'فندق المدينة المنورة',
    'نجوم فندق المدينة',
    'بعد فندق المدينة عن الحرم',
    'شركة النقل / المواصلات',
    'شركة الطيران',
    // C — Company Accountability
    'إجمالي تكلفة الحجز (ج.م)',
    'المبلغ المدفوع (ج.م)',
    'الرصيد المتبقي (ج.م)',
    'اسم المشرف الديني المعتمد',
    // Meta
    'نوع المسافر',
    'الحالة في الكشف',
    'رقم الهاتف',
    'البريد الإلكتروني',
    'تاريخ الحجز',
    'اسم شركة السياحة',
    'رقم ترخيص الشركة',
  ];

  const dataRows = rows.map((r, i) => [
    i + 1,
    r.booking_number,
    r.full_name,
    r.first_name, r.father_name, r.grandfather_name, r.family_name,
    r.national_id,
    r.passport_number,
    r.passport_expiry,
    r.gender,
    r.nationality,
    r.place_of_birth,
    r.date_of_birth,
    r.vaccination_meningitis,
    r.package_title,
    r.departure_date,
    r.return_date,
    r.mecca_hotel,
    r.mecca_hotel_stars,
    r.mecca_hotel_distance,
    r.medina_hotel,
    r.medina_hotel_stars,
    r.medina_hotel_distance,
    r.transport_type,
    r.airline,
    r.total_price,
    r.paid_amount,
    r.remaining_amount,
    r.religious_supervisor,
    r.traveler_type,
    r.is_primary,
    r.phone,
    r.email,
    r.booking_date,
    r.company_name,
    r.license_number,
  ]);

  const csv = buildCSV([...metaRows, headers, ...dataRows]);
  triggerDownload(csv, `كشف_وزارة_السياحة_${dateStr}.csv`);
}

// ─────────────────────────────────────────────────────────
//  NUSUK PLATFORM CSV  (كشوفات المجموعات — Ground Services)
//  Fields per: Saudi B2B Nusuk Masar portal MRZ-standard schema
// ─────────────────────────────────────────────────────────
function downloadNusukCSV(rows, bookings) {
  const dateStr  = new Date().toISOString().slice(0,10);
  const totalPax = rows.length;

  const metaRows = [
    ['جهة التقديم', REG_COMPANY.name, 'رقم الترخيص', REG_COMPANY.license, 'عدد المعتمرين', totalPax],
    ['المسؤول', REG_COMPANY.director, 'تاريخ التصدير', dateStr, '', ''],
    [],
  ];

  // A. Passport Logistics + B. Reservation References & Borders
  const headers = [
    'م',
    // A — Passport Logistics (MRZ-standard)
    'رقم الحجز',
    'الاسم الكامل (إنجليزي / MRZ)',
    'الاسم الأول', 'اسم الأب', 'اسم الجد', 'اسم القبيلة / العائلة',
    'نوع الوثيقة',   // P = Passport
    'دولة الإصدار',
    'رقم جواز السفر',
    'تاريخ انتهاء الجواز',
    'الجنس (M/F)',
    'تاريخ الميلاد',
    'محل الميلاد',
    'الجنسية الحالية',
    'رمز صلة المحرم / ولي الأمر',
    // B — Reservation References & Borders
    'رقم BRN السعودي',
    'مطار الدخول (JED/MED)',
    'تاريخ الوصول',
    'تاريخ المغادرة',
    'شركة الطيران',
    // Supporting
    'تطعيم الحمى الشوكية',
    'البرنامج السياحي',
    'نوع المسافر',
    'الحالة في الكشف',
    'رقم الجوال',
    'اسم شركة السياحة',
    'رقم الترخيص',
    'نوع الترخيص',
    'تاريخ إصدار الكشف',
  ];

  const dataRows = rows.map((r, i) => [
    i + 1,
    r.booking_number,
    r.full_name,
    r.first_name, r.father_name, r.grandfather_name, r.family_name,
    'P',                          // document type = Passport
    'EGY',                        // country of issue (Egyptian passports)
    r.passport_number,
    r.passport_expiry,
    r.gender,
    r.date_of_birth,
    r.place_of_birth,
    r.nationality,
    '',                           // mahram code — filled manually if needed
    r.brn_reference,
    'JED',                        // default port of entry; override per package if needed
    r.departure_date,
    r.return_date,
    r.airline,
    r.vaccination_meningitis,
    r.package_title,
    r.traveler_type,
    r.is_primary,
    r.phone,
    r.company_name,
    r.license_number,
    r.license_type,
    r.export_date,
  ]);

  const csv = buildCSV([...metaRows, headers, ...dataRows]);
  triggerDownload(csv, `كشف_نسك_المعتمرين_${dateStr}.csv`);
}

// ─────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────
function buildCSV(rows) {
  const esc = v => {
    const s = String(v ?? '');
    return (s.includes(',') || s.includes('"') || s.includes('\n'))
      ? '"' + s.replace(/"/g, '""') + '"'
      : s;
  };
  return rows.map(r => r.map(esc).join(',')).join('\n');
}

function triggerDownload(csvContent, filename) {
  const blob = new Blob(['\uFEFF' + csvContent], { type: 'text/csv;charset=utf-8;' });
  const url  = URL.createObjectURL(blob);
  const a    = Object.assign(document.createElement('a'), {
    href: url, download: filename
  });
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(url); }, 1500);
}

function fmtDateSimple(d) {
  if (!d) return '—';
  return new Date(d).toLocaleDateString('ar-EG');
}

function showRegToast(msg, color = 'green') {
  const map = { green: 'bg-green-600', red: 'bg-red-600', blue: 'bg-blue-600' };
  const toast = document.createElement('div');
  toast.className = `fixed bottom-6 left-1/2 -translate-x-1/2 ${map[color]||map.green} text-white px-6 py-3 rounded-xl shadow-xl font-bold text-sm z-[300] flex items-center gap-2`;
  toast.innerHTML = `<i class="fa-solid fa-circle-check"></i> ${msg}`;
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}

// ─────────────────────────────────────────────────────────
//  STYLES — injected once into <head>
// ─────────────────────────────────────────────────────────
(function injectRegStyles() {
  if (document.getElementById('reg-export-styles')) return;
  const style = document.createElement('style');
  style.id = 'reg-export-styles';
  style.textContent = `
    /* ── Overlay ── */
    .reg-modal-overlay {
      position: fixed; inset: 0; z-index: 200;
      background: rgba(0,0,0,0.65);
      display: flex; align-items: center; justify-content: center;
      padding: 1rem;
      font-family: 'Cairo', sans-serif;
    }

    /* ── Box ── */
    .reg-modal-box {
      background: #fff;
      border-radius: 1.25rem;
      width: 100%; max-width: 560px;
      max-height: 90vh;
      display: flex; flex-direction: column;
      box-shadow: 0 25px 60px rgba(0,0,0,0.35);
      overflow: hidden;
    }

    /* ── Header ── */
    .reg-modal-header {
      background: linear-gradient(135deg, #1B5E20 0%, #2E7D32 100%);
      padding: 1.1rem 1.4rem;
      display: flex; align-items: center; justify-content: space-between;
      border-bottom: 3px solid #B8860B;
      flex-shrink: 0;
    }
    .reg-header-icon {
      width: 48px; height: 48px; border-radius: 50%;
      background: rgba(255,255,255,0.15);
      display: flex; align-items: center; justify-content: center;
      border: 2px solid rgba(184,134,11,0.6);
    }
    .reg-modal-title { color: #fff; font-size: 1.1rem; font-weight: 700; margin: 0; }
    .reg-modal-sub   { color: #d4af6a; font-size: 0.75rem; margin: 0; }
    .reg-close-btn {
      width: 36px; height: 36px; border-radius: 50%;
      background: rgba(255,255,255,0.15); border: none; cursor: pointer;
      color: #fff; display: flex; align-items: center; justify-content: center;
      transition: background .2s;
    }
    .reg-close-btn:hover { background: rgba(255,255,255,0.3); }

    /* ── Body ── */
    .reg-modal-body {
      flex: 1; overflow-y: auto;
      padding: 1.25rem 1.4rem;
      display: flex; flex-direction: column; gap: 1.1rem;
    }

    /* ── Single badge ── */
    .reg-single-badge {
      background: #f0fdf4; border: 1.5px solid #bbf7d0;
      border-radius: .75rem; padding: .65rem 1rem;
      font-size: .85rem; color: #166534; font-weight: 600;
    }

    /* ── Section ── */
    .reg-section { display: flex; flex-direction: column; gap: .6rem; }
    .reg-section-title {
      font-size: .78rem; font-weight: 700; color: #374151;
      display: flex; align-items: center; gap: .5rem;
      border-bottom: 1px dashed #e5e7eb; padding-bottom: .35rem;
    }

    /* ── Scope cards ── */
    .reg-scope-grid {
      display: grid; grid-template-columns: 1fr 1fr; gap: .75rem;
    }
    .reg-scope-card {
      border: 2px solid #e5e7eb; border-radius: .85rem;
      cursor: pointer; transition: all .18s; overflow: hidden;
    }
    .reg-scope-card input { display: none; }
    .reg-scope-body {
      padding: .9rem; display: flex; flex-direction: column;
      align-items: center; text-align: center; gap: .25rem;
    }
    .reg-scope-count  { font-size: 1.8rem; font-weight: 800; color: #1B5E20; line-height: 1; }
    .reg-scope-label  { font-size: .72rem; color: #6b7280; font-weight: 600; }
    .reg-scope-active { border-color: #1B5E20; background: #f0fdf4; box-shadow: 0 0 0 3px #bbf7d020; }

    /* ── Name split radios ── */
    .reg-radio-group { display: flex; flex-direction: column; gap: .4rem; }
    .reg-radio-opt {
      display: flex; align-items: center; gap: .55rem;
      font-size: .8rem; color: #374151; cursor: pointer;
      padding: .45rem .6rem; border-radius: .5rem;
      border: 1.5px solid #e5e7eb; transition: border-color .15s;
    }
    .reg-radio-opt:hover { border-color: #1B5E20; background: #f9fafb; }
    .reg-radio-opt input[type=radio] { accent-color: #1B5E20; }

    /* ── Report type cards ── */
    .reg-report-grid {
      display: grid; grid-template-columns: 1fr 1fr; gap: .75rem;
    }
    .reg-report-card {
      border: 2px solid #e5e7eb; border-radius: .85rem;
      cursor: pointer; transition: all .18s;
    }
    .reg-report-card input { display: none; }
    .reg-report-body { padding: .9rem; display: flex; flex-direction: column; align-items: center; gap: .4rem; text-align: center; }
    .reg-report-icon {
      width: 56px; height: 56px; border-radius: 50%;
      border: 2px solid; display: flex; align-items: center; justify-content: center;
    }
    .reg-report-name { font-size: .8rem; font-weight: 700; color: #1f2937; }
    .reg-report-desc { font-size: .7rem; color: #9ca3af; }
    .reg-report-active { border-color: #1B5E20; background: #f9fffe; box-shadow: 0 0 0 3px #bbf7d020; }

    /* ── Notice ── */
    .reg-notice {
      background: #eff6ff; border: 1.5px solid #bfdbfe;
      border-radius: .75rem; padding: .75rem 1rem;
      display: flex; gap: .6rem; align-items: flex-start;
    }

    /* ── Footer ── */
    .reg-modal-footer {
      border-top: 1px solid #f3f4f6;
      padding: .9rem 1.4rem;
      display: flex; gap: .75rem; justify-content: flex-end;
      flex-shrink: 0;
      background: #fafafa;
    }
    .reg-btn-cancel {
      padding: .6rem 1.2rem; border-radius: .6rem; font-weight: 700;
      font-size: .85rem; cursor: pointer; transition: all .15s;
      background: #f3f4f6; color: #374151; border: 1.5px solid #e5e7eb;
    }
    .reg-btn-cancel:hover { background: #e5e7eb; }
    .reg-btn-export {
      padding: .6rem 1.5rem; border-radius: .6rem; font-weight: 700;
      font-size: .85rem; cursor: pointer; transition: all .15s;
      background: linear-gradient(135deg, #1B5E20 0%, #2E7D32 100%);
      color: #fff; border: none;
      display: flex; align-items: center; gap: .4rem;
      box-shadow: 0 3px 10px rgba(27,94,32,0.35);
    }
    .reg-btn-export:hover { background: linear-gradient(135deg, #15511a 0%, #245f26 100%); transform: translateY(-1px); }

    /* ── Mobile ── */
    @media (max-width: 540px) {
      .reg-scope-grid, .reg-report-grid { grid-template-columns: 1fr; }
      .reg-modal-footer { flex-direction: column-reverse; }
      .reg-btn-cancel, .reg-btn-export { width: 100%; justify-content: center; }
    }
  `;
  document.head.appendChild(style);
})();
