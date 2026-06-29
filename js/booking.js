/**
 * booking.js — v19 (Gender/Marital/Age/Vaccines + soft-warn on missing docs)
 */

function showInlineError(id, msg) {
    const el = document.getElementById(id);
    if (!el) return;
    const msgEl = el.querySelector('[data-msg]') || el;
    msgEl.textContent = msg;
    el.classList.remove('hidden');
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

// ══════════════════════════════════════════════════════
//  DOCUMENT WARNING SYSTEM
// ══════════════════════════════════════════════════════

/**
 * Run cross-checks on a single traveler block.
 * Returns array of warning strings (empty = all good).
 */
function auditTravelerDocs(block, idx, isChild) {
    const warnings = [];

    if (isChild) {
        // child block: only need birth cert (age < 18 always true for children)
        const birthInput = block.querySelector('.t-birth-cert');
        if (birthInput && !birthInput.files?.[0]) {
            warnings.push('شهادة الميلاد غير مرفقة');
        }
        return warnings;
    }

    // --- Adult block ---
    const name      = block.querySelector('.t-name')?.value?.trim() || `المسافر ${idx + 1}`;
    const gender    = block.querySelector('.t-gender')?.value;
    const marital   = block.querySelector('.t-marital')?.value;
    const ageRange  = block.querySelector('.t-age-range')?.value; // 'adult' or 'youth'

    // Required document inputs
    const nidInput      = block.querySelector('.t-nid-file');
    const passportInput = block.querySelector('.t-passport-file');
    const photoInput    = block.querySelector('.t-photo-file');
    const meningInput   = block.querySelector('.t-menin-file');
    const covidInput    = block.querySelector('.t-covid-file');
    const marriageInput = block.querySelector('.t-marriage-file');
    const birthInput    = block.querySelector('.t-birth-cert');

    if (!nidInput?.files?.[0])      warnings.push('صورة بطاقة الرقم القومي غير مرفقة');
    if (!passportInput?.files?.[0]) warnings.push('صورة جواز السفر غير مرفقة');
    if (!photoInput?.files?.[0])    warnings.push('الصورة الشخصية غير مرفقة');
    if (!meningInput?.files?.[0])   warnings.push('شهادة تطعيم الحمى الشوكية (MenACYW) غير مرفقة');
    if (!covidInput?.files?.[0])    warnings.push('شهادة تطعيم كوفيد-19 غير مرفقة');

    // Marriage contract required only for married females
    if (gender === 'female' && marital === 'married') {
        if (!marriageInput?.files?.[0]) warnings.push('عقد الزواج غير مرفق (مطلوب للمرأة المتزوجة)');
    }

    // Birth certificate required for youth (12–17)
    if (ageRange === 'youth') {
        if (!birthInput?.files?.[0]) warnings.push('شهادة الميلاد غير مرفقة (مطلوبة لمن هم دون 18 سنة)');
    }

    return warnings;
}

/**
 * Show doc-warnings banner inside a traveler block.
 * Returns total warning count across all travelers.
 */
function renderDocWarnings() {
    let totalWarnings = 0;

    document.querySelectorAll('.traveler-adult-block').forEach((block, idx) => {
        const warnings = auditTravelerDocs(block, idx, false);
        let bannerEl   = block.querySelector('.doc-warnings-banner');

        if (!bannerEl) {
            bannerEl = document.createElement('div');
            bannerEl.className = 'doc-warnings-banner';
            block.appendChild(bannerEl);
        }

        if (warnings.length) {
            totalWarnings += warnings.length;
            const name = block.querySelector('.t-name')?.value?.trim() || `المسافر ${idx + 1}`;
            bannerEl.innerHTML = `
                <div class="mt-3 bg-amber-50 border border-amber-300 rounded-lg p-3">
                  <p class="text-amber-700 font-bold text-xs mb-1">
                    <i class="fa-solid fa-triangle-exclamation ml-1"></i>
                    تحذيرات على ملف ${name}:
                  </p>
                  <ul class="text-xs text-amber-700 space-y-0.5 list-disc list-inside">
                    ${warnings.map(w => `<li>${w}</li>`).join('')}
                  </ul>
                  <p class="text-xs text-amber-500 mt-1">⚠ يمكن إكمال الحجز الآن وإرسال المستندات الناقصة لاحقاً عبر واتساب</p>
                </div>`;
        } else {
            bannerEl.innerHTML = '';
        }
    });

    document.querySelectorAll('.traveler-child-block').forEach((block, idx) => {
        const warnings = auditTravelerDocs(block, idx, true);
        let bannerEl   = block.querySelector('.doc-warnings-banner');
        if (!bannerEl) {
            bannerEl = document.createElement('div');
            bannerEl.className = 'doc-warnings-banner';
            block.appendChild(bannerEl);
        }
        if (warnings.length) {
            totalWarnings += warnings.length;
            bannerEl.innerHTML = `
                <div class="mt-3 bg-amber-50 border border-amber-300 rounded-lg p-3">
                  <p class="text-amber-700 font-bold text-xs mb-1">
                    <i class="fa-solid fa-triangle-exclamation ml-1"></i> مستندات ناقصة:
                  </p>
                  <ul class="text-xs text-amber-700 space-y-0.5 list-disc list-inside">
                    ${warnings.map(w => `<li>${w}</li>`).join('')}
                  </ul>
                </div>`;
        } else {
            bannerEl.innerHTML = '';
        }
    });

    return totalWarnings;
}

// ══════════════════════════════════════════════════════
//  TOGGLE HELPERS (gender / marital / age-range)
// ══════════════════════════════════════════════════════

function onGenderChange(block) {
    const gender  = block.querySelector('.t-gender').value;
    const marital = block.querySelector('.t-marital').value;
    toggleMarriageSection(block, gender, marital);
    renderDocWarnings();
}

function onMaritalChange(block) {
    const gender  = block.querySelector('.t-gender').value;
    const marital = block.querySelector('.t-marital').value;
    toggleMarriageSection(block, gender, marital);
    renderDocWarnings();
}

function toggleMarriageSection(block, gender, marital) {
    const section = block.querySelector('.marriage-section');
    if (!section) return;
    const show = gender === 'female' && marital === 'married';
    section.classList.toggle('hidden', !show);
}

function onAgeRangeChange(block) {
    const ageRange = block.querySelector('.t-age-range').value;
    const birthSection = block.querySelector('.birth-cert-section');
    if (birthSection) {
        birthSection.classList.toggle('hidden', ageRange !== 'youth');
    }
    renderDocWarnings();
}

// ══════════════════════════════════════════════════════
//  BOOKING CONTROLLER
// ══════════════════════════════════════════════════════

const bookingController = {
    step: 1,
    packageData: null,
    totalBasePrice: 0,
    appliedCoupon: null,
    discountAmount: 0,
    uploadedDocuments: [],

    async init() {
        const { data: { session } } = await window.db.auth.getSession();
        if (!session) { this._showAuthGate(); return; }
        this.currentUser = session.user;

        checkDraft();

        const urlParams = new URLSearchParams(window.location.search);
        const pkgId = urlParams.get('package');
        if (!pkgId) {
            showInlineError('booking-validation-error', 'الرجاء اختيار برنامج أولاً');
            window.location.href = '/packages.html';
            return;
        }

        try {
            const { data, error } = await window.db.from('packages')
                .select('id,title,category,season,departure_date,return_date,duration_nights,price_per_person,price_child,discount_percent,max_seats,available_seats,departure_city,flight_type,airline,mecca_hotel,mecca_hotel_stars,medina_hotel,medina_hotel_stars,nights_mecca,nights_medina,transport_type,includes,excludes,itinerary,images,thumbnail_url,is_active,visa_included,notes')
                .eq('id', pkgId).single();
            if (error) throw error;
            this.packageData = data;

            document.getElementById('summaryCard').style.display = 'flex';
            document.getElementById('summaryTitle').innerText = data.title;
            document.getElementById('summaryDate').innerText = 'المغادرة: ' + window.formatDate(data.departure_date);
            document.getElementById('summaryBasePrice').innerText = window.formatCurrency(data.price_per_person) + ' / للفرد';

            if (window.trackEvent) window.trackEvent('booking_start', { package_id: data.id, package_title: data.title });

            if (!data.price_child) {
                document.getElementById('childPriceNotice').innerText = 'سعر الطفل غير متاح لهذا البرنامج؛ يُحسب كفرد بالغ.';
            } else {
                document.getElementById('childPriceNotice').innerText = `سعر الطفل: ${window.formatCurrency(data.price_child)}`;
            }

            this.updatePricing();
            document.getElementById('adultsCount').addEventListener('input', () => this.updatePricing());
            document.getElementById('childrenCount').addEventListener('input', () => this.updatePricing());

        } catch(err) {
            console.error(err);
            showInlineError('booking-validation-error', 'خطأ في استرجاع بيانات البرنامج');
        }
    },

    updatePricing() {
        const adults   = parseInt(document.getElementById('adultsCount').value) || 1;
        const children = parseInt(document.getElementById('childrenCount').value) || 0;
        const priceAdult = this.packageData.price_per_person;
        const priceChild = this.packageData.price_child || priceAdult;

        const adultsTotal   = adults * priceAdult;
        const childrenTotal = children * priceChild;
        this.totalBasePrice = adultsTotal + childrenTotal;

        document.getElementById('calcAdultsText').innerText   = `${adults} بالغ`;
        document.getElementById('calcAdultsTotal').innerText  = window.formatCurrency(adultsTotal);
        document.getElementById('calcChildrenText').innerText = `${children} طفل`;
        document.getElementById('calcChildrenTotal').innerText= window.formatCurrency(childrenTotal);

        if (this.appliedCoupon && this.packageData.discount_percent) {
            this.discountAmount = (this.totalBasePrice * this.packageData.discount_percent) / 100;
            document.getElementById('discountPercentText').innerText = this.packageData.discount_percent;
            document.getElementById('calcDiscountTotal').innerText   = '-' + window.formatCurrency(this.discountAmount);
            document.getElementById('discountRow').classList.remove('hidden');
        } else {
            this.discountAmount = 0;
            document.getElementById('discountRow')?.classList.add('hidden');
        }

        const finalTotal = this.totalBasePrice - this.discountAmount;
        document.getElementById('calcGrandTotal').innerText = window.formatCurrency(finalTotal);
    },

    async applyCoupon() {
        const inputStr = document.getElementById('couponCode').value.trim();
        const msgEl    = document.getElementById('couponMsg');
        if (!inputStr) return;

        msgEl.innerText   = '...جاري التحقق';
        msgEl.className   = 'text-sm -mt-6 mb-6 px-4 text-gray-400 block';

        const { data, error } = await supabase.rpc('validate_coupon', {
            p_package_id: this.packageData.id, p_code: inputStr.toUpperCase()
        });

        if (error || !data?.valid) {
            this.appliedCoupon  = null;
            this.couponDiscount = 0;
            msgEl.innerText  = 'الكود غير صحيح أو لا ينطبق على هذا البرنامج';
            msgEl.className  = 'text-sm -mt-6 mb-6 px-4 text-red-600 block';
        } else {
            this.appliedCoupon  = inputStr;
            this.couponDiscount = data.discount ?? this.packageData.coupon_discount ?? 0;
            msgEl.innerText  = 'تم تطبيق كود الخصم بنجاح';
            msgEl.className  = 'text-sm -mt-6 mb-6 px-4 text-green-600 block';
        }
        this.updatePricing();
    },

    nextStep() {
        if (this.step === 1) this.buildTravelersForm();
        if (this.step < 3) {
            document.getElementById(`step${this.step}`).classList.add('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.remove('text-primary');
            this.step++;
            document.getElementById(`step${this.step}`).classList.remove('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.add('text-primary');
            document.getElementById('progressBar').style.width = (this.step * 33) + '%';
            if (this.step === 3) this.buildConfirmStep();
            if (window.trackEvent) window.trackEvent('booking_step', {
                package_id: this.packageData?.id, package_title: this.packageData?.title, step_number: this.step
            });
        }
    },

    prevStep() {
        if (this.step > 1) {
            document.getElementById(`step${this.step}`).classList.add('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.remove('text-primary');
            this.step--;
            document.getElementById(`step${this.step}`).classList.remove('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.add('text-primary');
            document.getElementById('progressBar').style.width = (this.step * 33) + '%';
        }
    },

    // ── Build step 2: travelers form ──────────────────────
    buildTravelersForm() {
        const adults   = parseInt(document.getElementById('adultsCount').value) || 1;
        const children = parseInt(document.getElementById('childrenCount').value) || 0;
        const container= document.getElementById('travelersFormContainer');
        container.innerHTML = '';

        for (let i = 1; i <= adults; i++) {
            const idx = i - 1;
            const div = document.createElement('div');
            div.className = 'border border-gray-200 p-4 rounded-lg traveler-adult-block bg-white';
            div.innerHTML = `
              <h4 class="font-bold mb-3 border-b pb-2">
                <span class="bg-gray-200 text-gray-700 px-2 py-0.5 rounded text-sm ml-2">بالغ ${i}</span>
              </h4>

              <!-- Basic info -->
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <input type="text" class="t-name border p-2 rounded w-full" placeholder="الاسم الرباعي (مطلوب)" required>
                <input type="text" inputmode="numeric" pattern="[0-9]{14}" class="t-nid border p-2 rounded w-full"
                       placeholder="الرقم القومي (14 رقم)" required maxlength="14"
                       oninput="this.value=this.value.replace(/[^0-9]/g,'')">
                <input type="text" inputmode="numeric" class="t-passport border p-2 rounded w-full"
                       placeholder="رقم جواز السفر" required
                       oninput="this.value=this.value.replace(/[^A-Za-z0-9]/g,'').toUpperCase()">
                <div class="field-wrap col-span-1">
                  <label class="block text-xs text-gray-500 mb-1 font-medium">
                    تاريخ انتهاء جواز السفر <span class="text-red-500">*</span>
                  </label>
                  <input type="date" class="t-passport-exp border p-2 rounded w-full text-gray-600">
                  <p class="text-xs text-amber-600 mt-1">
                    <i class="fa-solid fa-triangle-exclamation ml-1"></i>
                    يجب أن يكون الجواز صالحاً 6 أشهر على الأقل بعد تاريخ المغادرة
                  </p>
                </div>
              </div>

              <!-- Nationality + Place of Birth + Date of Birth (Nusuk/Ministry required) -->
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-flag ml-1 text-sky-500"></i>الجنسية <span class="text-red-500">*</span>
                  </label>
                  <input type="text" class="t-nationality border p-2 rounded w-full text-sm"
                         placeholder="مصري / Egyptian" required value="مصري">
                </div>
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-location-dot ml-1 text-orange-500"></i>محل الميلاد <span class="text-red-500">*</span>
                  </label>
                  <input type="text" class="t-place-of-birth border p-2 rounded w-full text-sm"
                         placeholder="القاهرة" required>
                </div>
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-cake-candles ml-1 text-pink-500"></i>تاريخ الميلاد <span class="text-red-500">*</span>
                  </label>
                  <input type="date" class="t-dob border p-2 rounded w-full text-sm text-gray-600">
                </div>
              </div>

              <!-- Gender + Marital Status (adults only) -->
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4 bg-blue-50 border border-blue-200 rounded-lg p-3">
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-venus-mars ml-1 text-blue-500"></i>الجنس <span class="text-red-500">*</span>
                  </label>
                  <select class="t-gender border p-2 rounded w-full text-sm"
                          onchange="onGenderChange(this.closest('.traveler-adult-block'))">
                    <option value="">— اختر —</option>
                    <option value="male">ذكر</option>
                    <option value="female">أنثى</option>
                  </select>
                </div>
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-ring ml-1 text-pink-500"></i>الحالة الاجتماعية <span class="text-red-500">*</span>
                  </label>
                  <select class="t-marital border p-2 rounded w-full text-sm"
                          onchange="onMaritalChange(this.closest('.traveler-adult-block'))">
                    <option value="">— اختر —</option>
                    <option value="single">أعزب / عزباء</option>
                    <option value="married">متزوج / متزوجة</option>
                    <option value="divorced">مطلق / مطلقة</option>
                    <option value="widowed">أرمل / أرملة</option>
                  </select>
                </div>
                <div>
                  <label class="block text-xs font-bold text-gray-600 mb-1">
                    <i class="fa-solid fa-calendar-days ml-1 text-green-600"></i>الفئة العمرية
                  </label>
                  <select class="t-age-range border p-2 rounded w-full text-sm"
                          onchange="onAgeRangeChange(this.closest('.traveler-adult-block'))">
                    <option value="adult">بالغ (18+ سنة)</option>
                    <option value="youth">شاب (12–17 سنة)</option>
                  </select>
                </div>
              </div>

              <!-- Documents section -->
              <div class="mt-4 pt-4 border-t border-dashed border-gray-200">
                <p class="text-xs font-semibold text-gray-700 mb-3">
                  <i class="fa-solid fa-file-arrow-up ml-1 text-primary"></i>
                  المستندات المطلوبة
                  <span class="text-gray-400 font-normal">(مطلوبة لإتمام الحجز — يمكن الإرسال لاحقاً عبر واتساب)</span>
                </p>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">

                  <!-- National ID -->
                  <div>
                    <label class="block text-xs text-gray-600 mb-1 font-medium">
                      <i class="fa-solid fa-id-card ml-1 text-amber-600"></i>
                      بطاقة الرقم القومي <span class="text-red-500">*</span>
                    </label>
                    <input type="file" class="t-nid-file text-sm bg-white border border-gray-300 rounded w-full p-1 ocr-nid-input"
                           data-traveler="" data-doctype="national_id" data-traveler-idx="${idx}"
                           accept="image/jpeg,image/png,application/pdf"
                           onchange="renderDocWarnings()">
                    <div id="ocr_nid_status_${idx}" class="ocr-status mt-1 hidden"></div>
                  </div>

                  <!-- Passport -->
                  <div>
                    <label class="block text-xs text-gray-600 mb-1 font-medium">
                      <i class="fa-solid fa-passport ml-1 text-primary"></i>
                      جواز السفر <span class="text-red-500">*</span>
                    </label>
                    <input type="file" class="t-passport-file text-sm bg-white border border-gray-300 rounded w-full p-1 ocr-passport-input"
                           data-traveler="" data-doctype="passport" data-traveler-idx="${idx}"
                           accept="image/jpeg,image/png,application/pdf"
                           onchange="renderDocWarnings()">
                    <div id="ocr_passport_status_${idx}" class="ocr-status mt-1 hidden"></div>
                  </div>

                  <!-- Personal photo -->
                  <div>
                    <label class="block text-xs text-gray-600 mb-1 font-medium">
                      <i class="fa-solid fa-camera ml-1 text-rose-500"></i>
                      الصورة الشخصية (6×4 خلفية بيضاء) <span class="text-red-500">*</span>
                    </label>
                    <p class="text-xs text-blue-600 mb-1">
                      <i class="fa-solid fa-circle-info ml-1"></i>خلفية بيضاء، حديثة، واضحة الوجه
                    </p>
                    <input type="file" class="t-photo-file text-sm bg-white border border-gray-300 rounded w-full p-1"
                           data-traveler="" data-doctype="personal_photo"
                           accept="image/jpeg,image/png"
                           onchange="renderDocWarnings()">
                  </div>

                  <!-- Meningitis vaccine -->
                  <div>
                    <label class="block text-xs text-gray-600 mb-1 font-medium">
                      <i class="fa-solid fa-syringe ml-1 text-purple-600"></i>
                      تطعيم الحمى الشوكية (MenACYW) <span class="text-red-500">*</span>
                    </label>
                    <p class="text-xs text-purple-600 mb-1">شهادة تطعيم سارية المفعول — مطلب سعودي</p>
                    <input type="file" class="t-menin-file text-sm bg-white border border-gray-300 rounded w-full p-1"
                           data-traveler="" data-doctype="vaccination_meningitis"
                           accept="image/jpeg,image/png,application/pdf"
                           onchange="renderDocWarnings()">
                    <label class="flex items-center gap-2 mt-1.5 cursor-pointer select-none">
                      <input type="checkbox" class="t-menin-confirmed w-4 h-4 accent-purple-600">
                      <span class="text-xs text-purple-700 font-semibold">✓ تأكيد استلام تطعيم الحمى الشوكية الرباعي (MenACYW)</span>
                    </label>
                  </div>

                  <!-- COVID-19 vaccine -->
                  <div>
                    <label class="block text-xs text-gray-600 mb-1 font-medium">
                      <i class="fa-solid fa-shield-virus ml-1 text-teal-600"></i>
                      تطعيم كوفيد-19 <span class="text-red-500">*</span>
                    </label>
                    <input type="file" class="t-covid-file text-sm bg-white border border-gray-300 rounded w-full p-1"
                           data-traveler="" data-doctype="vaccination_covid"
                           accept="image/jpeg,image/png,application/pdf"
                           onchange="renderDocWarnings()">
                  </div>

                  <!-- Marriage contract — conditional (married female only) -->
                  <div class="marriage-section hidden md:col-span-2">
                    <div class="bg-pink-50 border border-pink-200 rounded-lg p-3">
                      <label class="block text-xs text-gray-600 mb-1 font-bold">
                        <i class="fa-solid fa-file-contract ml-1 text-pink-600"></i>
                        عقد الزواج <span class="text-red-500">*</span>
                        <span class="text-pink-500 font-normal">(مطلوب للمرأة المتزوجة)</span>
                      </label>
                      <input type="file" class="t-marriage-file text-sm bg-white border border-pink-300 rounded w-full p-1"
                             data-traveler="" data-doctype="marriage_contract"
                             accept="image/jpeg,image/png,application/pdf"
                             onchange="renderDocWarnings()">
                    </div>
                  </div>

                  <!-- Birth certificate — conditional (youth 12–17) -->
                  <div class="birth-cert-section hidden md:col-span-2">
                    <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
                      <label class="block text-xs text-gray-600 mb-1 font-bold">
                        <i class="fa-solid fa-baby ml-1 text-yellow-600"></i>
                        شهادة الميلاد <span class="text-red-500">*</span>
                        <span class="text-yellow-600 font-normal">(مطلوبة لمن هم دون 18 سنة)</span>
                      </label>
                      <input type="file" class="t-birth-cert text-sm bg-white border border-yellow-300 rounded w-full p-1"
                             data-traveler="" data-doctype="birth_certificate"
                             accept="image/jpeg,image/png,application/pdf"
                             onchange="renderDocWarnings()">
                    </div>
                  </div>

                </div>
                <div class="doc-warnings-banner"></div>
                <div id="ocr_cross_${idx}" class="hidden"></div>
              </div>
            `;
            container.appendChild(div);
        }

        // Child blocks
        for (let i = 1; i <= children; i++) {
            const div = document.createElement('div');
            div.className = 'border border-gray-200 p-4 rounded-lg traveler-child-block bg-white';
            div.innerHTML = `
              <h4 class="font-bold mb-3 border-b pb-2">
                <span class="bg-blue-100 text-blue-700 px-2 py-0.5 rounded text-sm ml-2">طفل ${i}</span>
                <span class="text-xs text-gray-400 font-normal">— أقل من 12 سنة</span>
              </h4>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <input type="text" class="t-name border p-2 rounded w-full" placeholder="الاسم الرباعي (مطلوب)" required>
                <input type="number" class="t-age border p-2 rounded w-full" placeholder="العمر" required min="1" max="11">
              </div>
              <div>
                <label class="block text-xs text-gray-600 mb-1 font-medium">
                  <i class="fa-solid fa-baby ml-1 text-yellow-600"></i>
                  شهادة الميلاد <span class="text-red-500">*</span>
                </label>
                <input type="file" class="t-birth-cert text-sm bg-white border border-gray-300 rounded w-full p-1"
                       data-traveler="" data-doctype="birth_certificate"
                       accept="image/jpeg,image/png,application/pdf"
                       onchange="renderDocWarnings()">
                <div class="doc-warnings-banner"></div>
              </div>
            `;
            container.appendChild(div);
        }

        // Attach passport-expiry live validation
        document.querySelectorAll('.traveler-adult-block .t-passport-exp').forEach(inp => {
            inp.addEventListener('change', () => this.validatePassportExpiry(inp));
        });

        // Initial warn render
        renderDocWarnings();
    },

    // ── Build confirm step (step 3) ──
    buildConfirmStep() {
        const totalWarnings = renderDocWarnings();
        const warnBanner    = document.getElementById('confirm-doc-warnings');
        if (warnBanner) {
            if (totalWarnings > 0) {
                warnBanner.innerHTML = `
                  <div class="bg-amber-50 border-2 border-amber-400 rounded-xl p-4 mb-4">
                    <p class="text-amber-700 font-bold text-sm mb-1">
                      <i class="fa-solid fa-triangle-exclamation ml-2 text-lg"></i>
                      تنبيه: يوجد ${totalWarnings} مستند ناقص
                    </p>
                    <p class="text-amber-600 text-xs">
                      يمكنك إتمام الحجز الآن وإرسال المستندات الناقصة لاحقاً عبر واتساب.
                      سيتم تنبيه الإدارة بالمستندات المفقودة تلقائياً.
                    </p>
                  </div>`;
                warnBanner.classList.remove('hidden');
            } else {
                warnBanner.innerHTML = '';
                warnBanner.classList.add('hidden');
            }
        }
    },

    // ── Passport expiry validation ──
    _passportMinExpiry(departureDateStr) {
        const d = new Date(departureDateStr);
        d.setMonth(d.getMonth() + 6);
        return d;
    },
    _passportWarningEl(input) {
        let el = input.closest('.field-wrap')?.querySelector('.passport-warning');
        if (!el) {
            el = document.createElement('div');
            el.className = 'passport-warning';
            input.parentNode.insertBefore(el, input.nextSibling);
        }
        return el;
    },
    validatePassportExpiry(input) {
        const val       = input.value;
        const departure = this.packageData?.departure_date;
        const warningEl = this._passportWarningEl(input);
        if (!val || !departure) { warningEl.innerHTML = ''; return true; }
        const expiry    = new Date(val);
        const now       = new Date(); now.setHours(0,0,0,0);
        const minExpiry = this._passportMinExpiry(departure);
        const fmt = d => d.toLocaleDateString('ar-EG', { year:'numeric', month:'long', day:'numeric' });
        const ERR = (msg) => {
            warningEl.innerHTML = `<div style="background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:10px 14px;margin-top:6px;font-size:13px;font-weight:700;color:#dc2626;display:flex;align-items:flex-start;gap:8px;"><i class="fa-solid fa-circle-exclamation" style="margin-top:2px;flex-shrink:0;"></i><span>${msg}</span></div>`;
            input.style.borderColor = '#fca5a5';
            return false;
        };
        const OK = () => {
            warningEl.innerHTML = `<div style="background:#f0fdf4;border:1px solid #86efac;border-radius:8px;padding:8px 14px;margin-top:6px;font-size:12px;font-weight:700;color:#16a34a;display:flex;align-items:center;gap:6px;"><i class="fa-solid fa-circle-check"></i> الجواز صالح للسفر ✓</div>`;
            input.style.borderColor = '#86efac';
            return true;
        };
        if (expiry < now)       return ERR('⛔ جواز السفر منتهي الصلاحية، يرجى تجديده قبل الحجز');
        if (expiry < minExpiry) return ERR(`⚠️ الجواز يجب أن يكون صالحاً 6 أشهر بعد المغادرة (اشتراط سعودي). الحد الأدنى: ${fmt(minExpiry)}`);
        return OK();
    },
    validateAllPassports() {
        const inputs = Array.from(document.querySelectorAll('.t-passport-exp'));
        const hasValue = inputs.filter(i => i.value);
        if (hasValue.length === 0) return true;
        return hasValue.every(i => this.validatePassportExpiry(i));
    },

    // ── Step 2 → 3 validation ──
    validateAndNext() {
        const phone = document.getElementById('contactPhone').value;
        if (!phone || phone.length < 8) {
            showInlineError('booking-validation-error', 'يرجى إدخال رقم هاتف صحيح للتواصل');
            return;
        }

        // Validate required text inputs
        const inputs = Array.from(document.querySelectorAll('.traveler-adult-block input[required], .traveler-child-block input[required]'));
        const isValid = inputs.every(i => i.value.trim() !== '');
        if (!isValid) {
            showInlineError('booking-validation-error', 'يرجى ملء كافة الحقول الإلزامية للمسافرين.');
            return;
        }

        // Validate gender and marital for adults
        let missingSelects = false;
        document.querySelectorAll('.traveler-adult-block').forEach(block => {
            const g = block.querySelector('.t-gender')?.value;
            const m = block.querySelector('.t-marital')?.value;
            if (!g || !m) missingSelects = true;
        });
        if (missingSelects) {
            showInlineError('booking-validation-error', 'يرجى تحديد الجنس والحالة الاجتماعية لكل مسافر بالغ.');
            return;
        }

        if (!this.validateAllPassports()) {
            const first = document.querySelector('.t-passport-exp[style*="fca5a5"]') ||
                          document.querySelector('.passport-warning div');
            first?.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return;
        }

        this.nextStep();
    },

    // ── Upload document ──
    async uploadDocument(fileObj, travelerName, docType) {
        if (!fileObj) return null;
        try {
            let file = fileObj;
            const isImage = fileObj.type.startsWith('image/');
            if (isImage && typeof imageCompression !== 'undefined') {
                try {
                    const compressed = await imageCompression(fileObj, {
                        maxSizeMB: 0.5, maxWidthOrHeight: 1400, useWebWorker: true,
                        fileType: 'image/jpeg', initialQuality: 0.82
                    });
                    file = new File([compressed], fileObj.name.replace(/\.[^.]+$/, '.jpg'), { type: 'image/jpeg' });
                } catch(e) { console.warn('Compression skipped:', e); }
            }
            const ext      = file.name.split('.').pop();
            const fileName = `${Date.now()}_${Math.random().toString(36).substring(7)}.${ext}`;
            const userId   = this.currentUser?.id || 'anon';
            const filePath = `passports/${userId}/${fileName}`;
            const { data, error } = await window.db.storage.from('booking-documents').upload(filePath, file);
            if (error) throw error;
            return {
                type: docType || 'passport',
                traveler_name: travelerName,
                path: filePath,
                url: null,
                uploaded_at: new Date().toISOString()
            };
        } catch(err) {
            console.error('Upload skipped:', err);
            return null;
        }
    },

    // ── Submit ──
    async submitBooking() {
        if (!this.validateAllPassports()) {
            const first = document.querySelector('.passport-warning div');
            first?.scrollIntoView({ behavior: 'smooth', block: 'center' });
            showInlineError('booking-validation-error', 'يوجد جواز سفر غير صالح للسفر.');
            return;
        }

        const recaptchaToken = grecaptcha.getResponse();
        if (!recaptchaToken) {
            showInlineError('booking-validation-error', 'يرجى التحقق من أنك لست روبوتاً');
            return;
        }

        const btn = document.getElementById('finalSubmitBtn');
        btn.innerHTML = '<div class="loader mx-auto" style="width:24px;height:24px;border-width:3px;"></div>';
        btn.disabled  = true;

        try {
            // reCAPTCHA server verify
            try {
                const { data: captchaData, error: captchaError } = await window.db.functions.invoke('verify-recaptcha', { body: { token: recaptchaToken } });
                if (captchaError || !captchaData?.success) {
                    showInlineError('booking-validation-error', 'فشل التحقق من reCAPTCHA.');
                    btn.innerHTML = 'تأكيد طلب الحجز'; btn.disabled = false;
                    grecaptcha.reset(); return;
                }
            } catch(e) { console.warn('reCAPTCHA server verify unavailable:', e); }

            // 1. Collect doc warnings for payload
            const docWarningsList = [];
            document.querySelectorAll('.traveler-adult-block').forEach((block, idx) => {
                const ws = auditTravelerDocs(block, idx, false);
                const name = block.querySelector('.t-name')?.value?.trim() || `بالغ ${idx+1}`;
                ws.forEach(w => docWarningsList.push(`${name}: ${w}`));
            });
            document.querySelectorAll('.traveler-child-block').forEach((block, idx) => {
                const ws = auditTravelerDocs(block, idx, true);
                const name = block.querySelector('.t-name')?.value?.trim() || `طفل ${idx+1}`;
                ws.forEach(w => docWarningsList.push(`${name}: ${w}`));
            });

            // 2. Upload all files
            let uploadedDocs = [];
            // Adult blocks — all named file inputs
            const docInputClasses = [
                { cls: '.t-nid-file',      type: 'national_id' },
                { cls: '.t-passport-file', type: 'passport' },
                { cls: '.t-photo-file',    type: 'personal_photo' },
                { cls: '.t-menin-file',    type: 'vaccination_meningitis' },
                { cls: '.t-covid-file',    type: 'vaccination_covid' },
                { cls: '.t-marriage-file', type: 'marriage_contract' },
                { cls: '.t-birth-cert',    type: 'birth_certificate' },
            ];

            for (const block of document.querySelectorAll('.traveler-adult-block, .traveler-child-block')) {
                const name = block.querySelector('.t-name')?.value?.trim() || '';
                for (const { cls, type } of docInputClasses) {
                    const inp = block.querySelector(cls);
                    if (inp?.files?.[0]) {
                        const rec = await this.uploadDocument(inp.files[0], name, type);
                        if (rec) uploadedDocs.push(rec);
                    }
                }
            }

            // 3. Gather traveler data
            const travelers = [];
            document.querySelectorAll('.traveler-adult-block').forEach(blk => {
                travelers.push({
                    type:                    'adult',
                    name:                    blk.querySelector('.t-name').value,
                    national_id:             blk.querySelector('.t-nid').value,
                    passport:                blk.querySelector('.t-passport').value,
                    passport_expiry:         blk.querySelector('.t-passport-exp').value,
                    gender:                  blk.querySelector('.t-gender')?.value || '',
                    marital_status:          blk.querySelector('.t-marital')?.value || '',
                    age_range:               blk.querySelector('.t-age-range')?.value || 'adult',
                    nationality:             blk.querySelector('.t-nationality')?.value || 'مصري',
                    place_of_birth:          blk.querySelector('.t-place-of-birth')?.value || '',
                    date_of_birth:           blk.querySelector('.t-dob')?.value || '',
                    vaccination_meningitis:  blk.querySelector('.t-menin-confirmed')?.checked ? true : false,
                });
            });
            document.querySelectorAll('.traveler-child-block').forEach(blk => {
                travelers.push({
                    type: 'child',
                    name: blk.querySelector('.t-name').value,
                    age:  parseInt(blk.querySelector('.t-age').value)
                });
            });

            // 4. Build payload
            const finalTotal = this.totalBasePrice - this.discountAmount;
            const payload = {
                package_id:              this.packageData.id,
                package_title:           this.packageData.title,
                package_departure:       this.packageData.departure_date,
                customer_name:           travelers[0]?.name || 'غير محدد',
                customer_phone:          document.getElementById('contactPhone').value,
                customer_email:          document.getElementById('contactEmail').value,
                customer_national_id:    travelers[0]?.national_id,
                customer_passport_number:travelers[0]?.passport,
                adults_count:            parseInt(document.getElementById('adultsCount').value) || 1,
                children_count:          parseInt(document.getElementById('childrenCount').value) || 0,
                travelers,
                total_price:             finalTotal,
                remaining_amount:        finalTotal,
                coupon_code:             this.appliedCoupon,
                discount_amount:         this.discountAmount,
                documents:               uploadedDocs,
                doc_warnings:            docWarningsList,  // stored in DB for admin
                special_requests:        document.getElementById('specialRequests').value,
                user_id:                 this.currentUser?.id || null
            };

            // 5. Insert
            const { data, error } = await window.db.from('bookings').insert(payload).select().single();
            if (error) throw error;

            document.getElementById('successBookingNumber').innerText = data.booking_number;
            document.getElementById('successModal').classList.remove('hidden');
            localStorage.removeItem(DRAFT_KEY);
            window.onbeforeunload = null;

            if (window.trackEvent) window.trackEvent('booking_complete', {
                package_id: this.packageData?.id, package_title: this.packageData?.title
            });

            document.getElementById('goToTrackingBtn').onclick = () => {
                window.location.href = `/tracking.html?booking=${data.booking_number}`;
            };
            this.sendWhatsApp(data, docWarningsList);

        } catch(err) {
            console.error('Booking Error:', err);
            const errCard = document.getElementById('booking-submit-error');
            const errMsg  = document.getElementById('booking-submit-error-msg');
            if (errCard && errMsg) {
                errMsg.textContent = err?.message || 'حدث خطأ أثناء إرسال طلب الحجز. يرجى المحاولة لاحقاً.';
                errCard.classList.remove('hidden');
                errCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
            btn.innerHTML = 'تأكيد طلب الحجز';
            btn.disabled  = false;
            grecaptcha.reset();
        }
    },

    sendWhatsApp(bookingRow, docWarnings = []) {
        const warningsText = docWarnings.length
            ? `\n⚠️ *مستندات ناقصة (${docWarnings.length}):*\n${docWarnings.map(w => `• ${w}`).join('\n')}`
            : '\n✅ جميع المستندات مرفقة';

        const msg =
`🕌 *طلب حجز جديد — نيو سي برنسيس*

📋 *رقم الحجز:* ${bookingRow.booking_number}
📦 *البرنامج:* ${bookingRow.package_title}
📅 *المغادرة:* ${window.formatDate(bookingRow.package_departure)}
👤 *العميل:* ${bookingRow.customer_name}
📞 *هاتف:* ${bookingRow.customer_phone}
👥 *الأفراد:* ${bookingRow.adults_count} بالغ | ${bookingRow.children_count} طفل
💰 *الإجمالي:* ${window.formatCurrency(bookingRow.total_price)}
📎 *المستندات:* ${bookingRow.documents.length} ملف${warningsText}`;

        const encoded = encodeURIComponent(msg);
        window.open(`https://wa.me/201031777295?text=${encoded}`, '_blank');
    },

    // ── Auth gate ──
    _showAuthGate() {
        const gate = document.createElement('div');
        gate.id = 'authGate';
        gate.style.cssText = `position:fixed;inset:0;z-index:9999;background:linear-gradient(155deg,#0D1B0E 0%,#132415 60%,#0A150B 100%);display:flex;align-items:center;justify-content:center;padding:20px;font-family:'Cairo',sans-serif;`;
        const pkg       = new URLSearchParams(window.location.search).get('package') || '';
        const returnUrl = encodeURIComponent('/booking.html?package=' + pkg);
        gate.innerHTML = `
            <div style="background:rgba(255,255,255,.96);border-radius:20px;padding:44px 36px;max-width:440px;width:100%;text-align:center;box-shadow:0 24px 64px rgba(0,0,0,.5);">
                <div style="width:72px;height:72px;background:linear-gradient(135deg,#1B5E20,#2E7D32);border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 auto 20px;box-shadow:0 8px 24px rgba(27,94,32,.35);">
                    <i class="fa-solid fa-lock" style="font-size:28px;color:#fff;"></i>
                </div>
                <h2 style="font-size:22px;font-weight:900;color:#0D1B0E;margin-bottom:8px;">تسجيل الدخول مطلوب</h2>
                <p style="font-size:14px;color:#6b7280;line-height:1.7;margin-bottom:28px;">
                    لحجز هذا البرنامج يجب أن تكون مسجلاً في الموقع.
                </p>
                <a href="/login.html?next=${returnUrl}"
                   style="display:flex;align-items:center;justify-content:center;gap:8px;background:linear-gradient(135deg,#B8860B,#9a7209);color:#fff;padding:14px;border-radius:10px;font-weight:800;font-size:15px;text-decoration:none;margin-bottom:12px;box-shadow:0 4px 18px rgba(184,134,11,.4);">
                    <i class="fa-solid fa-right-to-bracket"></i> تسجيل الدخول
                </a>
                <a href="/login.html?tab=register&next=${returnUrl}"
                   style="display:flex;align-items:center;justify-content:center;gap:8px;background:transparent;color:#1B5E20;padding:13px;border-radius:10px;font-weight:700;font-size:14px;text-decoration:none;border:1.5px solid #1B5E20;margin-bottom:20px;">
                    <i class="fa-solid fa-user-plus"></i> إنشاء حساب جديد مجاناً
                </a>
                <a href="javascript:history.back()" style="font-size:12px;color:#9ca3af;font-weight:700;text-decoration:none;display:inline-flex;align-items:center;gap:5px;">
                    <i class="fa-solid fa-arrow-right"></i> العودة للبرنامج
                </a>
            </div>`;
        document.body.appendChild(gate);
        const main = document.querySelector('main') || document.querySelector('.container');
        if (main) main.style.filter = 'blur(4px)';
    }
};


// ═══════════════════════════════════════════════════════════════
//  DRAFT SAVE / RESTORE
// ═══════════════════════════════════════════════════════════════
const DRAFT_KEY = 'nsp_booking_draft';

function collectTravelersPartial() {
    const adults = Array.from(document.querySelectorAll('.traveler-adult-block')).map(blk => ({
        name:                   blk.querySelector('.t-name')?.value         || '',
        national_id:            blk.querySelector('.t-nid')?.value          || '',
        passport:               blk.querySelector('.t-passport')?.value     || '',
        passport_expiry:        blk.querySelector('.t-passport-exp')?.value || '',
        gender:                 blk.querySelector('.t-gender')?.value       || '',
        marital_status:         blk.querySelector('.t-marital')?.value      || '',
        age_range:              blk.querySelector('.t-age-range')?.value    || 'adult',
        nationality:            blk.querySelector('.t-nationality')?.value  || 'مصري',
        place_of_birth:         blk.querySelector('.t-place-of-birth')?.value || '',
        date_of_birth:          blk.querySelector('.t-dob')?.value          || '',
        vaccination_meningitis: blk.querySelector('.t-menin-confirmed')?.checked || false,
    }));
    const children = Array.from(document.querySelectorAll('.traveler-child-block')).map(blk => ({
        name: blk.querySelector('.t-name')?.value || '',
        age:  blk.querySelector('.t-age')?.value  || ''
    }));
    return { adults, children };
}

function saveDraft() {
    const pkgId = new URLSearchParams(location.search).get('package');
    if (!pkgId) return;
    try {
        const draft = {
            packageId:    pkgId,
            savedAt:      new Date().toISOString(),
            step:         bookingController.step || 1,
            contactPhone: document.getElementById('contactPhone')?.value   || '',
            contactEmail: document.getElementById('contactEmail')?.value   || '',
            adults:       document.getElementById('adultsCount')?.value    || '1',
            children:     document.getElementById('childrenCount')?.value  || '0',
            notes:        document.getElementById('specialRequests')?.value|| '',
            travelers:    collectTravelersPartial()
        };
        localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
    } catch(e) { /* silent */ }
}

function formatRelativeTime(isoStr) {
    const diff = Math.floor((Date.now() - new Date(isoStr)) / 60000);
    if (diff < 1)  return 'الآن';
    if (diff < 60) return `منذ ${diff} دقيقة`;
    const hrs = Math.floor(diff / 60);
    if (hrs < 24)  return `منذ ${hrs} ساعة`;
    return `منذ ${Math.floor(hrs/24)} يوم`;
}

function showDraftBanner(savedAt) {
    const existing = document.getElementById('draftBanner');
    if (existing) existing.remove();
    const banner = document.createElement('div');
    banner.id = 'draftBanner';
    banner.style.cssText = 'position:fixed;top:64px;left:0;right:0;z-index:40;padding:0 16px;animation:slideDownBanner .35s cubic-bezier(.4,0,.2,1);';
    banner.innerHTML = `
        <style>@keyframes slideDownBanner{from{opacity:0;transform:translateY(-12px)}to{opacity:1;transform:translateY(0)}}</style>
        <div style="max-width:900px;margin:0 auto;background:linear-gradient(135deg,#0D1B0E 0%,#132816 100%);border:1px solid rgba(184,134,11,.45);border-top:none;border-radius:0 0 16px 16px;padding:14px 20px;display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;box-shadow:0 8px 24px rgba(0,0,0,.35);direction:rtl;">
            <div style="display:flex;align-items:center;gap:12px;">
                <div style="width:40px;height:40px;background:rgba(184,134,11,.15);border:1px solid rgba(184,134,11,.4);border-radius:50%;display:flex;align-items:center;justify-content:center;flex-shrink:0;">
                    <i class="fa-solid fa-rotate-right" style="color:#DAA520;font-size:15px;"></i>
                </div>
                <div>
                    <p style="font-weight:800;color:#F8F5EC;font-size:14px;margin:0 0 3px;font-family:'Cairo',sans-serif;">لديك حجز غير مكتمل</p>
                    <p style="font-size:12px;color:rgba(184,134,11,.8);margin:0;font-family:'Cairo',sans-serif;">
                        <i class="fa-regular fa-clock" style="margin-left:4px;"></i>آخر حفظ: ${formatRelativeTime(savedAt)}
                    </p>
                </div>
            </div>
            <div style="display:flex;gap:8px;align-items:center;flex-shrink:0;">
                <button onclick="restoreDraft()" style="background:linear-gradient(135deg,#B8860B,#DAA520);color:#0D1B0E;padding:9px 20px;border-radius:8px;font-weight:800;font-size:13px;border:none;cursor:pointer;font-family:'Cairo',sans-serif;">
                    <i class="fa-solid fa-arrow-left ml-1" style="font-size:11px;"></i> اكمل حجزك
                </button>
                <button onclick="discardDraft()" style="background:rgba(255,255,255,.06);color:rgba(255,255,255,.5);padding:9px 14px;border:1px solid rgba(255,255,255,.1);border-radius:8px;cursor:pointer;font-size:12px;font-family:'Cairo',sans-serif;">
                    تجاهل
                </button>
            </div>
        </div>`;
    document.body.appendChild(banner);
}

function restoreDraft() {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return;
    try {
        const draft = JSON.parse(raw);
        const phone = document.getElementById('contactPhone');
        const email = document.getElementById('contactEmail');
        const notes = document.getElementById('specialRequests');
        if (phone && draft.contactPhone) phone.value = draft.contactPhone;
        if (email && draft.contactEmail) email.value = draft.contactEmail;
        if (notes && draft.notes)        notes.value = draft.notes;

        const adultsEl   = document.getElementById('adultsCount');
        const childrenEl = document.getElementById('childrenCount');
        if (adultsEl   && draft.adults)   { adultsEl.value   = draft.adults;   adultsEl.dispatchEvent(new Event('input')); }
        if (childrenEl && draft.children) { childrenEl.value = draft.children; childrenEl.dispatchEvent(new Event('input')); }

        if (draft.step >= 2 && draft.travelers) {
            setTimeout(() => {
                bookingController.nextStep();
                restoreTravelers(draft.travelers);
            }, 400);
        }
        document.getElementById('draftBanner')?.remove();
    } catch(e) { console.error('draft restore error:', e); }
}

function restoreTravelers(travelers) {
    if (!travelers) return;
    const adultBlocks = document.querySelectorAll('.traveler-adult-block');
    (travelers.adults || []).forEach((t, i) => {
        const blk = adultBlocks[i];
        if (!blk) return;
        const set = (cls, val) => { const el = blk.querySelector(cls); if (el && val) el.value = val; };
        set('.t-name',           t.name);
        set('.t-nid',            t.national_id);
        set('.t-passport',       t.passport);
        set('.t-passport-exp',   t.passport_expiry);
        set('.t-gender',         t.gender);
        set('.t-marital',        t.marital_status);
        set('.t-age-range',      t.age_range);
        set('.t-nationality',    t.nationality);
        set('.t-place-of-birth', t.place_of_birth);
        set('.t-dob',            t.date_of_birth);
        const meninCb = blk.querySelector('.t-menin-confirmed');
        if (meninCb && t.vaccination_meningitis) meninCb.checked = true;
        // Trigger conditional renders
        if (t.gender || t.marital_status) onGenderChange(blk);
        if (t.age_range) onAgeRangeChange(blk);
    });
    const childBlocks = document.querySelectorAll('.traveler-child-block');
    (travelers.children || []).forEach((t, i) => {
        const blk = childBlocks[i];
        if (!blk) return;
        const nameEl = blk.querySelector('.t-name');
        const ageEl  = blk.querySelector('.t-age');
        if (nameEl && t.name) nameEl.value = t.name;
        if (ageEl  && t.age)  ageEl.value  = t.age;
    });
}

function discardDraft() {
    localStorage.removeItem(DRAFT_KEY);
    document.getElementById('draftBanner')?.remove();
}

function checkDraft() {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return;
    try {
        const draft    = JSON.parse(raw);
        const pkgId    = new URLSearchParams(location.search).get('package');
        const ageHours = (Date.now() - new Date(draft.savedAt)) / 3_600_000;
        if (draft.packageId !== pkgId || ageHours > 48) {
            localStorage.removeItem(DRAFT_KEY);
            return;
        }
        showDraftBanner(draft.savedAt);
    } catch(e) { localStorage.removeItem(DRAFT_KEY); }
}

document.addEventListener('DOMContentLoaded', async () => {
    await bookingController.init();
    document.addEventListener('input',  () => saveDraft());
    document.addEventListener('change', () => saveDraft());
    setInterval(saveDraft, 30_000);
    window.addEventListener('beforeunload', (e) => {
        const ctrl = bookingController;
        if (ctrl.step && ctrl.step < 3 && ctrl.packageData) {
            window.trackEvent && window.trackEvent('booking_abandon', {
                package_id: ctrl.packageData.id, package_title: ctrl.packageData.title, step_number: ctrl.step
            });
            e.preventDefault(); e.returnValue = '';
        }
    });
});
