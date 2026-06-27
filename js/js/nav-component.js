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

(function () {
  const WHATSAPP_NUMBER = '201555154996'; // ← change here only

  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('a[href*="wa.me/"]').forEach(function (el) {
      el.href = el.href.replace(/wa\.me\/20\d+/, 'wa.me/' + WHATSAPP_NUMBER);
    });
  });
})();
