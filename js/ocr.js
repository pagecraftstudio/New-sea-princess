/**
 * ocr.js — نيو سي برنسيس للسياحة
 * OCR scanner for passport and national ID upload fields.
 *
 * Sends the uploaded image to our /api/ocr-scan serverless endpoint, which
 * calls Google Cloud Vision's DOCUMENT_TEXT_DETECTION. Replaces the previous
 * client-side Tesseract.js pipeline, which was unreliable on the
 * Arabic-Indic numerals (٠-٩) printed on Egyptian national ID cards.
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

(function () {

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

  /* ── Per-traveler OCR data store ───────────────────────── */
  // Stores extracted data per traveler index so we can cross-check once both docs scanned
  const ocrStore = {}; // { [idx]: { passport: {...}, nid: {...} } }

  function storeOCR(idx, docType, data) {
    if (!ocrStore[idx]) ocrStore[idx] = {};
    ocrStore[idx][docType === 'passport' ? 'passport' : 'nid'] = data;
  }

  /* ── Cross-document validation ──────────────────────────── */

  function crossCheckDocuments(idx) {
    const store = ocrStore[idx];
    if (!store?.passport || !store?.nid) return; // need both to compare

    const warnings = [];
    const passport = store.passport;
    const nid      = store.nid;

    // ── 1. Date of birth check ───────────────────────────────
    if (passport.date_of_birth && nid.date_of_birth) {
      if (passport.date_of_birth !== nid.date_of_birth) {
        warnings.push(
          `📅 تاريخ الميلاد غير متطابق — الجواز: ${passport.date_of_birth} | البطاقة: ${nid.date_of_birth}`
        );
      }
    }

    // ── 2. Gender check (NID encodes gender in digit 13: odd=M, even=F) ──
    if (passport.gender && nid.national_id_number) {
      const nidGenderDigit = parseInt(nid.national_id_number[12]);
      const nidGender = nidGenderDigit % 2 !== 0 ? 'M' : 'F';
      if (passport.gender !== nidGender) {
        warnings.push(
          `⚧ الجنس غير متطابق — الجواز: ${passport.gender === 'M' ? 'ذكر' : 'أنثى'} | البطاقة: ${nidGender === 'M' ? 'ذكر' : 'أنثى'}`
        );
      }
    }

    // ── 3. Name similarity check (transliteration-aware) ────
    // Compare Latin passport name with Arabic NID name phonetically
    // We normalize common Arabic→Latin sound mappings for comparison
    if (passport.full_name && nid.full_name_arabic) {
      const latinNormalized  = passport.full_name.toLowerCase()
        .replace(/ou|oo/g, 'u').replace(/ph/g, 'f')
        .replace(/ck/g, 'k').replace(/[aeiou]/g, '')  // strip vowels
        .replace(/\s+/g, '');

      // Rough Arabic consonant map → Latin for comparison.
      // (Fixed: 'م' and 'د' were each listed twice in the original map, silently
      // dropping a mapping — every key below now appears exactly once.)
      const arabicToLatin = {
        'م':'m','ح':'h','د':'d','ع':'a','ب':'b',
        'أ':'a','إ':'i','ا':'a','ى':'a','ة':'h','ت':'t','ن':'n',
        'ر':'r','س':'s','ي':'y','و':'w','ك':'k','ل':'l','ف':'f',
        'ق':'q','ز':'z','خ':'kh','ش':'sh','ص':'s','ض':'d',
        'ط':'t','ظ':'z','غ':'gh','ج':'g','ث':'th','ذ':'z','ء':'a'
      };
      const arabicNormalized = nid.full_name_arabic
        .split('').map(c => arabicToLatin[c] || '').join('')
        .replace(/[aeiou]/g, '').replace(/\s+/g, '');

      // The original check compared consonants index-by-index, which lets two
      // unrelated names "match" by coincidental alignment (especially on short
      // strings) and is thrown off by any extra/missing letter shifting the rest
      // out of alignment. Instead, score by longest common subsequence (LCS),
      // which tolerates re-ordering/transliteration drift but still correctly
      // separates names that don't share most of their consonants.
      function lcsLength(a, b) {
        const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
        for (let i = 1; i <= a.length; i++) {
          for (let j = 1; j <= b.length; j++) {
            dp[i][j] = a[i-1] === b[j-1] ? dp[i-1][j-1] + 1 : Math.max(dp[i-1][j], dp[i][j-1]);
          }
        }
        return dp[a.length][b.length];
      }

      const longer = Math.max(latinNormalized.length, arabicNormalized.length);
      if (longer > 3) {
        const lcs = lcsLength(latinNormalized, arabicNormalized);
        const similarity = lcs / longer;
        if (similarity < 0.6) {
          warnings.push(
            `👤 الاسم قد لا يتطابق — الجواز: ${passport.full_name} | البطاقة: ${nid.full_name_arabic} — يرجى التحقق`
          );
        }
      }
    }

    // ── Show result ──────────────────────────────────────────
    const crossEl = document.getElementById(`ocr_cross_${idx}`);
    if (!crossEl) return;

    if (warnings.length === 0) {
      crossEl.style.cssText = 'background:#F0FDF4;border:1px solid #BBF7D0;color:#15803D;border-radius:6px;padding:8px 12px;font-size:12px;font-family:"Cairo",sans-serif;margin-top:8px;';
      crossEl.innerHTML = '✅ البيانات متطابقة في الجواز والبطاقة';
      crossEl.classList.remove('hidden');
      setTimeout(() => crossEl.classList.add('hidden'), 8000);
    } else {
      crossEl.style.cssText = 'background:#FEF2F2;border:1px solid #FECACA;color:#B91C1C;border-radius:6px;padding:8px 12px;font-size:12px;font-family:"Cairo",sans-serif;margin-top:8px;line-height:1.8;';
      crossEl.innerHTML = '<strong>⚠️ تحذير — يرجى مراجعة البيانات:</strong><br>' + warnings.join('<br>');
      crossEl.classList.remove('hidden');
    }
  }

  /* ── Image resize (keep uploads small/fast — Vision doesn't need the
        grayscale+contrast boost the old Tesseract pipeline used) ───── */

  async function resizeImage(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        try {
          const MAX = 2400; // longest side, px
          let { width: w, height: h } = img;
          if (w > MAX || h > MAX) {
            if (w >= h) { h = Math.round(h * MAX / w); w = MAX; }
            else        { w = Math.round(w * MAX / h); h = MAX; }
          }
          const c = document.createElement('canvas');
          c.width = w; c.height = h;
          c.getContext('2d').drawImage(img, 0, 0, w, h);
          c.toBlob(blob => { URL.revokeObjectURL(url); resolve(blob); }, 'image/jpeg', 0.92);
        } catch (e) { URL.revokeObjectURL(url); reject(e); }
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('img load failed')); };
      img.src = url;
    });
  }

  function blobToBase64(blob) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload  = () => resolve(reader.result.split(',')[1] || '');
      reader.onerror = () => reject(new Error('file read failed'));
      reader.readAsDataURL(blob);
    });
  }

  /* ── Cloud Vision OCR (via our serverless proxy) ──────────────────── */

  async function runOCR(file) {
    const resized      = await resizeImage(file);
    const imageBase64  = await blobToBase64(resized);

    const res = await fetch('/api/ocr-scan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ imageBase64 }),
    });

    const data = await res.json().catch(() => ({}));

    if (!res.ok) {
      throw new Error(data?.error || `OCR request failed (${res.status})`);
    }

    return data.text || '';
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
      const expRaw = mrz.substring(21, 27);
      if (/^\d{6}$/.test(expRaw)) {
        const yr = parseInt(expRaw.substring(0, 2));
        // Expiry dates are always in the future relative to issuance, so unlike
        // DOB we don't need the "yr > 30 => 1900s" heuristic — always 2000+yr.
        extracted.expiry_date = `${2000+yr}-${expRaw.substring(2,4)}-${expRaw.substring(4,6)}`;
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

  // Egyptian NID cards print the ID number, address numerals, etc. in Arabic-Indic
  // digits (٠١٢٣٤٥٦٧٨٩, U+0660–U+0669), not ASCII 0-9. \d never matches those, so
  // without this conversion the 14-digit NID regex silently fails on every real
  // Egyptian card. Convert Arabic-Indic (and Extended/Persian variant ۰-۹ for safety)
  // to ASCII before any digit-matching runs.
  function toAsciiDigits(s) {
    return s.replace(/[٠-٩۰-۹]/g, ch => {
      const code = ch.codePointAt(0);
      // Arabic-Indic block: U+0660-0669 maps to 0-9
      if (code >= 0x0660 && code <= 0x0669) return String(code - 0x0660);
      // Extended Arabic-Indic (Persian/Urdu) block: U+06F0-06F9 maps to 0-9
      if (code >= 0x06F0 && code <= 0x06F9) return String(code - 0x06F0);
      return ch;
    });
  }

  function parseNID(rawText) {
    const extracted = {};
    const text = toAsciiDigits(rawText);

    // Strip whitespace AND common OCR noise characters (Arabic diacritics, dots,
    // dashes, RTL/LTR marks) that Tesseract sometimes inserts inside digit runs
    // when scanning Arabic-script documents, before searching for the 14-digit NID.
    const cleaned = text.replace(/[\s\u200e\u200f\u064b-\u065f.\-_|]+/g, '');
    const nidMatch = cleaned.match(/[23]\d{13}/); // Egyptian NID starts with 2 or 3
    if (nidMatch) {
      extracted.national_id_number = nidMatch[0];
      const n = nidMatch[0];
      const century = n[0] === '3' ? '20' : '19';
      extracted.date_of_birth = `${century}${n.substring(1,3)}-${n.substring(3,5)}-${n.substring(5,7)}`;
    } else {
      // Fallback: allow noise characters between individual digits too
      const spacedMatch = text.match(/([23](?:[\s\u200e\u200f\u064b-\u065f.\-_|]*\d){13})/);
      if (spacedMatch) {
        const n = spacedMatch[0].replace(/[\s\u200e\u200f\u064b-\u065f.\-_|]/g, '');
        extracted.national_id_number = n;
        const century = n[0] === '3' ? '20' : '19';
        extracted.date_of_birth = `${century}${n.substring(1,3)}-${n.substring(3,5)}-${n.substring(5,7)}`;
      }
    }

    // Arabic name: collect Arabic lines, exclude lines that are just labels/headers.
    // Previous list missed several common ID-card header words (e.g. "الشخصية" as in
    // "بطاقة الرقم القومي الشخصية"), which let header text get picked up as the name.
    const arabicLabels = /(?:الجمهورية|العربية|المصرية|بطاقة|الرقم|القومي|تاريخ|الميلاد|محل|الإقامة|الديانة|الحالة|الشخصية|الإصدار|الانتهاء|وزارة|الداخلية|مصر|قومي|النوع|الجنس|العنوان|المهنة)/;
    const arabicLines = text.split('\n')
      .map(l => l.trim())
      // Require: real Arabic words, not a label line, no digits, and no leftover
      // Latin/garbled tokens (e.g. "pid") that indicate a misread header line.
      .filter(l =>
        /[\u0600-\u06FF]{4,}/.test(l) &&
        !arabicLabels.test(l) &&
        !/\d/.test(l) &&
        !/[A-Za-z]{2,}/.test(l)
      );

    if (arabicLines.length > 0) {
      // Name is usually 2-4 Arabic words — pick the line that looks most like a name
      const nameLine = arabicLines
        .map(l => ({
          line: l,
          words: l.split(/\s+/).filter(w => /[\u0600-\u06FF]{2,}/.test(w)).length
        }))
        // A real name line has at least 2 proper words; anything with just 1 word
        // is almost always a stray label fragment, not a full name.
        .filter(x => x.words >= 2)
        .sort((a, b) => Math.abs(a.words - 3) - Math.abs(b.words - 3))[0];
      if (nameLine) extracted.full_name_arabic = nameLine.line;
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
          storeOCR(idx, 'passport', extracted);
          const filled = [extracted.passport_number, extracted.expiry_date, extracted.full_name].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال');
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات بوضوح — يرجى الإدخال يدوياً');
          }
        } else {
          fillNIDFields(block, extracted);
          storeOCR(idx, 'nid', extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', '✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال');
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
          }
        }

        setTimeout(() => hideStatus(statusEl), 8000);

        // Cross-check passport vs NID once both are scanned
        crossCheckDocuments(idx);

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
