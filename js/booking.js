/**
 * booking.js
 * Multi-step booking flow and Supabase integrations
 */

function showInlineError(id, msg) {
    const el = document.getElementById(id);
    if (!el) return;
    const msgEl = el.querySelector("[data-msg]") || el;
    msgEl.textContent = msg;
    el.classList.remove("hidden");
    el.scrollIntoView({ behavior: "smooth", block: "center" });
}

const bookingController = {
    step: 1,
    packageData: null,
    totalBasePrice: 0,
    appliedCoupon: null,
    discountAmount: 0,
    uploadedDocuments: [], // Array to hold returned storage URLs
    
    async init() {
        // ── Auth gate: must be logged in to book ──
        const { data: { session } } = await window.db.auth.getSession();
        if (!session) {
            this._showAuthGate();
            return;
        }
        this.currentUser = session.user;

        // فحص وجود مسودة محفوظة
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
                .select('id, title, category, season, departure_date, return_date, duration_nights, price_per_person, price_child, discount_percent, max_seats, available_seats, departure_city, flight_type, airline, mecca_hotel, mecca_hotel_stars, medina_hotel, medina_hotel_stars, nights_mecca, nights_medina, transport_type, includes, excludes, itinerary, images, thumbnail_url, is_active, visa_included, notes')
                .eq('id', pkgId).single();
            if (error) throw error;
            this.packageData = data;
            
            document.getElementById('summaryCard').style.display = 'flex';
            document.getElementById('summaryTitle').innerText = data.title;
            document.getElementById('summaryDate').innerText = 'المغادرة: ' + window.formatDate(data.departure_date);
            document.getElementById('summaryBasePrice').innerText = window.formatCurrency(data.price_per_person) + ' / للفرد';

            // Funnel: booking_start
            if (window.trackEvent) window.trackEvent('booking_start', {
              package_id: data.id, package_title: data.title
            });
            
            if(!data.price_child) {
                document.getElementById('childPriceNotice').innerText = 'سعر الطفل غير متاح لهذا البرنامج؛ يُحسب كفرد بالغ.';
            } else {
                document.getElementById('childPriceNotice').innerText = `سعر الطفل: ${window.formatCurrency(data.price_child)}`;
            }

            this.updatePricing();
            
            // Listeners for inputs
            document.getElementById('adultsCount').addEventListener('input', () => this.updatePricing());
            document.getElementById('childrenCount').addEventListener('input', () => this.updatePricing());

        } catch(err) {
            console.error(err);
            showInlineError('booking-validation-error', 'خطأ في استرجاع بيانات البرنامج');
        }
    },

    updatePricing() {
        const adults = parseInt(document.getElementById('adultsCount').value) || 1;
        const children = parseInt(document.getElementById('childrenCount').value) || 0;
        
        const priceAdult = this.packageData.price_per_person;
        const priceChild = this.packageData.price_child || priceAdult; // Fallback if no child price

        const adultsTotal = adults * priceAdult;
        const childrenTotal = children * priceChild;
        this.totalBasePrice = adultsTotal + childrenTotal;

        document.getElementById('calcAdultsText').innerText = `${adults} بالغ`;
        document.getElementById('calcAdultsTotal').innerText = window.formatCurrency(adultsTotal);
        
        document.getElementById('calcChildrenText').innerText = `${children} طفل`;
        document.getElementById('calcChildrenTotal').innerText = window.formatCurrency(childrenTotal);

        if (this.appliedCoupon && this.packageData.discount_percent) {
            this.discountAmount = (this.totalBasePrice * this.packageData.discount_percent) / 100;
            document.getElementById('discountPercentText').innerText = this.packageData.discount_percent;
            document.getElementById('calcDiscountTotal').innerText = '-' + window.formatCurrency(this.discountAmount);
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
        const msgEl = document.getElementById('couponMsg');

        if (!inputStr) return;

        // Validate server-side so the coupon code is never exposed in the browser
        msgEl.innerText = '...جاري التحقق';
        msgEl.className = 'text-sm -mt-6 mb-6 px-4 text-gray-400 block';

        const { data, error } = await supabase.rpc('validate_coupon', {
            p_package_id: this.packageData.id,
            p_code: inputStr.toUpperCase()
        });

        if (error || !data?.valid) {
            this.appliedCoupon = null;
            this.couponDiscount = 0;
            msgEl.innerText = 'الكود غير صحيح أو لا ينطبق على هذا البرنامج';
            msgEl.className = 'text-sm -mt-6 mb-6 px-4 text-red-600 block';
        } else {
            this.appliedCoupon = inputStr;
            this.couponDiscount = data.discount ?? this.packageData.coupon_discount ?? 0;
            msgEl.innerText = 'تم تطبيق كود الخصم بنجاح';
            msgEl.className = 'text-sm -mt-6 mb-6 px-4 text-green-600 block';
        }
        this.updatePricing();
    },

    nextStep() {
        if(this.step === 1) {
            this.buildTravelersForm();
        }
        if(this.step < 3) {
            document.getElementById(`step${this.step}`).classList.add('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.remove('text-primary');
            this.step++;
            document.getElementById(`step${this.step}`).classList.remove('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.add('text-primary');
            document.getElementById('progressBar').style.width = (this.step * 33) + '%';
            if (this.step === 3) this.buildDocumentsForm();

            // Funnel: booking_step
            if (window.trackEvent) window.trackEvent('booking_step', {
              package_id:    this.packageData?.id,
              package_title: this.packageData?.title,
              step_number:   this.step
            });
        }
    },

    prevStep() {
        if(this.step > 1) {
            document.getElementById(`step${this.step}`).classList.add('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.remove('text-primary');
            this.step--;
            document.getElementById(`step${this.step}`).classList.remove('hidden');
            document.getElementById(`stepLabel${this.step}`).classList.add('text-primary');
            document.getElementById('progressBar').style.width = (this.step * 33) + '%';
        }
    },

    buildTravelersForm() {
        const adults = parseInt(document.getElementById('adultsCount').value) || 1;
        const children = parseInt(document.getElementById('childrenCount').value) || 0;
        const container = document.getElementById('travelersFormContainer');
        container.innerHTML = '';

        for(let i = 1; i <= adults; i++) {
            container.innerHTML += `
               <div class="border border-gray-200 p-4 rounded-lg traveler-adult-block bg-white">
                 <h4 class="font-bold mb-3 border-b pb-2"><span class="bg-gray-200 text-gray-700 px-2 py-0.5 rounded text-sm ml-2">بالغ ${i}</span></h4>
                 <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <input type="text" class="t-name border p-2 rounded w-full" placeholder="الاسم الرباعي (مطلوب)" required>
                    <input type="text" class="t-nid border p-2 rounded w-full" placeholder="الرقم القومي (14 رقم)" required maxlength="14">
                    <input type="text" class="t-passport border p-2 rounded w-full" placeholder="رقم جواز السفر (مطلوب)" required>
                    <input type="date" class="t-passport-exp border p-2 rounded w-full text-gray-600" title="تاريخ انتهاء الجواز">
                 </div>
               </div>
            `;
        }

        for(let i = 1; i <= children; i++) {
            container.innerHTML += `
               <div class="border border-gray-200 p-4 rounded-lg traveler-child-block bg-white">
                 <h4 class="font-bold mb-3 border-b pb-2"><span class="bg-blue-100 text-blue-700 px-2 py-0.5 rounded text-sm ml-2">طفل ${i}</span></h4>
                 <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <input type="text" class="t-name border p-2 rounded w-full" placeholder="الاسم الرباعي (مطلوب)" required>
                    <input type="number" class="t-age border p-2 rounded w-full" placeholder="العمر" required min="1" max="11">
                 </div>
               </div>
            `;
        }

        // ── Attach live passport-expiry validation to every adult block ──
        document.querySelectorAll('.traveler-adult-block .t-passport-exp').forEach(inp => {
            inp.addEventListener('change', () => this.validatePassportExpiry(inp));
        });
    },

    // ── Passport expiry validation ──────────────────────────────────────────
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
        const val        = input.value;
        const departure  = this.packageData?.departure_date;
        const warningEl  = this._passportWarningEl(input);

        if (!val || !departure) { warningEl.innerHTML = ''; return true; }

        const expiry    = new Date(val);
        const now       = new Date(); now.setHours(0,0,0,0);
        const minExpiry = this._passportMinExpiry(departure);

        const fmt = d => d.toLocaleDateString('ar-EG', { year:'numeric', month:'long', day:'numeric' });
        const ERR = (msg) => {
            warningEl.innerHTML = `<div style="background:#fef2f2;border:1px solid #fecaca;border-radius:8px;
                padding:10px 14px;margin-top:6px;font-size:13px;font-weight:700;color:#dc2626;
                display:flex;align-items:flex-start;gap:8px;">
              <i class="fa-solid fa-circle-exclamation" style="margin-top:2px;flex-shrink:0;"></i>
              <span>${msg}</span></div>`;
            input.style.borderColor = '#fca5a5';
            return false;
        };
        const OK = () => {
            warningEl.innerHTML = `<div style="background:#f0fdf4;border:1px solid #86efac;border-radius:8px;
                padding:8px 14px;margin-top:6px;font-size:12px;font-weight:700;color:#16a34a;
                display:flex;align-items:center;gap:6px;">
              <i class="fa-solid fa-circle-check"></i> الجواز صالح للسفر ✓</div>`;
            input.style.borderColor = '#86efac';
            return true;
        };

        if (expiry < now)       return ERR('⛔ جواز السفر منتهي الصلاحية، يرجى تجديده قبل الحجز');
        if (expiry < minExpiry) return ERR(`⚠️ الجواز يجب أن يكون صالحاً 6 أشهر بعد المغادرة (اشتراط سعودي). الحد الأدنى المطلوب: ${fmt(minExpiry)}`);
        return OK();
    },

    validateAllPassports() {
        const inputs = Array.from(document.querySelectorAll('.t-passport-exp'));
        const hasValue = inputs.filter(i => i.value);
        if (hasValue.length === 0) return true; // all blank — skip (not required field)
        return hasValue.every(i => this.validatePassportExpiry(i));
    },
    // ────────────────────────────────────────────────────────────────────────

    validateAndNext() {
        const phone = document.getElementById('contactPhone').value;
        if(!phone || phone.length < 8) {
            showInlineError("booking-validation-error", "يرجى إدخال رقم هاتف صحيح للتواصل");
            return;
        }
        const inputs = Array.from(document.querySelectorAll('.traveler-adult-block input[required], .traveler-child-block input[required]'));
        let isValid = inputs.every(i => i.value.trim() !== '');
        
        if(!isValid) {
            showInlineError("booking-validation-error", "يرجى ملء كافة الحقول الإلزامية للمسافرين.");
            return;
        }

        // ── Passport expiry gate ──
        if (!this.validateAllPassports()) {
            const first = document.querySelector('.t-passport-exp[style*="fca5a5"]') ||
                          document.querySelector('.passport-warning div');
            first?.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return;
        }

        this.nextStep();
    },

    buildDocumentsForm() {
        const container = document.getElementById('documentsContainer');
        container.innerHTML = '';
        const names = Array.from(document.querySelectorAll('.traveler-adult-block .t-name')).map(inp => inp.value);
        
        names.forEach((name, idx) => {
            if(!name) return;
            container.innerHTML += `
              <div class="bg-gray-50 border border-gray-200 p-4 rounded-lg flex justify-between items-center">
                  <div>
                      <p class="font-bold text-primary">${name}</p>
                      <p class="text-xs text-gray-500">صورة جواز السفر (PDF, JPG)</p>
                  </div>
                  <div>
                    <input type="file" id="file_${idx}" data-traveler="${name}" class="text-sm bg-white border border-gray-300 rounded" accept="image/jpeg,image/png,application/pdf">
                  </div>
              </div>
            `;
        });
    },

    async uploadDocument(fileObj, travelerName) {
        if(!fileObj) return null;
        try {
            let file = fileObj;
            const isImage = fileObj.type.startsWith('image/');

            // ── Compress images before upload ─────────────
            if (isImage && typeof imageCompression !== 'undefined') {
                try {
                    const compressed = await imageCompression(fileObj, {
                        maxSizeMB:        0.5,
                        maxWidthOrHeight:  1400,
                        useWebWorker:      true,
                        fileType:         'image/jpeg',
                        initialQuality:    0.82,
                    });
                    console.log(`Passport: ${(fileObj.size/1024).toFixed(0)}KB → ${(compressed.size/1024).toFixed(0)}KB`);
                    file = new File([compressed],
                        fileObj.name.replace(/\.[^.]+$/, '.jpg'),
                        { type: 'image/jpeg' }
                    );
                } catch(compErr) {
                    console.warn('Compression skipped:', compErr);
                }
            }

            const ext      = file.name.split('.').pop();
            const fileName = `${Date.now()}_${Math.random().toString(36).substring(7)}.${ext}`;
            // Path scoped to user so storage RLS policy (passports/<user_id>/...) is satisfied
            const userId   = this.currentUser?.id || 'anon';
            const filePath = `passports/${userId}/${fileName}`;

            const { data, error } = await window.db.storage
              .from('booking-documents')
              .upload(filePath, file);

            if (error) throw error;

            // Bucket is private — store path only; admin uses signed URL on demand
            return {
                type: 'passport',
                traveler_name: travelerName,
                path: filePath,
                url: null,
                uploaded_at: new Date().toISOString()
            };
        } catch(err) {
            console.error('File upload skipped or failed:', err);
            return null;
        }
    },

    async submitBooking() {
        // ── Final passport expiry guard ──
        if (!this.validateAllPassports()) {
            const first = document.querySelector('.passport-warning div');
            first?.scrollIntoView({ behavior: 'smooth', block: 'center' });
            showInlineError('booking-validation-error', 'يوجد جواز سفر غير صالح للسفر. يرجى المراجعة قبل المتابعة.');
            return;
        }

        const recaptchaToken = grecaptcha.getResponse();
        if (!recaptchaToken) {
            showInlineError('booking-validation-error', 'يرجى التحقق من أنك لست روبوتاً');
            return;
        }

        const btn = document.getElementById('finalSubmitBtn');
        btn.innerHTML = '<div class="loader mx-auto" style="width:24px;height:24px;border-width:3px;"></div>';
        btn.disabled = true;

        try {
            // Server-side reCAPTCHA verification
            const { data: captchaData, error: captchaError } = await window.db.functions.invoke('verify-recaptcha', { body: { token: recaptchaToken } });
            if (captchaError || !captchaData?.success) {
                showInlineError('booking-validation-error', 'فشل التحقق من reCAPTCHA. يرجى المحاولة مرة أخرى.');
                btn.innerHTML = 'تأكيد طلب الحجز';
                btn.disabled = false;
                grecaptcha.reset();
                return;
            }
            // 1. Gather files and upload sequentially
            let uploadedDocs = [];
            const fileInputs = document.querySelectorAll('#documentsContainer input[type="file"]');
            for(let input of fileInputs) {
                if(input.files && input.files[0]) {
                    const docRec = await this.uploadDocument(input.files[0], input.dataset.traveler);
                    if(docRec) uploadedDocs.push(docRec);
                }
            }

            // 2. Gather Travelers
            const travelers = [];
            document.querySelectorAll('.traveler-adult-block').forEach(blk => {
                travelers.push({
                    type: 'adult',
                    name: blk.querySelector('.t-name').value,
                    national_id: blk.querySelector('.t-nid').value,
                    passport: blk.querySelector('.t-passport').value,
                    passport_expiry: blk.querySelector('.t-passport-exp').value
                });
            });
            document.querySelectorAll('.traveler-child-block').forEach(blk => {
                travelers.push({
                    type: 'child',
                    name: blk.querySelector('.t-name').value,
                    age: parseInt(blk.querySelector('.t-age').value)
                });
            });

            // 3. Prepare payload
            const finalTotal = this.totalBasePrice - this.discountAmount;
            const payload = {
                package_id: this.packageData.id,
                package_title: this.packageData.title,
                package_departure: this.packageData.departure_date,
                customer_name: travelers[0]?.name || 'غير محدد',
                customer_phone: document.getElementById('contactPhone').value,
                customer_email: document.getElementById('contactEmail').value,
                customer_national_id: travelers[0]?.national_id,
                customer_passport_number: travelers[0]?.passport,
                adults_count: parseInt(document.getElementById('adultsCount').value) || 1,
                children_count: parseInt(document.getElementById('childrenCount').value) || 0,
                travelers: travelers,
                total_price: finalTotal,
                remaining_amount: finalTotal,
                coupon_code: this.appliedCoupon,
                discount_amount: this.discountAmount,
                documents: uploadedDocs,
                special_requests: document.getElementById('specialRequests').value,
                user_id: this.currentUser?.id || null
            };

            // 4. API Insert
            // TODO (Issue #5): Integrate online payment gateway (Paymob or Fawry)
            // before inserting the booking, redirect to payment page and only
            // insert with payment_status = "paid" upon successful callback.
            // Requires merchant registration outside the codebase.
            const { data, error } = await window.db.from('bookings').insert(payload).select().single();
            if (error) throw error;

            // 5. Success
            document.getElementById('successBookingNumber').innerText = data.booking_number;
            document.getElementById('successModal').classList.remove('hidden');

            // حذف المسودة بعد إتمام الحجز بنجاح
            localStorage.removeItem(DRAFT_KEY);

            // Funnel: booking_complete
            if (window.trackEvent) window.trackEvent('booking_complete', {
              package_id:    this.packageData?.id,
              package_title: this.packageData?.title
            });

            // Set up button redirection and auto-whatsapp
            document.getElementById('goToTrackingBtn').onclick = () => {
                window.location.href = `/tracking.html?booking=${data.booking_number}`;
            };
            
            // Trigger WhatsApp popup
            this.sendWhatsApp(data);

        } catch(err) {
            console.error("Booking Error:", err);
            // Show inline error card instead of blocking alert()
            const errCard = document.getElementById('booking-submit-error');
            const errMsg  = document.getElementById('booking-submit-error-msg');
            if (errCard && errMsg) {
                errMsg.textContent = err?.message || 'حدث خطأ أثناء إرسال طلب الحجز. يرجى المحاولة لاحقاً.';
                errCard.classList.remove('hidden');
                errCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
            btn.innerHTML = 'تأكيد طلب الحجز';
            btn.disabled = false;
            grecaptcha.reset();
        }
    },

    sendWhatsApp(bookingRow) {
        const msg = `🕌 *طلب حجز جديد — نيو سي برنسيس لسياحة*

📋 *رقم الحجز:* ${bookingRow.booking_number}
📦 *البرنامج:* ${bookingRow.package_title}
📅 *تاريخ المغادرة:* ${window.formatDate(bookingRow.package_departure)}
👤 *اسم العميل:* ${bookingRow.customer_name}
📞 *رقم التواصل:* ${bookingRow.customer_phone}
👥 *الأفراد:* ${bookingRow.adults_count} بالغين | ${bookingRow.children_count} أطفال
💰 *الإجمالي:* ${window.formatCurrency(bookingRow.total_price)}
📎 *المستندات المرفوعة:* ${bookingRow.documents.length} ملف
        `;
        const encoded = encodeURIComponent(msg);
        window.open(`https://wa.me/201031777295?text=${encoded}`, '_blank');
    },

    // ── Auth gate UI ──
    _showAuthGate() {
        // Hide the whole booking page content
        const main = document.querySelector('main') || document.querySelector('.container');
        const body = document.body;

        // Build the overlay gate
        const gate = document.createElement('div');
        gate.id = 'authGate';
        gate.style.cssText = `
            position:fixed;inset:0;z-index:9999;
            background:linear-gradient(155deg,#0D1B0E 0%,#132415 60%,#0A150B 100%);
            display:flex;align-items:center;justify-content:center;padding:20px;
            font-family:'Cairo',sans-serif;
        `;

        const pkg = new URLSearchParams(window.location.search).get('package') || '';
        const returnUrl = encodeURIComponent('/booking.html?package=' + pkg);

        gate.innerHTML = `
            <div style="background:rgba(255,255,255,.96);border-radius:20px;padding:44px 36px;max-width:440px;width:100%;text-align:center;box-shadow:0 24px 64px rgba(0,0,0,.5);">
                <!-- icon -->
                <div style="width:72px;height:72px;background:linear-gradient(135deg,#1B5E20,#2E7D32);border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 auto 20px;box-shadow:0 8px 24px rgba(27,94,32,.35);">
                    <i class="fa-solid fa-lock" style="font-size:28px;color:#fff;"></i>
                </div>

                <!-- heading -->
                <h2 style="font-size:22px;font-weight:900;color:#0D1B0E;margin-bottom:8px;">تسجيل الدخول مطلوب</h2>
                <p style="font-size:14px;color:#6b7280;line-height:1.7;margin-bottom:28px;">
                    لحجز هذا البرنامج يجب أن تكون مسجلاً في الموقع.<br>
                    سجّل دخولك أو أنشئ حساباً جديداً مجاناً.
                </p>

                <!-- divider gold -->
                <div style="display:flex;align-items:center;gap:10px;margin-bottom:24px;">
                    <span style="flex:1;height:1px;background:linear-gradient(90deg,transparent,rgba(184,134,11,.4));"></span>
                    <i class="fa-solid fa-kaaba" style="color:#B8860B;font-size:13px;"></i>
                    <span style="flex:1;height:1px;background:linear-gradient(90deg,rgba(184,134,11,.4),transparent);"></span>
                </div>

                <!-- buttons -->
                <a href="/login.html?next=${returnUrl}"
                   style="display:flex;align-items:center;justify-content:center;gap:8px;background:linear-gradient(135deg,#B8860B,#9a7209);color:#fff;padding:14px;border-radius:10px;font-weight:800;font-size:15px;text-decoration:none;margin-bottom:12px;box-shadow:0 4px 18px rgba(184,134,11,.4);">
                    <i class="fa-solid fa-right-to-bracket"></i> تسجيل الدخول
                </a>
                <a href="/login.html?tab=register&next=${returnUrl}"
                   style="display:flex;align-items:center;justify-content:center;gap:8px;background:transparent;color:#1B5E20;padding:13px;border-radius:10px;font-weight:700;font-size:14px;text-decoration:none;border:1.5px solid #1B5E20;margin-bottom:20px;">
                    <i class="fa-solid fa-user-plus"></i> إنشاء حساب جديد مجاناً
                </a>

                <!-- back link -->
                <a href="javascript:history.back()" style="font-size:12px;color:#9ca3af;font-weight:700;text-decoration:none;display:inline-flex;align-items:center;gap:5px;">
                    <i class="fa-solid fa-arrow-right"></i> العودة للبرنامج
                </a>
            </div>
        `;

        document.body.appendChild(gate);

        // Blur the page behind it
        if (main) main.style.filter = 'blur(4px)';
    }
};


// ═══════════════════════════════════════════════════════════════
//  DRAFT SAVE / RESTORE — حفظ واسترداد مسودة الحجز
// ═══════════════════════════════════════════════════════════════
const DRAFT_KEY = 'nsp_booking_draft';

/* جمع بيانات المسافرين النصية فقط (بدون الملفات) */
function collectTravelersPartial() {
    const adults   = Array.from(document.querySelectorAll('.traveler-adult-block')).map(blk => ({
        name:           blk.querySelector('.t-name')?.value        || '',
        national_id:    blk.querySelector('.t-nid')?.value         || '',
        passport:       blk.querySelector('.t-passport')?.value    || '',
        passport_expiry:blk.querySelector('.t-passport-exp')?.value|| ''
    }));
    const children = Array.from(document.querySelectorAll('.traveler-child-block')).map(blk => ({
        name: blk.querySelector('.t-name')?.value || '',
        age:  blk.querySelector('.t-age')?.value  || ''
    }));
    return { adults, children };
}

/* حفظ المسودة في localStorage */
function saveDraft() {
    const pkgId = new URLSearchParams(location.search).get('package');
    if (!pkgId) return;
    try {
        const draft = {
            packageId:    pkgId,
            savedAt:      new Date().toISOString(),
            step:         bookingController.step || 1,
            contactPhone: document.getElementById('contactPhone')?.value  || '',
            contactEmail: document.getElementById('contactEmail')?.value  || '',
            adults:       document.getElementById('adultsCount')?.value   || '1',
            children:     document.getElementById('childrenCount')?.value || '0',
            notes:        document.getElementById('specialRequests')?.value|| '',
            travelers:    collectTravelersPartial()
        };
        localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
    } catch(e) { /* صامت */ }
}

/* تحويل الوقت لنص نسبي عربي */
function formatRelativeTime(isoStr) {
    const diff = Math.floor((Date.now() - new Date(isoStr)) / 60000); // بالدقائق
    if (diff < 1)  return 'الآن';
    if (diff < 60) return `منذ ${diff} دقيقة`;
    const hrs = Math.floor(diff / 60);
    if (hrs < 24)  return `منذ ${hrs} ساعة`;
    return `منذ ${Math.floor(hrs / 24)} يوم`;
}

/* عرض بانر الاسترداد */
function showDraftBanner(savedAt) {
    const existing = document.getElementById('draftBanner');
    if (existing) existing.remove();

    const banner = document.createElement('div');
    banner.id = 'draftBanner';
    banner.style.cssText = 'margin-bottom:16px;';
    banner.innerHTML = `
        <div style="background:#f0fdf4;border:1.5px solid #86efac;border-radius:12px;padding:14px 18px;
                    display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;
                    box-shadow:0 2px 8px rgba(22,163,74,.1);">
            <div style="display:flex;align-items:center;gap:10px;">
                <div style="width:38px;height:38px;background:#dcfce7;border-radius:50%;display:flex;
                            align-items:center;justify-content:center;flex-shrink:0;">
                    <i class="fa-solid fa-rotate-right" style="color:#16a34a;font-size:15px;"></i>
                </div>
                <div>
                    <p style="font-weight:800;color:#166534;font-size:14px;margin:0 0 2px;">
                        لديك مسودة حجز محفوظة
                    </p>
                    <p style="font-size:12px;color:#4b7c5a;margin:0;">
                        آخر حفظ: ${formatRelativeTime(savedAt)}
                    </p>
                </div>
            </div>
            <div style="display:flex;gap:8px;flex-shrink:0;">
                <button onclick="restoreDraft()"
                        style="background:#16a34a;color:#fff;padding:8px 18px;border-radius:8px;
                               font-weight:800;font-size:13px;border:none;cursor:pointer;
                               font-family:'Cairo',sans-serif;white-space:nowrap;">
                    نكمل من حيث توقفنا ←
                </button>
                <button onclick="discardDraft()"
                        style="background:transparent;color:#9ca3af;padding:8px 12px;border:none;
                               cursor:pointer;font-size:12px;font-family:'Cairo',sans-serif;white-space:nowrap;">
                    ابدأ من جديد
                </button>
            </div>
        </div>`;

    // إدراج البانر أعلى محتوى الصفحة مباشرةً
    const container = document.querySelector('.max-w-3xl') 
                   || document.querySelector('.container')
                   || document.querySelector('main');
    if (container) container.prepend(banner);
}

/* استعادة البيانات من المسودة */
function restoreDraft() {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return;
    try {
        const draft = JSON.parse(raw);

        // تعبئة حقول التواصل
        const phone = document.getElementById('contactPhone');
        const email = document.getElementById('contactEmail');
        const notes = document.getElementById('specialRequests');
        if (phone && draft.contactPhone) phone.value = draft.contactPhone;
        if (email && draft.contactEmail) email.value = draft.contactEmail;
        if (notes && draft.notes)        notes.value = draft.notes;

        // تعبئة عدد المسافرين
        const adultsEl   = document.getElementById('adultsCount');
        const childrenEl = document.getElementById('childrenCount');
        if (adultsEl   && draft.adults)   { adultsEl.value   = draft.adults;   adultsEl.dispatchEvent(new Event('input')); }
        if (childrenEl && draft.children) { childrenEl.value = draft.children; childrenEl.dispatchEvent(new Event('input')); }

        // إذا كان المستخدم وصل للخطوة الثانية، انتقل إليها وعبّئ بيانات المسافرين
        if (draft.step >= 2 && draft.travelers) {
            // الانتقال للخطوة 2 بعد تأخير قصير حتى تُبنى قائمة المسافرين
            setTimeout(() => {
                bookingController.nextStep();
                restoreTravelers(draft.travelers);
            }, 400);
        }

        // إخفاء البانر بعد الاسترداد
        document.getElementById('draftBanner')?.remove();

    } catch(e) { console.error('draft restore error:', e); }
}

/* تعبئة بيانات المسافرين */
function restoreTravelers(travelers) {
    if (!travelers) return;

    const adultBlocks = document.querySelectorAll('.traveler-adult-block');
    (travelers.adults || []).forEach((t, i) => {
        const blk = adultBlocks[i];
        if (!blk) return;
        const set = (cls, val) => { const el = blk.querySelector(cls); if (el && val) el.value = val; };
        set('.t-name',         t.name);
        set('.t-nid',          t.national_id);
        set('.t-passport',     t.passport);
        set('.t-passport-exp', t.passport_expiry);
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

/* تجاهل المسودة وحذفها */
function discardDraft() {
    localStorage.removeItem(DRAFT_KEY);
    document.getElementById('draftBanner')?.remove();
}

/* فحص وجود مسودة عند تحميل الصفحة */
function checkDraft() {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) return;
    try {
        const draft    = JSON.parse(raw);
        const pkgId    = new URLSearchParams(location.search).get('package');
        const ageHours = (Date.now() - new Date(draft.savedAt)) / 3_600_000;

        // تجاهل إذا كانت لبرنامج مختلف أو انتهت صلاحيتها (48 ساعة)
        if (draft.packageId !== pkgId || ageHours > 48) {
            localStorage.removeItem(DRAFT_KEY);
            return;
        }
        showDraftBanner(draft.savedAt);
    } catch(e) {
        localStorage.removeItem(DRAFT_KEY);
    }
}

document.addEventListener('DOMContentLoaded', async () => {
    await bookingController.init();

    // حفظ تلقائي عند كل تغيير في الحقول
    document.addEventListener('input',  () => saveDraft());
    document.addEventListener('change', () => saveDraft());

    // حفظ تلقائي كل 30 ثانية
    setInterval(saveDraft, 30_000);

    // Funnel: booking_abandon (fires when user leaves mid-flow)
    window.addEventListener('beforeunload', () => {
      const ctrl = bookingController;
      if (ctrl.step && ctrl.step < 3 && ctrl.packageData) {
        window.trackEvent && window.trackEvent('booking_abandon', {
          package_id:    ctrl.packageData.id,
          package_title: ctrl.packageData.title,
          step_number:   ctrl.step
        });
      }
    });
});
