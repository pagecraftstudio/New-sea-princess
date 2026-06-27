/**
 * currency-hint.js
 * Lightweight in-card currency hint for packages.html and package-detail.html.
 * Shared fallback rates + optional live fetch (once per page load).
 */
(function () {
  const RATES = { SAR: 0.074, AED: 0.073, KWD: 0.0061, USD: 0.020 };
  const SYMS  = { SAR: 'ر.س', AED: 'د.إ', KWD: 'د.ك', USD: '$' };

  // Current selected currency (default SAR, '' = off)
  window.HINT_CURRENCY = 'SAR';

  /** Return formatted hint string for egpAmount in targetCurrency */
  window.getCurrencyHint = function (egpAmount, targetCurrency) {
    const cur = targetCurrency ?? window.HINT_CURRENCY;
    if (!cur || !RATES[cur]) return '';
    const converted = Math.round(egpAmount * RATES[cur]);
    return `≈ ${converted.toLocaleString('ar-EG')} ${SYMS[cur]}`;
  };

  /** Re-render every .price-hint span already in the DOM */
  window.updateAllHints = function (currency) {
    window.HINT_CURRENCY = currency;
    document.querySelectorAll('[data-egp]').forEach(el => {
      const egp  = parseFloat(el.dataset.egp);
      const hint = el.querySelector('.price-hint');
      if (!hint) return;
      hint.textContent = currency ? window.getCurrencyHint(egp, currency) : '';
    });
  };

  /** Try to refresh RATES with live data once; silently fall back on error */
  window.fetchLiveHintRates = async function () {
    try {
      const r = await fetch('https://open.er-api.com/v6/latest/EGP');
      if (!r.ok) return;
      const d = await r.json();
      if (!d.rates) return;
      Object.keys(RATES).forEach(k => {
        if (d.rates[k]) RATES[k] = d.rates[k];
      });
      // Refresh displayed hints with live rates
      window.updateAllHints(window.HINT_CURRENCY);
    } catch (_) { /* stay with fallback */ }
  };
})();
