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

    // Passport number: typically 1-2 letters followed by 6-7 digits (e.g. A12345678)
    const passportMatch = text.match(/\b([A-Z]{1,2}[0-9]{6,8})\b/);
    if (passportMatch) extracted.passport_number = passportMatch[1];

    // MRZ lines (bottom 2 lines of passport — most reliable source)
    // MRZ line 2 format: PASSPORT_NO + CHECK + NATIONALITY + DOB + CHECK + SEX + EXPIRY + CHECK
    const mrzLine = lines.find(l => /^[A-Z0-9<]{40,44}$/.test(l.replace(/\s/g, '')));
    if (mrzLine) {
      const mrz = mrzLine.replace(/\s/g, '');
      // Passport number from MRZ (chars 1-9)
      const mrzPassport = mrz.substring(0, 9).replace(/</g, '');
      if (mrzPassport) extracted.passport_number = mrzPassport;
      // DOB from MRZ (chars 14-19): YYMMDD
      const dobRaw = mrz.substring(13, 19);
      if (/^\d{6}$/.test(dobRaw)) {
        const yr = parseInt(dobRaw.substring(0, 2));
        const fullYr = yr > 30 ? 1900 + yr : 2000 + yr;
        extracted.date_of_birth = `${fullYr}-${dobRaw.substring(2,4)}-${dobRaw.substring(4,6)}`;
      }
      // Expiry from MRZ (chars 21-26): YYMMDD
      const expRaw = mrz.substring(20, 26);
      if (/^\d{6}$/.test(expRaw)) {
        const yr = parseInt(expRaw.substring(0, 2));
        const fullYr = yr > 30 ? 1900 + yr : 2000 + yr;
        extracted.expiry_date = `${fullYr}-${expRaw.substring(2,4)}-${expRaw.substring(4,6)}`;
      }
      // Gender from MRZ (char 21)
      const sex = mrz[20];
      if (sex === 'M' || sex === 'F') extracted.gender = sex;
    }

    // Fallback expiry date: look for date patterns like 01/01/2030 or 2030-01-01
    if (!extracted.expiry_date) {
      const dateMatch = text.match(/(\d{2})[\/\-\.](\d{2})[\/\-\.](\d{4})/g);
      if (dateMatch) {
        // Take the latest date as expiry
        const dates = dateMatch.map(d => {
          const parts = d.split(/[\/\-\.]/);
          return parts[2] ? `${parts[2]}-${parts[1]}-${parts[0]}` : null;
        }).filter(Boolean).sort();
        extracted.expiry_date = dates[dates.length - 1];
      }
    }

    // Name: look for "Surname / Given Names" pattern or name after "Name" label
    const nameMatch = text.match(/(?:Name|الاسم)[:\s]+([A-Z\s]+)/i);
    if (nameMatch) extracted.full_name = nameMatch[1].trim();

    return extracted;
  }

  function parseNID(text) {
    const extracted = {};

    // Egyptian NID: exactly 14 digits
    const nidMatch = text.match(/\b(\d{14})\b/);
    if (nidMatch) {
      extracted.national_id_number = nidMatch[1];
      // Derive DOB from NID: digits 2-7 = YYMMDD, digit 1 = century (2=1900s, 3=2000s)
      const century = nidMatch[1][0] === '3' ? '20' : '19';
      const yy = nidMatch[1].substring(1, 3);
      const mm = nidMatch[1].substring(3, 5);
      const dd = nidMatch[1].substring(5, 7);
      extracted.date_of_birth = `${century}${yy}-${mm}-${dd}`;
    }

    // Arabic name: look for Arabic text lines
    const arabicLines = text.split('\n')
      .map(l => l.trim())
      .filter(l => /[\u0600-\u06FF]/.test(l) && l.length > 3);
    if (arabicLines.length > 0) {
      // Usually the longest Arabic line is the full name
      extracted.full_name_arabic = arabicLines.sort((a, b) => b.length - a.length)[0];
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
