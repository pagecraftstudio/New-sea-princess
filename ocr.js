/**
 * ocr.js — نيو سي برنسيس للسياحة
 * OCR scanner for passport and national ID upload fields.
 * Uses Tesseract.js — runs entirely in the browser, no API key needed.
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

(function () {

  /* ── Load Tesseract.js from CDN ─────────────────────────── */
  (function loadTesseract() {
    if (window.Tesseract) return;
    const s = document.createElement('script');
    s.src = 'https://cdnjs.cloudflare.com/ajax/libs/tesseract.js/5.0.4/tesseract.min.js';
    s.async = true;
    document.head.appendChild(s);
  })();

  /* ── Helpers ────────────────────────────────────────────── */

  function setStatus(el, type, msg) {
    if (!el) return;
    const styles = {
      loading : 'background:#EFF6FF;border:1px solid #BFDBFE;color:#1D4ED8',
      success : 'background:#F0FDF4;border:1px solid #BBF7D0;color:#15803D',
      error   : 'background:#FEF2F2;border:1px solid #FECACA;color:#B91C1C',
      warning : 'background:#FFFBEB;border:1px solid #FDE68A;color:#B45309',
    };
    el.style.cssText = `${styles[type]};border-radius:6px;padding:6px 10px;font-size:12px;font-family:'Cairo',sans-serif;`;
    el.textContent = msg;
    el.classList.remove('hidden');
  }

  function hideStatus(el) {
    if (el) { el.classList.add('hidden'); el.textContent = ''; }
  }

  /* Find the traveler block by index */
  function getTravelerBlock(idx) {
    const blocks = document.querySelectorAll('.traveler-adult-block, .traveler-child-block');
    return blocks[idx] || null;
  }

  /* Safely set a field value and flash it green */
  function fillField(el, value) {
    if (!el || !value) return;
    el.value = value;
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ── Tesseract OCR ──────────────────────────────────────── */

  async function waitForTesseract() {
    let attempts = 0;
    while (!window.Tesseract && attempts < 20) {
      await new Promise(r => setTimeout(r, 300));
      attempts++;
    }
    if (!window.Tesseract) throw new Error('Tesseract.js failed to load');
  }

  async function runOCR(file) {
    await waitForTesseract();

    // Run with English + Arabic language packs for best passport/NID coverage
    const result = await Tesseract.recognize(file, 'eng+ara', {
      logger: () => {} // suppress progress logs
    });

    return result.data.text;
  }

  /* ── Text Parsers ───────────────────────────────────────── */

  function parsePassport(text) {
    const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
    const extracted = {};

    // ── Identify MRZ lines: 44-char lines of A-Z, 0-9, < ───────────
    // Egyptian passport MRZ is 2 lines of 44 chars each
    const mrzLines = lines.filter(l => /^[A-Z0-9<]{30,}$/.test(l.replace(/\s/g, '')));

    // MRZ line 2 contains: passport no, nationality, DOB, sex, expiry
    const mrz2 = mrzLines.find(l => l.replace(/\s/g,'').length >= 40 && /\d{6}[02FM]\d{6}/.test(l.replace(/\s/g,'')));
    if (mrz2) {
      const mrz = mrz2.replace(/\s/g, '');
      const mrzPassport = mrz.substring(0, 9).replace(/</g, '');
      if (mrzPassport) extracted.passport_number = mrzPassport;

      const dobRaw = mrz.substring(13, 19);
      if (/^\d{6}$/.test(dobRaw)) {
        const yr = parseInt(dobRaw.substring(0, 2));
        extracted.date_of_birth = `${yr > 30 ? 1900+yr : 2000+yr}-${dobRaw.substring(2,4)}-${dobRaw.substring(4,6)}`;
      }
      const expRaw = mrz.substring(20, 26);
      if (/^\d{6}$/.test(expRaw)) {
        const yr = parseInt(expRaw.substring(0, 2));
        extracted.expiry_date = `${yr > 30 ? 1900+yr : 2000+yr}-${expRaw.substring(2,4)}-${expRaw.substring(4,6)}`;
      }
      const sex = mrz[20];
      if (sex === 'M' || sex === 'F') extracted.gender = sex;
    }

    // MRZ line 1 contains the name — format: P<EGY<SURNAME<<GIVEN<NAMES<<<...
    const mrz1 = mrzLines.find(l => /^P[A-Z<]/.test(l.replace(/\s/g,'')));
    if (mrz1) {
      const mrz = mrz1.replace(/\s/g, '');
      // Name section starts at char 5, separated by <<
      const namePart = mrz.substring(5).split('<<');
      const surname   = (namePart[0] || '').replace(/</g, ' ').trim();
      const givenName = (namePart[1] || '').replace(/</g, ' ').trim();
      if (surname && givenName) extracted.full_name = `${givenName} ${surname}`;
      else if (surname)         extracted.full_name = surname;
    }

    // Fallback passport number from visible area (not MRZ)
    if (!extracted.passport_number) {
      // Non-MRZ lines only (exclude lines with lots of < chars)
      const visibleText = lines.filter(l => !l.includes('<')).join(' ');
      const m = visibleText.match(/[A-Z]{1,2}[0-9]{6,8}/);
      if (m) extracted.passport_number = m[0];
    }

    // Fallback expiry date from visible printed dates
    if (!extracted.expiry_date) {
      const visibleText = lines.filter(l => !l.includes('<')).join(' ');
      const dateMatches = visibleText.match(/(\d{2})[\/\.\-](\d{2})[\/\.\-](\d{4})/g) || [];
      const dates = dateMatches.map(d => {
        const p = d.split(/[\/\.\-]/);
        return `${p[2]}-${p[1]}-${p[0]}`;
      }).sort();
      if (dates.length) extracted.expiry_date = dates[dates.length - 1];
    }

    return extracted;
  }

  function parseNID(text) {
    const extracted = {};

    // Strip all whitespace and look for 14 consecutive digits anywhere
    // Tesseract sometimes inserts spaces inside long number sequences
    const digitsOnly = text.replace(/\s+/g, '');
    const nidMatch = digitsOnly.match(/[23]\d{13}/); // Egyptian NID starts with 2 or 3
    if (nidMatch) {
      extracted.national_id_number = nidMatch[0];
      const n = nidMatch[0];
      const century = n[0] === '3' ? '20' : '19';
      extracted.date_of_birth = `${century}${n.substring(1,3)}-${n.substring(3,5)}-${n.substring(5,7)}`;
    } else {
      // Fallback: try to find 14 digits even with spaces between them
      const spacedMatch = text.match(/([23](?:\s*\d){13})/);
      if (spacedMatch) {
        const n = spacedMatch[0].replace(/\s/g, '');
        extracted.national_id_number = n;
        const century = n[0] === '3' ? '20' : '19';
        extracted.date_of_birth = `${century}${n.substring(1,3)}-${n.substring(3,5)}-${n.substring(5,7)}`;
      }
    }

    // Arabic name: collect Arabic lines, exclude lines that are just labels
    const arabicLabels = /(?:الجمهورية|العربية|المصرية|بطاقة|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة)/;
    const arabicLines = text.split('\n')
      .map(l => l.trim())
      .filter(l => /[\u0600-\u06FF]{4,}/.test(l) && !arabicLabels.test(l));

    if (arabicLines.length > 0) {
      // Name is usually 3-4 Arabic words — pick the line that looks most like a name
      const nameLine = arabicLines
        .sort((a, b) => {
          const aWords = a.split(/\s+/).filter(w => /[\u0600-\u06FF]/.test(w)).length;
          const bWords = b.split(/\s+/).filter(w => /[\u0600-\u06FF]/.test(w)).length;
          // Prefer lines with 3-5 Arabic words (typical full name length)
          const aScore = Math.abs(aWords - 4);
          const bScore = Math.abs(bWords - 4);
          return aScore - bScore;
        })[0];
      extracted.full_name_arabic = nameLine;
    }

    return extracted;
  }

  /* ── Auto-fill logic ────────────────────────────────────── */

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

  /* ── Event attachment ───────────────────────────────────── */

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

      setStatus(statusEl, 'loading', '🔍 جارٍ قراءة المستند… (قد يستغرق بضع ثوانٍ)');

      try {
        const rawText  = await runOCR(file);
        const extracted = docType === 'passport' ? parsePassport(rawText) : parseNID(rawText);

        console.log('[OCR] Raw text:', rawText);
        console.log('[OCR] Extracted:', extracted);

        if (docType === 'passport') {
          fillPassportFields(block, extracted);
          const filled = [extracted.passport_number, extracted.expiry_date, extracted.full_name].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال');
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات بوضوح — يرجى الإدخال يدوياً');
          }
        } else {
          fillNIDFields(block, extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال');
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
          }
        }

        setTimeout(() => hideStatus(statusEl), 8000);

      } catch (err) {
        console.error('[OCR] Error:', err);
        setStatus(statusEl, 'error', '❌ تعذّر قراءة المستند — يرجى الإدخال اليدوي');
      }
    });
  }

  /* ── Observer: attach OCR to dynamically added inputs ───── */

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
