/**
 * ocr.js — نيو سي برنسيس فرع الزقازيق فرع الزقازيق فرع الزقازيق  v4.0
 *
 * BOTH passport and NID:
 *   1. Compress image client-side (max 1 MB — OCR.space free-tier limit)
 *   2. POST base64 to /api/ocr-scan (Vercel serverless → OCR.space Engine 2)
 *   3. Parse returned text:
 *        Passport → mrz npm package (TD3 checksum) + hand-rolled fallback
 *        NID      → Arabic-Indic digit normalisation + position-aware name picker
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * ─────────────────────────────────────────────────────────
 */

(function () {

  /* ══════════════════════════════════════════════════════════
     LOAD: mrz npm package via esm.sh  (passport only)
  ══════════════════════════════════════════════════════════ */

  let _mrzReady = null;
  function ensureMrz() {
    if (_mrzReady) return _mrzReady;
    _mrzReady = import('https://esm.sh/mrz@5').then(m => m.default || m.parse || m);
    return _mrzReady;
  }
  ensureMrz().catch(() => {});

  /* ══════════════════════════════════════════════════════════
     STATUS HELPERS
  ══════════════════════════════════════════════════════════ */

  function setStatus(el, type, msg) {
    if (!el) return;
    const styles = {
      loading : 'background:#EFF6FF;border:1px solid #BFDBFE;color:#1D4ED8',
      success : 'background:#F0FDF4;border:1px solid #BBF7D0;color:#15803D',
      error   : 'background:#FEF2F2;border:1px solid #FECACA;color:#B91C1C',
      warning : 'background:#FFFBEB;border:1px solid #FDE68A;color:#B45309',
    };
    el.style.cssText = `${styles[type]};border-radius:6px;padding:6px 10px;font-size:12px;font-family:'Cairo',sans-serif;`;
    el.textContent   = msg;
    el.classList.remove('hidden');
  }
  function hideStatus(el) {
    if (el) { el.classList.add('hidden'); el.textContent = ''; }
  }

  /* ══════════════════════════════════════════════════════════
     BLOCK / FIELD HELPERS
  ══════════════════════════════════════════════════════════ */

  function getBlock(input) {
    return input.closest('.traveler-adult-block, .traveler-child-block') || null;
  }

  function fillField(el, value) {
    if (!el || value == null || String(value).trim() === '') return;
    el.value = String(value).trim();
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ══════════════════════════════════════════════════════════
     IMAGE COMPRESS → base64
     OCR.space free tier: hard 1 MB limit on base64 payload.
     We resize to max 1800px wide + JPEG quality 82 which keeps
     most ID cards under 300 KB while preserving OCR accuracy.
  ══════════════════════════════════════════════════════════ */

  function compressToBase64(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        try {
          const MAX = 1800;
          let { width: w, height: h } = img;
          if (w > MAX) { h = Math.round(h * MAX / w); w = MAX; }
          const c   = document.createElement('canvas');
          c.width = w; c.height = h;
          const ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0, w, h);
          URL.revokeObjectURL(url);
          // Strip data:...;base64, prefix
          const dataUrl = c.toDataURL('image/jpeg', 0.82);
          resolve(dataUrl.split(',')[1]);
        } catch (e) { URL.revokeObjectURL(url); reject(e); }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('img load failed')); };
      img.src = url;
    });
  }

  /* ══════════════════════════════════════════════════════════
     CALL /api/ocr-scan
  ══════════════════════════════════════════════════════════ */

  async function callOcrApi(base64) {
    const res = await fetch('/api/ocr-scan', {
      method  : 'POST',
      headers : { 'Content-Type': 'application/json' },
      body    : JSON.stringify({ imageBase64: base64 }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || `OCR API error ${res.status}`);
    }
    const { text } = await res.json();
    return text || '';
  }

  /* ══════════════════════════════════════════════════════════
     ARABIC-INDIC → WESTERN DIGIT NORMALISER
     Covers: ٠١٢٣٤٥٦٧٨٩  (U+0660–U+0669)
             ۰۱۲۳۴۵۶۷۸۹  (U+06F0–U+06F9 — extended Arabic-Indic)
  ══════════════════════════════════════════════════════════ */

  function normaliseDigits(str) {
    return str
      .replace(/[\u0660-\u0669]/g, d => d.charCodeAt(0) - 0x0660)
      .replace(/[\u06F0-\u06F9]/g, d => d.charCodeAt(0) - 0x06F0);
  }

  /* ══════════════════════════════════════════════════════════
     NID PARSER
     Egyptian NID layout (RTL, read top→bottom by OCR):
       Line 0-1 : جمهورية مصر العربية / بطاقة تحقيق الشخصية  ← always header
       Line 2   : الاسم label or the name itself
       Line 3   : full quadrilinear name  ← TARGET
       Line 4+  : address, religion, marital, dates, NID number
  ══════════════════════════════════════════════════════════ */

  // Words that CANNOT appear in a name line
  const NID_SKIP_RE = /(?:الجمهورية|العربية|المصرية|بطاقة|تحقيق|الشخصية|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة|الاجتماعية|الإصدار|الانتهاء|وزارة|الداخلية|مصر|رقم|حي|شارع|ميدان|طريق|عمارة|دور|شقة|مدينة|محافظة|القاهرة|الجيزة|الإسكندرية|الإسماعيلية|السويس|بورسعيد|المنصورة|طنطا|المنوفية|البحيرة|الدقهلية|الشرقية|الغربية|كفر|الشيخ|الفيوم|بني|سويف|المنيا|أسيوط|سوهاج|قنا|الأقصر|أسوان|البحر|الأحمر|الوادي|الجديد|مطروح|شمال|جنوب|سيناء|دمياط|ذكر|أنثى|مسيحي|مسلم|أعزب|متزوج|مطلق|أرمل|الاسم|الشروق|مدينتي|بدر|العبور|أكتوبر|الرحاب|التجمع|الاوركيد|الاوركيد|نصر|هليوبوليس|عين|شمس)/;

  function parseNID(rawText) {
    const extracted = {};

    // Normalise all Arabic-Indic digits in the whole text first
    const text = normaliseDigits(rawText);

    // ── 1. NID number ──
    // After normalisation, NID is 14 western digits starting with 2 or 3
    const noSpace = text.replace(/\s+/g, '');
    const directMatch = noSpace.match(/[23]\d{13}/);

    // Also try spaced version (OCR.space sometimes inserts spaces between digits)
    const spacedMatch = !directMatch && text.match(/([23](?:[\s·.]{0,2}\d){13})/);
    const nid = directMatch ? directMatch[0]
              : spacedMatch ? spacedMatch[0].replace(/[^0-9]/g, '')
              : null;

    if (nid && nid.length === 14) {
      extracted.national_id_number = nid;
      // Derive DOB: digit[0]=century, [1-2]=YY, [3-4]=MM, [5-6]=DD
      const century = nid[0] === '3' ? '20' : '19';
      const yy = nid.substring(1, 3);
      const mm = nid.substring(3, 5);
      const dd = nid.substring(5, 7);
      if (+mm >= 1 && +mm <= 12 && +dd >= 1 && +dd <= 31) {
        extracted.date_of_birth = `${century}${yy}-${mm}-${dd}`;
      }
    }

    // ── 2. Arabic name — position-aware ──
    const allLines = text.split('\n').map(l => l.trim()).filter(Boolean);

    const candidates = allLines
      .map((line, idx) => ({ line, idx }))
      .filter(({ line }) => {
        if (!/[\u0600-\u06FF]{2,}/.test(line)) return false; // must have Arabic
        if (/\d/.test(line))                   return false; // no digits
        if (NID_SKIP_RE.test(line))             return false; // no header/address words
        // Must have at least 2 Arabic words
        const words = line.split(/\s+/).filter(w => /[\u0600-\u06FF]{2,}/.test(w));
        return words.length >= 2;
      });

    if (candidates.length > 0) {
      // Score: prefer 3-5 words (quadrilinear name), earlier line = lower idx = better
      const scored = candidates.map(({ line, idx }) => {
        const words = line.split(/\s+/).filter(w => /[\u0600-\u06FF]{2,}/.test(w)).length;
        const wordScore = Math.abs(words - 4); // 0 = perfect
        return { line, score: wordScore * 3 + idx };
      });
      scored.sort((a, b) => a.score - b.score);
      extracted.full_name = scored[0].line;
    }

    return extracted;
  }

  /* ══════════════════════════════════════════════════════════
     PASSPORT PARSER — mrz package + hand-rolled fallback
  ══════════════════════════════════════════════════════════ */

  function mrzDateDOB(yymmdd) {
    if (!yymmdd || yymmdd.length !== 6) return null;
    const yr = parseInt(yymmdd.substring(0, 2));
    return `${yr < 30 ? 2000 + yr : 1900 + yr}-${yymmdd.substring(2,4)}-${yymmdd.substring(4,6)}`;
  }
  function mrzDateExpiry(yymmdd) {
    if (!yymmdd || yymmdd.length !== 6) return null;
    return `${2000 + parseInt(yymmdd.substring(0,2))}-${yymmdd.substring(2,4)}-${yymmdd.substring(4,6)}`;
  }

  async function parsePassport(text) {
    const extracted = {};
    const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
    const mrzLines = lines
      .filter(l => /^[A-Z0-9<]{30,}$/.test(l.replace(/\s/g, '')))
      .map(l => l.replace(/\s/g, ''));

    // Try mrz package (best path)
    if (mrzLines.length >= 2) {
      try {
        const mrzPkg  = await ensureMrz();
        const parseFn = typeof mrzPkg === 'function' ? mrzPkg
                      : (mrzPkg.parse || mrzPkg.default?.parse);
        if (parseFn) {
          const td3 = mrzLines.filter(l => l.length === 44);
          if (td3.length >= 2) {
            const result = parseFn([td3[0], td3[1]], { autocorrect: true });
            const f = result.fields;
            if (f.documentNumber) extracted.passport_number = f.documentNumber;
            if (f.lastName && f.firstName)
              extracted.full_name = `${f.firstName} ${f.lastName}`.replace(/\s+/g, ' ').trim();
            else if (f.lastName) extracted.full_name = f.lastName;
            if (f.birthDate)      extracted.date_of_birth = mrzDateDOB(f.birthDate);
            if (f.expirationDate) extracted.expiry_date   = mrzDateExpiry(f.expirationDate);
            if (f.sex)            extracted.gender        = f.sex;
            console.log('[OCR] mrz result:', result);
            return extracted;
          }
        }
      } catch (e) { console.warn('[OCR] mrz fallback:', e.message); }
    }

    // Hand-rolled fallback
    const mrz2 = mrzLines.find(l =>
      l.length >= 40 && /\d{6}[0-9][MF<]\d{6}/.test(l.substring(13, 28))
    );
    if (mrz2) {
      const pNo = mrz2.substring(0, 9).replace(/</g, '');
      if (pNo) extracted.passport_number = pNo;
      extracted.date_of_birth = mrzDateDOB(mrz2.substring(13, 19));
      const sex = mrz2[20];
      if (sex === 'M' || sex === 'F') extracted.gender = sex;
      extracted.expiry_date = mrzDateExpiry(mrz2.substring(21, 27));
    }
    const mrz1 = mrzLines.find(l => /^P[A-Z<]/.test(l));
    if (mrz1) {
      const np = mrz1.substring(5).split('<<');
      extracted.full_name = [`${(np[1]||'').replace(/</g,' ').trim()}`,
                             `${(np[0]||'').replace(/</g,' ').trim()}`]
                            .filter(Boolean).join(' ');
    }
    // Visible-zone fallbacks
    if (!extracted.passport_number) {
      const vis = lines.filter(l => !l.includes('<')).join(' ');
      const m   = vis.match(/[A-Z]{1,2}[0-9]{6,8}/);
      if (m) extracted.passport_number = m[0];
    }
    if (!extracted.expiry_date) {
      const vis   = lines.filter(l => !l.includes('<')).join(' ');
      const hits  = vis.match(/(\d{2})[\/.\-](\d{2})[\/.\-](\d{4})/g) || [];
      const dates = hits.map(d => { const p = d.split(/[\/.\-]/); return `${p[2]}-${p[1]}-${p[0]}`; }).sort();
      if (dates.length) extracted.expiry_date = dates[dates.length - 1];
    }
    return extracted;
  }

  /* ══════════════════════════════════════════════════════════
     FILL FUNCTIONS
  ══════════════════════════════════════════════════════════ */

  function fillPassportFields(block, ex) {
    if (!block || !ex) return;
    if (ex.full_name)       fillField(block.querySelector('.t-name'),         ex.full_name);
    if (ex.passport_number) fillField(block.querySelector('.t-passport'),     ex.passport_number.toUpperCase());
    if (ex.expiry_date)     fillField(block.querySelector('.t-passport-exp'), ex.expiry_date);
  }

  function fillNIDFields(block, ex) {
    if (!block || !ex) return;
    if (ex.full_name)          fillField(block.querySelector('.t-name'), ex.full_name);
    if (ex.national_id_number) fillField(block.querySelector('.t-nid'),  ex.national_id_number);
    if (ex.date_of_birth)      fillField(block.querySelector('.t-dob'),  ex.date_of_birth);
  }

  /* ══════════════════════════════════════════════════════════
     EVENT ATTACHMENT
  ══════════════════════════════════════════════════════════ */

  function attachOCR(input, docType) {
    input.addEventListener('change', async function () {
      const file = this.files?.[0];
      if (!file) return;

      const block    = getBlock(this);
      const idx      = parseInt(this.dataset.travelerIdx ?? '0', 10);
      const statusEl = document.getElementById(
        `ocr_${docType === 'passport' ? 'passport' : 'nid'}_status_${idx}`
      );

      if (file.type === 'application/pdf') {
        setStatus(statusEl, 'warning', '⚠️ ملفات PDF لا تدعم المسح — يرجى رفع صورة JPG/PNG');
        return;
      }
      if (!file.type.startsWith('image/')) return;

      setStatus(statusEl, 'loading', '🔍 جارٍ معالجة الصورة وقراءة البيانات…');

      try {
        const base64 = await compressToBase64(file);
        const text   = await callOcrApi(base64);
        console.log('[OCR] raw text:', text);

        if (docType === 'passport') {
          const ex = await parsePassport(text);
          console.log('[OCR] passport fields:', ex);
          fillPassportFields(block, ex);
          const filled = [ex.passport_number, ex.expiry_date, ex.full_name].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? `✅ تم استخراج ${filled.length} حقول — يرجى المراجعة قبل الإرسال`
              : '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
        } else {
          const ex = parseNID(text);
          console.log('[OCR] NID fields:', ex);
          fillNIDFields(block, ex);
          const filled = [ex.national_id_number, ex.full_name, ex.date_of_birth].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? `✅ تم استخراج ${filled.length} حقول — يرجى المراجعة قبل الإرسال`
              : '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
        }

        setTimeout(() => hideStatus(statusEl), 8000);
      } catch (err) {
        console.error('[OCR] Error:', err);
        setStatus(statusEl, 'error', `❌ تعذّر قراءة المستند — ${err.message || 'يرجى الإدخال يدوياً'}`);
      }
    });
  }

  /* ══════════════════════════════════════════════════════════
     OBSERVER — attach to dynamic inputs
  ══════════════════════════════════════════════════════════ */

  function scanAndAttach() {
    document.querySelectorAll('.ocr-passport-input:not([data-ocr-attached])').forEach(el => {
      el.setAttribute('data-ocr-attached', '1');
      attachOCR(el, 'passport');
    });
    document.querySelectorAll('.ocr-nid-input:not([data-ocr-attached])').forEach(el => {
      el.setAttribute('data-ocr-attached', '1');
      attachOCR(el, 'national_id');
    });
  }

  new MutationObserver(scanAndAttach).observe(document.body, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', scanAndAttach);

})();
