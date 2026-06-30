/**
 * nav-component.js
 * Single source of truth for the site's WhatsApp contact number.
 * Update WHATSAPP_NUMBER here and it propagates to all nav links on every page.
 *
 * Usage: include this script in every page's <head> or just before </body>.
 * The script replaces any href matching /wa.me/20[0-9]+/ with the canonical number.
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

/**
 * nav-component.js
 * Single source of truth for the site's WhatsApp contacts.
 * Update CONTACTS here and it propagates to every wa.me link on every page.
 *
 * Usage: include this script in every page's <head> or just before </body>.
 * Any click on an <a href="...wa.me/..."> (or one whose href is built via
 * window.waLink(...) in an inline onclick) is intercepted and replaced with
 * a picker so the visitor chooses *who* on the team to message, instead of
 * being routed to one number silently.
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

(function () {
  // ← change names/numbers here only — propagates everywhere automatically
  const CONTACTS = [
    { number: '201093475254', name: 'الداعية د. محمد دحروج' },
    { number: '201555154996', name: 'د. شيماء السعداوي' },
    { number: '201029593280', name: 'أ. ياسمين منصور' },
  ];
  const CREDIT_LINK_MARKER = '201029198346'; // Pagecraft Studio credit link — never intercept

  let modal, pendingText = '';

  function injectModal() {
    const style = document.createElement('style');
    style.textContent = `
      #waPickerOverlay { position:fixed; inset:0; z-index:99999; display:none;
        align-items:center; justify-content:center; padding:16px;
        background:rgba(13,27,16,.55); backdrop-filter:blur(3px); -webkit-backdrop-filter:blur(3px); }
      #waPickerOverlay.open { display:flex; }
      #waPickerCard { width:100%; max-width:380px; background:#fff; border-radius:18px;
        overflow:hidden; box-shadow:0 20px 50px -10px rgba(0,0,0,.4); direction:rtl;
        font-family:'Cairo', Tahoma, sans-serif; animation:waPickerIn .18s ease; }
      @keyframes waPickerIn { from { opacity:0; transform:translateY(8px) scale(.98);} to { opacity:1; transform:none; } }
      #waPickerCard .wa-head { background:linear-gradient(135deg,#1B5E20,#0D1B0E); color:#fff;
        padding:18px 20px; display:flex; align-items:center; gap:10px; }
      #waPickerCard .wa-head i { font-size:22px; color:#25D366; }
      #waPickerCard .wa-head h3 { margin:0; font-size:16px; font-weight:800; }
      #waPickerCard .wa-sub { padding:14px 20px 0; color:#6b7280; font-size:12.5px; }
      #waPickerCard .wa-list { padding:14px; display:flex; flex-direction:column; gap:8px; }
      #waPickerCard .wa-contact { display:flex; align-items:center; gap:12px; width:100%;
        background:#f8f5ec; border:1.5px solid #ece7d9; border-radius:12px; padding:12px 14px;
        cursor:pointer; text-align:right; font-family:inherit; transition:background .15s,border-color .15s,transform .1s; }
      #waPickerCard .wa-contact:hover { background:#f1ece0; border-color:#DAA520; transform:translateY(-1px); }
      #waPickerCard .wa-contact:active { transform:translateY(0); }
      #waPickerCard .wa-avatar { width:38px; height:38px; border-radius:50%; flex-shrink:0;
        background:linear-gradient(135deg,#25D366,#128C7E); color:#fff; display:flex;
        align-items:center; justify-content:center; font-size:17px; }
      #waPickerCard .wa-meta { flex:1; min-width:0; }
      #waPickerCard .wa-name { font-weight:800; font-size:14px; color:#1f2937; }
      #waPickerCard .wa-num { font-size:12px; color:#9ca3af; direction:ltr; text-align:right; margin-top:2px; }
      #waPickerCard .wa-go { color:#9ca3af; font-size:14px; }
      #waPickerCard .wa-cancel { display:block; width:calc(100% - 28px); margin:0 14px 14px;
        background:transparent; border:1.5px solid #e5e7eb; color:#6b7280; font-weight:700;
        font-size:13px; padding:10px; border-radius:10px; cursor:pointer; font-family:inherit; }
      #waPickerCard .wa-cancel:hover { background:#f9fafb; }
      @media (max-width:380px) { #waPickerCard .wa-name { font-size:13px; } }
    `;
    document.head.appendChild(style);

    modal = document.createElement('div');
    modal.id = 'waPickerOverlay';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-label', 'اختر من تريد التواصل معه عبر واتساب');
    modal.innerHTML = `
      <div id="waPickerCard">
        <div class="wa-head"><i class="fa-brands fa-whatsapp"></i><h3>تواصل معنا عبر واتساب</h3></div>
        <p class="wa-sub">اختر الشخص المناسب للتواصل معه:</p>
        <div class="wa-list">
          ${CONTACTS.map((c, i) => `
            <button type="button" class="wa-contact" data-index="${i}">
              <span class="wa-avatar"><i class="fa-solid fa-user" aria-hidden="true"></i></span>
              <span class="wa-meta">
                <span class="wa-name">${c.name}</span>
                <span class="wa-num">${formatDisplayNumber(c.number)}</span>
              </span>
              <i class="fa-solid fa-chevron-left wa-go" aria-hidden="true"></i>
            </button>
          `).join('')}
        </div>
        <button type="button" class="wa-cancel" id="waPickerCancel">إلغاء</button>
      </div>
    `;
    document.body.appendChild(modal);

    modal.querySelectorAll('.wa-contact').forEach(btn => {
      btn.addEventListener('click', function () {
        const c = CONTACTS[parseInt(this.dataset.index, 10)];
        const text = pendingText ? '?text=' + encodeURIComponent(pendingText) : '';
        window.open('https://wa.me/' + c.number + text, '_blank');
        closeModal();
      });
    });
    document.getElementById('waPickerCancel').addEventListener('click', closeModal);
    modal.addEventListener('click', function (e) { if (e.target === modal) closeModal(); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modal.classList.contains('open')) closeModal();
    });
  }

  function formatDisplayNumber(intlNumber) {
    // '201093475254' -> '01093475254'
    const local = '0' + intlNumber.slice(2);
    return local;
  }

  function openModal(text) {
    pendingText = text || '';
    modal.classList.add('open');
    const firstBtn = modal.querySelector('.wa-contact');
    if (firstBtn) firstBtn.focus();
  }
  function closeModal() {
    modal.classList.remove('open');
    pendingText = '';
  }

  // Pulls any pre-filled "?text=" query off a wa.me href, if present.
  function extractText(href) {
    try {
      const u = new URL(href, window.location.href);
      return u.searchParams.get('text') || '';
    } catch (e) { return ''; }
  }

  // For the few buttons that build their href dynamically via
  // onclick="this.href=window.waLink('context','some static message')…",
  // the static href never contains "wa.me/" until after the click already
  // ran — so we also match on the onclick attribute itself, and best-effort
  // pull out a literal second argument (string concatenation built from a
  // runtime value, e.g. a booking number the visitor typed, can't be
  // recovered this way and is simply omitted from the pre-filled text).
  function extractTextFromOnclick(onclickAttr) {
    if (!onclickAttr) return '';
    const m = onclickAttr.match(/waLink\(\s*['"][^'"]*['"]\s*,\s*['"]([^'"]*)['"]/);
    return m ? m[1] : '';
  }

  document.addEventListener('DOMContentLoaded', function () {
    injectModal();

    // Capture-phase listener: intercepts the click before the link's own
    // href navigation AND before any inline onclick="this.href=...;window.open(...)"
    // on the same element gets a chance to run, so nothing double-opens.
    document.addEventListener('click', function (e) {
      const el = e.target.closest('a[href*="wa.me/"], a[onclick*="waLink("]');
      if (!el) return;
      if (el.href.indexOf(CREDIT_LINK_MARKER) !== -1) return; // Pagecraft Studio credit link — leave alone
      e.preventDefault();
      e.stopPropagation();
      const text = el.href.indexOf('wa.me/') !== -1
        ? extractText(el.href)
        : extractTextFromOnclick(el.getAttribute('onclick'));
      openModal(text);
    }, true);
  });
})();

