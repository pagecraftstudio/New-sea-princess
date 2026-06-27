/**
 * ocr.js — نيو سي برنسيس للسياحة  v2.0
 * OCR scanner for passport and national ID upload fields.
 * Uses Tesseract.js — runs entirely in the browser, no API key needed.
 *
 * Changes in v2.0
 * ───────────────
 * • Fixed ICAO TD3 MRZ field offsets (expiry at pos 21-26, sex at pos 20)
 * • Split OCR passes: English-only for passports (faster), Arabic for NID
 * • Canvas pre-processing: grayscale + contrast boost before OCR
 * • Extended Tesseract wait to 40 attempts (12 s) with a Promise-based load guard
 * • Improved NID digit extraction with more aggressive de-spacing
 * • Smarter Arabic name picker (filters known label words, picks best line)
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * ─────────────────────────────────────────────────────────
 */

(function () {

  /* ── Load Tesseract.js once, resolve a Promise when ready ── */
  let _tesseractReady = null;

  function ensureTesseract() {
    if (_tesseractReady) return _tesseractReady;
    _tesseractReady = new Promise((resolve, reject) => {
      if (window.Tesseract) { resolve(window.Tesseract); return; }
      const s = document.createElement('script');
      s.src = 'https://cdnjs.cloudflare.com/ajax/libs/tesseract.js/5.0.4/tesseract.min.js';
      s.onload  = () => {
        // Tesseract.js sets window.Tesseract after script executes
        let tries = 0;
        const poll = setInterval(() => {
          if (window.Tesseract) { clearInterval(poll); resolve(window.Tesseract); }
          else if (++tries > 40)  { clearInterval(poll); reject(new Error('Tesseract.js failed to load')); }
        }, 300);
      };
      s.onerror = () => reject(new Error('Tesseract.js CDN unreachable'));
      document.head.appendChild(s);
    });
    return _tesseractReady;
  }

  // Begin loading immediately so it's ready when the user picks a file
  ensureTesseract().catch(() => {});

  /* ── Status helper ──────────────────────────────────────── */

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

  /* ── Find traveler block by index ───────────────────────── */

  function getTravelerBlock(idx) {
    const blocks = document.querySelectorAll('.traveler-adult-block, .traveler-child-block');
    return blocks[idx] || null;
  }

  /* ── Fill a field and flash green ───────────────────────── */

  function fillField(el, value) {
    if (!el || !value) return;
    el.value = value;
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ── Canvas pre-processing: grayscale + contrast ────────── */
  // Improves Tesseract accuracy on camera photos and scanned images

  async function preprocessImage(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        try {
          // Scale down very large images to ≤2400px wide (keeps fine detail)
          const MAX = 2400;
          let { width: w, height: h } = img;
          if (w > MAX) { h = Math.round(h * MAX / w); w = MAX; }

          const canvas = document.createElement('canvas');
          canvas.width  = w;
          canvas.height = h;
          const ctx = canvas.getContext('2d');

          ctx.drawImage(img, 0, 0, w, h);

          // Convert to grayscale + boost contrast
          const imageData = ctx.getImageData(0, 0, w, h);
          const d = imageData.data;
          for (let i = 0; i < d.length; i += 4) {
            // Grayscale (luminosity method)
            let g = 0.299 * d[i] + 0.587 * d[i+1] + 0.114 * d[i+2];
            // Simple contrast stretch: push toward black/white
            g = Math.min(255, Math.max(0, (g - 128) * 1.4 + 128));
            d[i] = d[i+1] = d[i+2] = g;
          }
          ctx.putImageData(imageData, 0, 0);

          canvas.toBlob(blob => {
            URL.revokeObjectURL(url);
            resolve(blob);
          }, 'image/png');
        } catch (e) {
          URL.revokeObjectURL(url);
          reject(e);
        }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Image load failed')); };
      img.src = url;
    });
  }

  /* ── Run Tesseract ──────────────────────────────────────── */
  // lang: 'eng' for passports, 'eng+ara' for NIDs

  async function runOCR(file, lang) {
    const T       = await ensureTesseract();
    const cleaned = await preprocessImage(file);
    const result  = await T.recognize(cleaned, lang, { logger: () => {} });
    return result.data.text;
  }

  /* ══════════════════════════════════════════════════════════
     PASSPORT PARSER
     ICAO Doc 9303 TD3 MRZ layout (line 2, 44 chars):
       [0-8]  Passport number        (9 chars)
       [9]    Check digit
       [10-14] Nationality           (5 chars, EGY + <<)
       [13-18] Date of birth YYMMDD  ← positions 13-18
       [19]   Check digit
       [20]   Sex (M/F/<)
       [21-26] Expiry date YYMMDD    ← positions 21-26
       [27]   Check digit
       [28-42] Personal number / filler
  ══════════════════════════════════════════════════════════ */

  function parsePassport(text) {
    const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
    const extracted = {};

    // ── Identify MRZ lines (30+ chars of A-Z 0-9 <) ─────────
    const mrzLines = lines.filter(l => /^[A-Z0-9<]{30,}$/.test(l.replace(/\s/g, '')));

    // Line 2: contains DOB + sex + expiry in predictable positions
    const mrz2 = mrzLines.find(l => {
      const m = l.replace(/\s/g, '');
      // Must be ≥ 44 chars and have a 6-digit DOB pattern around pos 13
      return m.length >= 40 && /\d{6}[0-9][MF<]\d{6}/.test(m.substring(13, 28));
    });

    if (mrz2) {
      const mrz = mrz2.replace(/\s/g, '');

      // Passport number: positions 0-8
      const pNo = mrz.substring(0, 9).replace(/</g, '');
      if (pNo) extracted.passport_number = pNo;

      // Date of birth: positions 13-18
      const dobRaw = mrz.substring(13, 19);
      if (/^\d{6}$/.test(dobRaw)) {
        const yr = parseInt(dobRaw.substring(0, 2));
        extracted.date_of_birth = `${yr > 30 ? 1900 + yr : 2000 + yr}-${dobRaw.substring(2, 4)}-${dobRaw.substring(4, 6)}`;
      }

      // Sex: position 20 (after DOB 13-18 + check digit 19)
      const sex = mrz[20];
      if (sex === 'M' || sex === 'F') extracted.gender = sex;

      // Expiry date: positions 21-26
      const expRaw = mrz.substring(21, 27);
      if (/^\d{6}$/.test(expRaw)) {
        const yr = parseInt(expRaw.substring(0, 2));
        extracted.expiry_date = `${yr > 30 ? 1900 + yr : 2000 + yr}-${expRaw.substring(2, 4)}-${expRaw.substring(4, 6)}`;
      }
    }

    // Line 1: P<EGY<SURNAME<<GIVEN<NAMES<<...
    const mrz1 = mrzLines.find(l => /^P[A-Z<]/.test(l.replace(/\s/g, '')));
    if (mrz1) {
      const mrz = mrz1.replace(/\s/g, '');
      // Name starts at char 5 (after P, type, country code EGY)
      const namePart  = mrz.substring(5).split('<<');
      const surname   = (namePart[0] || '').replace(/</g, ' ').trim();
      const givenName = (namePart[1] || '').replace(/</g, ' ').trim();
      extracted.full_name = givenName && surname ? `${givenName} ${surname}` : (surname || givenName);
    }

    // ── Fallbacks for when MRZ wasn't found / OCR garbled it ─

    // Passport number from visible data zone (no < chars)
    if (!extracted.passport_number) {
      const vis = lines.filter(l => !l.includes('<')).join(' ');
      const m   = vis.match(/[A-Z]{1,2}[0-9]{6,8}/);
      if (m) extracted.passport_number = m[0];
    }

    // Expiry date from visible printed dates (take the latest one)
    if (!extracted.expiry_date) {
      const vis  = lines.filter(l => !l.includes('<')).join(' ');
      const hits = vis.match(/(\d{2})[\/.\-](\d{2})[\/.\-](\d{4})/g) || [];
      const dates = hits.map(d => {
        const p = d.split(/[\/.\-]/);
        return `${p[2]}-${p[1]}-${p[0]}`;
      }).sort();
      if (dates.length) extracted.expiry_date = dates[dates.length - 1];
    }

    return extracted;
  }

  /* ══════════════════════════════════════════════════════════
     NATIONAL ID PARSER (Egyptian NID — 14 digits)
     Format: C YY MM DD GG SSS X
       C   = century (2 = 1900s, 3 = 2000s)
       YY  = birth year
       MM  = birth month
       DD  = birth day
       GG  = governorate code
       SSS = sequence
       X   = check digit
  ══════════════════════════════════════════════════════════ */

  function parseNID(text) {
    const extracted = {};

    // Remove all whitespace and look for 14-digit sequence starting with 2 or 3
    const noSpace   = text.replace(/\s+/g, '');
    let nidCandidate = null;

    const directMatch = noSpace.match(/[23]\d{13}/);
    if (directMatch) {
      nidCandidate = directMatch[0];
    } else {
      // Tesseract sometimes inserts spaces in long digit runs — try with spaces
      const spacedMatch = text.match(/([23](?:\s*\d){13})/);
      if (spacedMatch) nidCandidate = spacedMatch[0].replace(/\s/g, '');
    }

    if (nidCandidate && nidCandidate.length === 14) {
      extracted.national_id_number = nidCandidate;
      const century = nidCandidate[0] === '3' ? '20' : '19';
      const yy = nidCandidate.substring(1, 3);
      const mm = nidCandidate.substring(3, 5);
      const dd = nidCandidate.substring(5, 7);
      // Basic sanity: month 01-12, day 01-31
      if (parseInt(mm) >= 1 && parseInt(mm) <= 12 &&
          parseInt(dd) >= 1 && parseInt(dd) <= 31) {
        extracted.date_of_birth = `${century}${yy}-${mm}-${dd}`;
      }
    }

    // Arabic name: find lines with ≥ 4 Arabic chars that aren't label text
    const LABEL_RE = /(?:الجمهورية|العربية|المصرية|بطاقة|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة|الإصدار|الانتهاء|وزارة|الداخلية)/;
    const arabicLines = text.split('\n')
      .map(l => l.trim())
      .filter(l => /[\u0600-\u06FF]{4,}/.test(l) && !LABEL_RE.test(l));

    if (arabicLines.length > 0) {
      // Egyptian full names are typically 3-4 words; pick closest to that
      const nameLine = arabicLines.sort((a, b) => {
        const aW = a.split(/\s+/).filter(w => /[\u0600-\u06FF]/.test(w)).length;
        const bW = b.split(/\s+/).filter(w => /[\u0600-\u06FF]/.test(w)).length;
        return Math.abs(aW - 4) - Math.abs(bW - 4);
      })[0];
      extracted.full_name_arabic = nameLine;
    }

    return extracted;
  }

  /* ── Auto-fill fields ───────────────────────────────────── */

  function fillPassportFields(block, extracted) {
    if (!block || !extracted) return;
    const nameField    = block.querySelector('.t-name');
    const passportField = block.querySelector('.t-passport');
    const expiryField  = block.querySelector('.t-passport-exp');

    if (!nameField?.value && extracted.full_name)
      fillField(nameField, extracted.full_name);
    if (extracted.passport_number)
      fillField(passportField, extracted.passport_number.toUpperCase());
    if (extracted.expiry_date) {
      fillField(expiryField, extracted.expiry_date);
      expiryField?.dispatchEvent(new Event('input', { bubbles: true }));
    }
  }

  function fillNIDFields(block, extracted) {
    if (!block || !extracted) return;
    const nameField = block.querySelector('.t-name');
    const nidField  = block.querySelector('.t-nid');

    if (!nameField?.value && extracted.full_name_arabic)
      fillField(nameField, extracted.full_name_arabic);
    if (extracted.national_id_number)
      fillField(nidField, extracted.national_id_number);
  }

  /* ── Attach OCR listener to a file input ────────────────── */

  function attachOCRToInput(input, docType) {
    input.addEventListener('change', async function () {
      const file = this.files?.[0];
      if (!file) return;

      const idx      = parseInt(this.dataset.travelerIdx ?? '0', 10);
      const statusId = `ocr_${docType === 'passport' ? 'passport' : 'nid'}_status_${idx}`;
      const statusEl = document.getElementById(statusId);
      const block    = getTravelerBlock(idx);

      if (file.type === 'application/pdf') {
        setStatus(statusEl, 'warning', '⚠️ ملفات PDF لا تدعم المسح — يرجى رفع صورة JPG/PNG للملء التلقائي');
        return;
      }
      if (!file.type.startsWith('image/')) return;

      setStatus(statusEl, 'loading', '🔍 جارٍ معالجة الصورة وقراءة البيانات…');

      try {
        // Passport: English-only OCR (faster, MRZ is pure Latin)
        // NID:      English + Arabic (need Arabic for name extraction)
        const lang    = docType === 'passport' ? 'eng' : 'eng+ara';
        const rawText = await runOCR(file, lang);

        console.log('[OCR] Raw text:', rawText);

        if (docType === 'passport') {
          const extracted = parsePassport(rawText);
          console.log('[OCR] Passport extracted:', extracted);
          fillPassportFields(block, extracted);
          const filled = [extracted.passport_number, extracted.expiry_date, extracted.full_name].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال'
              : '⚠️ لم يتمكن النظام من قراءة البيانات بوضوح — يرجى الإدخال يدوياً');
        } else {
          const extracted = parseNID(rawText);
          console.log('[OCR] NID extracted:', extracted);
          fillNIDFields(block, extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال'
              : '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
        }

        setTimeout(() => hideStatus(statusEl), 8000);

      } catch (err) {
        console.error('[OCR] Error:', err);
        setStatus(statusEl, 'error', '❌ تعذّر قراءة المستند — يرجى الإدخال اليدوي');
      }
    });
  }

  /* ── MutationObserver: attach to dynamically added inputs ── */

  function scanAndAttach() {
    document.querySelectorAll('.ocr-passport-input:not([data-ocr-attached])').forEach(input => {
      input.setAttribute('data-ocr-attached', '1');
      attachOCRToInput(input, 'passport');
    });
    document.querySelectorAll('.ocr-nid-input:not([data-ocr-attached])').forEach(input => {
      input.setAttribute('data-ocr-attached', '1');
      attachOCRToInput(input, 'national_id');
    });
  }

  const observer = new MutationObserver(scanAndAttach);
  observer.observe(document.body, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', scanAndAttach);

})();
