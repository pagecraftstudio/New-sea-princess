/**
 * ocr.js — نيو سي برنسيس للسياحة  v2.1
 * OCR scanner for passport and national ID upload fields.
 * Uses Tesseract.js — runs entirely in the browser, no API key needed.
 *
 * Fixes in v2.1
 * ─────────────
 * • Block lookup: use input.closest() instead of global DOM index — fixes NID fill
 * • Expiry year: always 2000+yr for passport expiry (passports never expire in 1900s)
 * • DOB year:    yr < 30 → 2000s, else 1900s (correct for people born before 2030)
 * • Name fill:   always write name from OCR; don't skip if field already has a value
 *                (user may have typed placeholder text; OCR result is more accurate)
 * • NID Arabic name: stricter label filter + min-score threshold to avoid picking
 *                    header lines ("الجمهورية العربية المصرية") when no real name found
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
      s.onload = () => {
        let tries = 0;
        const poll = setInterval(() => {
          if (window.Tesseract) { clearInterval(poll); resolve(window.Tesseract); }
          else if (++tries > 40) { clearInterval(poll); reject(new Error('Tesseract.js failed to load')); }
        }, 300);
      };
      s.onerror = () => reject(new Error('Tesseract.js CDN unreachable'));
      document.head.appendChild(s);
    });
    return _tesseractReady;
  }

  // Begin loading immediately so it is ready before user picks a file
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

  /* ── Find the traveler block that owns this input ───────── */
  // Using closest() is always correct regardless of how many blocks exist.
  // The old getTravelerBlock(idx) used a global querySelectorAll index which
  // broke when file inputs were inside the block (it would still find the right
  // block by coincidence for 1 traveler, but silently failed for edge cases).

  function getBlockForInput(input) {
    return input.closest('.traveler-adult-block, .traveler-child-block') || null;
  }

  /* ── Set a field value and flash green ──────────────────── */

  function fillField(el, value) {
    if (!el || value === undefined || value === null || value === '') return;
    el.value = value;
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ── Canvas pre-processing: grayscale + contrast boost ──── */

  async function preprocessImage(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        try {
          const MAX = 2400;
          let { width: w, height: h } = img;
          if (w > MAX) { h = Math.round(h * MAX / w); w = MAX; }

          const canvas = document.createElement('canvas');
          canvas.width  = w;
          canvas.height = h;
          const ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0, w, h);

          const imageData = ctx.getImageData(0, 0, w, h);
          const d = imageData.data;
          for (let i = 0; i < d.length; i += 4) {
            let g = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
            g = Math.min(255, Math.max(0, (g - 128) * 1.4 + 128));
            d[i] = d[i + 1] = d[i + 2] = g;
          }
          ctx.putImageData(imageData, 0, 0);

          canvas.toBlob(blob => { URL.revokeObjectURL(url); resolve(blob); }, 'image/png');
        } catch (e) { URL.revokeObjectURL(url); reject(e); }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Image load failed')); };
      img.src = url;
    });
  }

  /* ── Run Tesseract ──────────────────────────────────────── */

  async function runOCR(file, lang) {
    const T       = await ensureTesseract();
    const cleaned = await preprocessImage(file);
    const result  = await T.recognize(cleaned, lang, { logger: () => {} });
    return result.data.text;
  }

  /* ══════════════════════════════════════════════════════════
     MRZ YEAR HELPER
     ─────────────────────────────────────────────────────────
     Passport EXPIRY:  always in the future → always 2000 + yr.
     Date of BIRTH:    yr ≥ current 2-digit year means person born in 1900s;
                       yr <  current 2-digit year means born in 2000s.
                       (Threshold: yr < 30 → 2000s, else 1900s is a safe
                        approximation until 2030.)
  ══════════════════════════════════════════════════════════ */

  function mrzYearDOB(yr) {
    return (yr < 30 ? 2000 : 1900) + yr;
  }

  function mrzYearExpiry(yr) {
    // Passports expire in the future — always 2000s
    return 2000 + yr;
  }

  function mrzDate(raw, isExpiry) {
    if (!/^\d{6}$/.test(raw)) return null;
    const yr = parseInt(raw.substring(0, 2));
    const mm = raw.substring(2, 4);
    const dd = raw.substring(4, 6);
    const year = isExpiry ? mrzYearExpiry(yr) : mrzYearDOB(yr);
    return `${year}-${mm}-${dd}`;
  }

  /* ══════════════════════════════════════════════════════════
     PASSPORT PARSER
     ICAO TD3 MRZ line 2 layout (44 chars):
       [0-8]   Passport number
       [9]     Check digit
       [10-12] Nationality (EGY)
       [13-18] DOB  YYMMDD
       [19]    Check digit
       [20]    Sex  M/F/<
       [21-26] Expiry YYMMDD
       [27]    Check digit
       [28-42] Personal number / filler
  ══════════════════════════════════════════════════════════ */

  function parsePassport(text) {
    const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
    const extracted = {};

    // Identify MRZ lines: 30+ consecutive A-Z 0-9 < chars
    const mrzLines = lines.filter(l => /^[A-Z0-9<]{30,}$/.test(l.replace(/\s/g, '')));

    // Line 2: contains DOB(13-18) + check(19) + sex(20) + expiry(21-26)
    const mrz2 = mrzLines.find(l => {
      const m = l.replace(/\s/g, '');
      return m.length >= 40 && /\d{6}[0-9][MF<]\d{6}/.test(m.substring(13, 28));
    });

    if (mrz2) {
      const mrz = mrz2.replace(/\s/g, '');

      // Passport number: pos 0-8
      const pNo = mrz.substring(0, 9).replace(/</g, '');
      if (pNo) extracted.passport_number = pNo;

      // DOB: pos 13-18
      extracted.date_of_birth = mrzDate(mrz.substring(13, 19), false);

      // Sex: pos 20
      const sex = mrz[20];
      if (sex === 'M' || sex === 'F') extracted.gender = sex;

      // Expiry: pos 21-26 (always future → mrzYearExpiry)
      extracted.expiry_date = mrzDate(mrz.substring(21, 27), true);
    }

    // Line 1: P<EGY<SURNAME<<GIVEN<<...
    const mrz1 = mrzLines.find(l => /^P[A-Z<]/.test(l.replace(/\s/g, '')));
    if (mrz1) {
      const mrz      = mrz1.replace(/\s/g, '');
      const namePart = mrz.substring(5).split('<<');
      const surname  = (namePart[0] || '').replace(/</g, ' ').trim();
      const given    = (namePart[1] || '').replace(/</g, ' ').trim();
      if (surname || given) {
        extracted.full_name = [given, surname].filter(Boolean).join(' ');
      }
    }

    // Fallback: passport number from visible zone (no < chars)
    if (!extracted.passport_number) {
      const vis = lines.filter(l => !l.includes('<')).join(' ');
      const m   = vis.match(/[A-Z]{1,2}[0-9]{6,8}/);
      if (m) extracted.passport_number = m[0];
    }

    // Fallback: expiry from printed dates — take the latest date (most likely expiry)
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
     NATIONAL ID PARSER  (Egyptian NID — 14 digits)
     Format: C YY MM DD GG SSS X
       C   = century marker (2 = 1900s, 3 = 2000s)
       YYMMDD = birth date
       GG  = governorate code (01-35)
       SSS = sequence
       X   = check digit
  ══════════════════════════════════════════════════════════ */

  // Labels that appear on the NID card — never part of the holder's name
  const NID_LABEL_RE = /(?:الجمهورية|العربية|المصرية|بطاقة|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة|الإصدار|الانتهاء|وزارة|الداخلية|مصر|رقم|قومي)/;

  function parseNID(text) {
    const extracted = {};

    // Remove all whitespace and find 14-digit NID starting with 2 or 3
    const noSpace     = text.replace(/\s+/g, '');
    let nidCandidate  = null;

    const directMatch = noSpace.match(/[23]\d{13}/);
    if (directMatch) {
      nidCandidate = directMatch[0];
    } else {
      // Tesseract sometimes inserts spaces inside long digit runs
      const spacedMatch = text.match(/([23](?:\s*\d){13})/);
      if (spacedMatch) nidCandidate = spacedMatch[0].replace(/\s/g, '');
    }

    if (nidCandidate && nidCandidate.length === 14) {
      extracted.national_id_number = nidCandidate;
      // Extract birth date from NID digits
      const century = nidCandidate[0] === '3' ? '20' : '19';
      const yy = nidCandidate.substring(1, 3);
      const mm = nidCandidate.substring(3, 5);
      const dd = nidCandidate.substring(5, 7);
      if (parseInt(mm) >= 1 && parseInt(mm) <= 12 &&
          parseInt(dd) >= 1 && parseInt(dd) <= 31) {
        extracted.date_of_birth = `${century}${yy}-${mm}-${dd}`;
      }
    }

    // Arabic name: collect lines that look like a person's name
    const arabicLines = text.split('\n')
      .map(l => l.trim())
      .filter(l => {
        if (!/[\u0600-\u06FF]{3,}/.test(l)) return false;  // must have Arabic chars
        if (NID_LABEL_RE.test(l))           return false;  // skip card labels
        if (/\d/.test(l))                   return false;  // skip lines with digits
        return true;
      });

    if (arabicLines.length > 0) {
      // Score each line: prefer 3-4 Arabic words (typical full name length)
      // Require at least 2 Arabic words to avoid picking single-word labels
      const scored = arabicLines
        .map(l => {
          const words = l.split(/\s+/).filter(w => /[\u0600-\u06FF]{2,}/.test(w));
          return { line: l, words: words.length };
        })
        .filter(x => x.words >= 2)   // must be at least 2 words
        .sort((a, b) => Math.abs(a.words - 4) - Math.abs(b.words - 4));

      if (scored.length > 0) {
        extracted.full_name_arabic = scored[0].line;
      }
    }

    return extracted;
  }

  /* ── Fill passport fields in the traveler block ─────────── */

  function fillPassportFields(block, extracted) {
    if (!block || !extracted) return;
    const nameField    = block.querySelector('.t-name');
    const passportField = block.querySelector('.t-passport');
    const expiryField  = block.querySelector('.t-passport-exp');

    // Always fill name from OCR if we got one (OCR result > typed placeholder)
    if (extracted.full_name)
      fillField(nameField, extracted.full_name);

    if (extracted.passport_number)
      fillField(passportField, extracted.passport_number.toUpperCase());

    if (extracted.expiry_date)
      fillField(expiryField, extracted.expiry_date);
  }

  /* ── Fill NID fields in the traveler block ──────────────── */

  function fillNIDFields(block, extracted) {
    if (!block || !extracted) return;
    const nameField = block.querySelector('.t-name');
    const nidField  = block.querySelector('.t-nid');

    // Fill name only if we found a valid Arabic name AND the field is empty
    // (passport OCR name takes priority; don't overwrite it with NID name)
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

      // Find the block via DOM ancestry — reliable regardless of traveler count
      const block    = getBlockForInput(this);
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
        // Passport: English-only (MRZ is pure Latin — faster, more accurate)
        // NID:      English + Arabic (need Arabic for name line)
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
              ? `✅ تم استخراج البيانات (${filled.length} حقول) — يرجى المراجعة قبل الإرسال`
              : '⚠️ لم يتمكن النظام من قراءة البيانات بوضوح — يرجى الإدخال يدوياً');
        } else {
          const extracted = parseNID(rawText);
          console.log('[OCR] NID extracted:', extracted);
          fillNIDFields(block, extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          setStatus(statusEl, filled.length ? 'success' : 'warning',
            filled.length
              ? `✅ تم استخراج البيانات (${filled.length} حقول) — يرجى المراجعة قبل الإرسال`
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