/**
 * ocr.js — نيو سي برنسيس للسياحة
 * AI-powered OCR scanner for passport and national ID upload fields.
 * Uses Claude Vision API to extract and auto-fill traveler data.
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

  /* Convert File → base64 string (strips the data-URL prefix) */
  function fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload  = () => resolve(reader.result.split(',')[1]);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  /* Find the traveler block that owns a given file input (by traveler index) */
  function getTravelerBlock(idx) {
    const blocks = document.querySelectorAll('.traveler-adult-block, .traveler-child-block');
    return blocks[idx] || null;
  }

  /* Safely set a field value and trigger input/change events */
  function fillField(el, value) {
    if (!el || !value) return;
    el.value = value;
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.style.background = '#F0FDF4';
    setTimeout(() => { el.style.background = ''; }, 2500);
  }

  /* ── Claude Vision API call ─────────────────────────────── */

  // Supabase project URL — matches your supabase-config.js
  const SUPABASE_URL = 'https://uptaqdldbvmiigsfndtm.supabase.co';

  async function runOCR(file, docType) {
    const base64    = await fileToBase64(file);
    const mediaType = file.type || 'image/jpeg';

    const response = await fetch(`${SUPABASE_URL}/functions/v1/ocr-scan`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ imageBase64: base64, mediaType, docType })
    });

    const rawText = await response.text();
    console.log('[OCR] Edge Function raw response:', response.status, rawText);

    if (!response.ok) {
      let errDetail = rawText;
      try { errDetail = JSON.parse(rawText)?.error || rawText; } catch(_) {}
      throw new Error(`HTTP ${response.status}: ${errDetail}`);
    }

    const result = JSON.parse(rawText);
    if (!result.success) throw new Error(result.error || 'unknown_error');
    return result.data;
  }

  /* ── Auto-fill logic ────────────────────────────────────── */

  function fillPassportFields(block, extracted) {
    if (!block || !extracted) return;

    // Name (prefer Arabic, fall back to Latin)
    const nameField = block.querySelector('.t-name');
    if (!nameField?.value && (extracted.full_name_arabic || extracted.full_name)) {
      fillField(nameField, extracted.full_name_arabic || extracted.full_name);
    }

    // Passport number
    const passportField = block.querySelector('.t-passport');
    if (extracted.passport_number) fillField(passportField, extracted.passport_number.toUpperCase());

    // Expiry date
    const expiryField = block.querySelector('.t-passport-exp');
    if (extracted.expiry_date) {
      fillField(expiryField, extracted.expiry_date);
      // Trigger the built-in passport expiry validator
      expiryField?.dispatchEvent(new Event('input', { bubbles: true }));
    }
  }

  function fillNIDFields(block, extracted) {
    if (!block || !extracted) return;

    // Name
    const nameField = block.querySelector('.t-name');
    if (!nameField?.value && extracted.full_name_arabic) {
      fillField(nameField, extracted.full_name_arabic);
    }

    // National ID number
    const nidField = block.querySelector('.t-nid');
    if (extracted.national_id_number) fillField(nidField, extracted.national_id_number);
  }

  /* ── Event attachment ───────────────────────────────────── */

  function attachOCRToInput(input, docType) {
    input.addEventListener('change', async function () {
      const file = this.files?.[0];
      if (!file) return;

      const idx       = parseInt(this.dataset.travelerIdx ?? '0', 10);
      const statusEl  = document.getElementById(`ocr_${docType === 'passport' ? 'passport' : 'nid'}_status_${idx}`);
      const block     = getTravelerBlock(idx);

      // Only process images (not PDFs — can't send PDF as vision)
      if (file.type === 'application/pdf') {
        setStatus(statusEl, 'warning', '⚠️ ملفات PDF لا تدعم المسح الضوئي — يرجى رفع صورة JPG/PNG للملء التلقائي');
        return;
      }

      if (!file.type.startsWith('image/')) return;

      setStatus(statusEl, 'loading', '🔍 جارٍ قراءة المستند بالذكاء الاصطناعي…');

      try {
        const extracted = await runOCR(file, docType);

        if (docType === 'passport') {
          fillPassportFields(block, extracted);
          const filled = [extracted.passport_number, extracted.expiry_date, extracted.full_name_arabic || extracted.full_name].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', `✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال`);
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات بوضوح — يرجى الإدخال يدوياً');
          }
        } else {
          fillNIDFields(block, extracted);
          const filled = [extracted.national_id_number, extracted.full_name_arabic].filter(Boolean);
          if (filled.length) {
            setStatus(statusEl, 'success', `✅ تم استخراج البيانات تلقائياً — يرجى المراجعة قبل الإرسال`);
          } else {
            setStatus(statusEl, 'warning', '⚠️ لم يتمكن النظام من قراءة البيانات — يرجى الإدخال يدوياً');
          }
        }

        // Auto-hide success message after 6 seconds
        setTimeout(() => hideStatus(statusEl), 6000);

      } catch (err) {
        console.error('[OCR] Full error:', err);
        // Show the actual error message to help diagnose
        const msg = err?.message || String(err);
        setStatus(statusEl, 'error', `❌ خطأ: ${msg} — افتح Console (F12) لمزيد من التفاصيل`);
      }
    });
  }

  /* ── Observer: attach OCR whenever new upload inputs are added ── */
  // (The booking form renders inputs dynamically when travelers are added)

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

  // Also run once on load in case inputs already exist
  document.addEventListener('DOMContentLoaded', scanAndAttach);

})();
