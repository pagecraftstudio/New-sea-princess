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

  async function runOCR(file, docType) {
    const base64 = await fileToBase64(file);
    const mediaType = file.type || 'image/jpeg';

    const prompts = {
      passport: `You are an OCR assistant. Extract data from this passport image.
Return ONLY a JSON object with these exact keys (use null for any field you cannot read clearly):
{
  "full_name": "full name as written in the passport (Latin characters)",
  "full_name_arabic": "full name in Arabic if present",
  "passport_number": "passport number (letters and digits only, no spaces)",
  "nationality": "nationality",
  "date_of_birth": "YYYY-MM-DD format",
  "expiry_date": "YYYY-MM-DD format",
  "gender": "M or F"
}
Return ONLY the JSON object. No explanation, no markdown, no code fences.`,

      national_id: `You are an OCR assistant. Extract data from this Egyptian National ID card.
Return ONLY a JSON object with these exact keys (use null for any field you cannot read clearly):
{
  "full_name_arabic": "full name in Arabic as printed on the card",
  "full_name": "full name transliterated to English if back of card is shown",
  "national_id_number": "the 14-digit national ID number",
  "date_of_birth": "YYYY-MM-DD format derived from NID number or printed date",
  "gender": "M or F",
  "governorate": "governorate of issue in Arabic"
}
Return ONLY the JSON object. No explanation, no markdown, no code fences.`,
    };

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6',
        max_tokens: 400,
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType, data: base64 } },
            { type: 'text',  text: prompts[docType] }
          ]
        }]
      })
    });

    if (!response.ok) throw new Error(`API error ${response.status}`);
    const data = await response.json();
    const text = data.content.map(b => b.text || '').join('').trim();

    // Strip any accidental markdown fences
    const clean = text.replace(/^```json\s*/i, '').replace(/```$/,'').trim();
    return JSON.parse(clean);
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
        console.error('[OCR]', err);
        setStatus(statusEl, 'error', '❌ تعذّر قراءة المستند — يرجى الإدخال اليدوي');
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
