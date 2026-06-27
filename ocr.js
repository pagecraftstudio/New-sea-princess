/**
 * ocr.js — نيو سي برنسيس للسياحة  v3.0
 *
 * PASSPORT  → Tesseract.js (eng-only) extracts raw text → `mrz` npm package
 *             (via esm.sh CDN) parses MRZ lines with checksum validation and
 *             O↔0 / I↔1 auto-correction. No API key. Runs in ~1-3 s.
 *
 * NID       → Tesseract.js (eng+ara) for Arabic name + digit extraction.
 *             Same as before; no better free browser alternative for Arabic.
 *
 * Key changes vs v2.1
 * ────────────────────
 * • mrzParse() replaces hand-rolled MRZ field offsets — handles TD1/TD2/TD3,
 *   validates check digits, auto-corrects common OCR character confusions
 * • Fallback: if mrz package parse fails (garbled MRZ), fall back to our own
 *   regex parser so the user still gets partial data
 * • Block lookup still uses input.closest() (fix from v2.1)
 * • Expiry year fix retained (2000+yr)
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * ─────────────────────────────────────────────────────────
 */

(function () {

  /* ══════════════════════════════════════════════════════════
     LOAD: Tesseract.js (OCR engine)
  ══════════════════════════════════════════════════════════ */

  let _tesseractReady = null;

  function ensureTesseract() {
    if (_tesseractReady) return _tesseractReady;
    _tesseractReady = new Promise((resolve, reject) => {
      if (window.Tesseract) { resolve(window.Tesseract); return; }
      const s = document.createElement('script');
      s.src = 'https://cdnjs.cloudflare.com/ajax/libs/tesseract.js/5.0.4/tesseract.min.js';
      s.onload = () => {
        let t = 0;
        const poll = setInterval(() => {
          if (window.Tesseract) { clearInterval(poll); resolve(window.Tesseract); }
          else if (++t > 40)   { clearInterval(poll); reject(new Error('Tesseract failed to load')); }
        }, 300);
      };
      s.onerror = () => reject(new Error('Tesseract CDN unreachable'));
      document.head.appendChild(s);
    });
    return _tesseractReady;
  }

  /* ══════════════════════════════════════════════════════════
     LOAD: mrz npm package via esm.sh
     Provides: parse(lines, { autocorrect: true })
     Returns structured fields with checksum validation.
  ══════════════════════════════════════════════════════════ */

  let _mrzReady = null;

  function ensureMrz() {
    if (_mrzReady) return _mrzReady;
    _mrzReady = import('https://esm.sh/mrz@5').then(mod => mod.default || mod.parse || mod);
    return _mrzReady;
  }

  // Begin loading both libraries immediately
  ensureTesseract().catch(() => {});
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
    el.textContent  = msg;
    el.classList.remove('hidden');
  }

  function hideStatus(el) {
    if (el) { el.classList.add('hidden'); el.textContent = ''; }
  }

  /* ══════════════════════════════════════════════════════════
     BLOCK LOOKUP — always via closest()
  ══════════════════════════════════════════════════════════ */

  function getBlock(input) {
    return input.closest('.traveler-adult-block, .traveler-child-block') || null;
  }

  /* ══════════════════════════════════════════════════════════
     FILL FIELD
  ══════════════════════════════════════════════════════════ */

  function fillField(el, value) {
    if (!el || value === undefined || value === null || String(value).trim() === '') return;
    el.value = String(value).trim();
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ══════════════════════════════════════════════════════════
     IMAGE PRE-PROCESSING — grayscale + contrast
  ══════════════════════════════════════════════════════════ */

  async function preprocess(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        try {
          const MAX = 2400;
          let { width: w, height: h } = img;
          if (w > MAX) { h = Math.round(h * MAX / w); w = MAX; }
          const c = document.createElement('canvas');
          c.width = w; c.height = h;
          const ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0, w, h);
          const d = ctx.getImageData(0, 0, w, h);
          for (let i = 0; i < d.data.length; i += 4) {
            let g = 0.299 * d.data[i] + 0.587 * d.data[i+1] + 0.114 * d.data[i+2];
            g = Math.min(255, Math.max(0, (g - 128) * 1.4 + 128));
            d.data[i] = d.data[i+1] = d.data[i+2] = g;
          }
          ctx.putImageData(d, 0, 0);
          c.toBlob(blob => { URL.revokeObjectURL(url); resolve(blob); }, 'image/png');
        } catch (e) { URL.revokeObjectURL(url); reject(e); }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('img load failed')); };
      img.src = url;
    });
  }

  /* ══════════════════════════════════════════════════════════
     TESSERACT RUNNER
  ══════════════════════════════════════════════════════════ */

  async function runOCR(file, lang) {
    const T    = await ensureTesseract();
    const blob = await preprocess(file);
    const res  = await T.recognize(blob, lang, { logger: () => {} });
    return res.data.text;
  }

  /* ══════════════════════════════════════════════════════════
     MRZ DATE HELPERS
  ══════════════════════════════════════════════════════════ */

  function mrzDateDOB(yymmdd) {
    if (!yymmdd || yymmdd.length !== 6) return null;
    const yr = parseInt(yymmdd.substring(0, 2));
    return `${yr < 30 ? 2000 + yr : 1900 + yr}-${yymmdd.substring(2,4)}-${yymmdd.substring(4,6)}`;
  }

  function mrzDateExpiry(yymmdd) {
    if (!yymmdd || yymmdd.length !== 6) return null;
    const yr = parseInt(yymmdd.substring(0, 2));
    return `${2000 + yr}-${yymmdd.substring(2,4)}-${yymmdd.substring(4,6)}`;
  }

  /* ══════════════════════════════════════════════════════════
     PASSPORT PARSER
     Strategy:
       1. Extract MRZ lines from Tesseract raw text
       2. Try mrz.parse() — gives validated, auto-corrected fields
       3. Fallback to hand-rolled regex parser if mrz.parse throws
  ══════════════════════════════════════════════════════════ */

  async function parsePassport(text) {
    const extracted = {};
    const lines     = text.split('\n').map(l => l.trim()).filter(Boolean);

    // Find MRZ lines: 30+ chars of A-Z, 0-9, <
    const mrzLines = lines.filter(l => /^[A-Z0-9<]{30,}$/.test(l.replace(/\s/g, '')))
                          .map(l => l.replace(/\s/g, ''));

    /* ── Try mrz npm package (best path) ── */
    if (mrzLines.length >= 2) {
      try {
        const mrzPkg = await ensureMrz();
        const parseFn = typeof mrzPkg === 'function' ? mrzPkg
                      : (mrzPkg.parse || mrzPkg.default?.parse);

        if (parseFn) {
          // Try TD3 (passport = 2 lines of 44)
          const td3Lines = mrzLines.filter(l => l.length === 44);
          if (td3Lines.length >= 2) {
            const result = parseFn([td3Lines[0], td3Lines[1]], { autocorrect: true });
            const f      = result.fields;

            if (f.documentNumber) extracted.passport_number = f.documentNumber;
            if (f.lastName && f.firstName) {
              extracted.full_name = `${f.firstName} ${f.lastName}`.replace(/\s+/g, ' ').trim();
            } else if (f.lastName) {
              extracted.full_name = f.lastName;
            }
            if (f.birthDate) extracted.date_of_birth  = mrzDateDOB(f.birthDate);
            if (f.expirationDate) extracted.expiry_date = mrzDateExpiry(f.expirationDate);
            if (f.sex) extracted.gender = f.sex;

            console.log('[OCR] mrz package result:', result);
            return extracted; // Return early — best possible parse
          }
        }
      } catch (e) {
        console.warn('[OCR] mrz package failed, falling back:', e.message);
      }
    }

    /* ── Fallback: hand-rolled MRZ parser ── */
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
      const namePart = mrz1.substring(5).split('<<');
      const surname  = (namePart[0] || '').replace(/</g, ' ').trim();
      const given    = (namePart[1] || '').replace(/</g, ' ').trim();
      extracted.full_name = [given, surname].filter(Boolean).join(' ');
    }

    /* ── Visible-zone fallbacks ── */
    if (!extracted.passport_number) {
      const vis = lines.filter(l => !l.includes('<')).join(' ');
      const m   = vis.match(/[A-Z]{1,2}[0-9]{6,8}/);
      if (m) extracted.passport_number = m[0];
    }

    if (!extracted.expiry_date) {
      const vis   = lines.filter(l => !l.includes('<')).join(' ');
      const hits  = vis.match(/(\d{2})[\/.\-](\d{2})[\/.\-](\d{4})/g) || [];
      const dates = hits.map(d => {
        const p = d.split(/[\/.\-]/);
        return `${p[2]}-${p[1]}-${p[0]}`;
      }).sort();
      if (dates.length) extracted.expiry_date = dates[dates.length - 1];
    }

    return extracted;
  }

  /* ══════════════════════════════════════════════════════════
     NID PARSER (Egyptian — 14 digits + Arabic name)
  ══════════════════════════════════════════════════════════ */

  const NID_LABEL_RE = /(?:الجمهورية|العربية|المصرية|بطاقة|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة|الإصدار|الانتهاء|وزارة|الداخلية|مصر|رقم|قومي)/;

  function parseNID(text) {
    const extracted = {};
    const noSpace   = text.replace(/\s+/g, '');

    const direct = noSpace.match(/[23]\d{13}/);
    const spaced = !direct && text.match(/([23](?:\s*\d){13})/);
    const nid    = direct ? direct[0] : (spaced ? spaced[0].replace(/\s/g, '') : null);

    if (nid && nid.length === 14) {
      extracted.national_id_number = nid;
      const century = nid[0] === '3' ? '20' : '19';
      const mm = nid.substring(3, 5), dd = nid.substring(5, 7);
      if (parseInt(mm) >= 1 && parseInt(mm) <= 12 && parseInt(dd) >= 1 && parseInt(dd) <= 31) {
        extracted.date_of_birth = `${century}${nid.substring(1,3)}-${mm}-${dd}`;
      }
    }

    const arabicLines = text.split('\n')
      .map(l => l.trim())
      .filter(l => /[\u0600-\u06FF]{3,}/.test(l) && !NID_LABEL_RE.test(l) && !/\d/.test(l));

    if (arabicLines.length > 0) {
      const best = arabicLines
        .map(l => ({ line: l, w: l.split(/\s+/).filter(w => /[\u0600-\u06FF]{2,}/.test(w)).length }))
        .filter(x => x.w >= 2)
        .sort((a, b) => Math.abs(a.w - 4) - Math.abs(b.w - 4))[0];
      if (best) extracted.full_name_arabic = best.line;
    }

    return extracted;
  }

  /* ══════════════════════════════════════════════════════════
     FILL FUNCTIONS
  ══════════════════════════════════════════════════════════ */

  function fillPassportFields(block, ex) {
    if (!block || !ex) return;
    if (ex.full_name)       fillField(block.querySelector('.t-name'),        ex.full_name);
    if (ex.passport_number) fillField(block.querySelector('.t-passport'),    ex.passport_number.toUpperCase());
    if (ex.expiry_date)     fillField(block.querySelector('.t-passport-exp'), ex.expiry_date);
  }

  function fillNIDFields(block, ex) {
    if (!block || !ex) return;
    const nameField = block.querySelector('.t-name');
    if (!nameField?.value && ex.full_name_arabic) fillField(nameField, ex.full_name_arabic);
    if (ex.national_id_number) fillField(block.querySelector('.t-nid'), ex.national_id_number);
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
      const statusId = `ocr_${docType === 'passport' ? 'passport' : 'nid'}_status_${idx}`;
      const statusEl = document.getElementById(statusId);

      if (file.type === 'application/pdf') {
        setStatus(statusEl, 'warning', '⚠️ ملفات PDF لا تدعم المسح — يرجى رفع صورة JPG/PNG للملء التلقائي');
        return;
      }
      if (!file.type.startsWith('image/')) return;

      setStatus(statusEl, 'loading', '🔍 جارٍ معالجة الصورة وقراءة البيانات…');

      try {
        if (docType === 'passport') {
          const raw       = await runOCR(file, 'eng');
          console.log('[OCR] raw passport text:', raw);
          const extracted = await parsePassport(raw);
          console.log('[OCR] passport fields:', extracted);
          fillPassportFields(block, extracted);
          const filled = [extracted.passport_number, extracted.expiry_date, extracted.full_name].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? `✅ تم استخراج ${filled.length} حقول — يرجى المراجعة قبل الإرسال`
              : '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
        } else {
          const raw       = await runOCR(file, 'eng+ara');
          console.log('[OCR] raw NID text:', raw);
          const extracted = parseNID(raw);
          console.log('[OCR] NID fields:', extracted);
          fillNIDFields(block, extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? `✅ تم استخراج ${filled.length} حقول — يرجى المراجعة قبل الإرسال`
              : '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
        }

        setTimeout(() => hideStatus(statusEl), 8000);
      } catch (err) {
        console.error('[OCR] Error:', err);
        setStatus(statusEl, 'error', '❌ تعذّر قراءة المستند — يرجى الإدخال اليدوي');
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
