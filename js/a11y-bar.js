/**
 * a11y-bar.js
 * Site-wide accessibility toolbar: font size, contrast, underline links,
 * reduce motion, dyslexia-friendly font, reset — plus a live Mecca clock
 * and real-time temperature (Open-Meteo, no API key needed).
 *
 * Usage: include once per page, ideally right after <body>:
 *   <script src="/js/a11y-bar.js" defer></script>
 *
 * Preferences persist in localStorage under the "nspA11y" key and are
 * re-applied on every page load before paint (no flash of un-styled content).
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * ─────────────────────────────────────────────────────────
 */
(function () {
  'use strict';

  const STORAGE_KEY = 'nspA11y';
  const MECCA_LAT = 21.4225, MECCA_LON = 39.8262;
  const MECCA_TZ = 'Asia/Riyadh'; // Mecca shares Saudi Arabia's single UTC+3 zone, no DST

  const defaults = { fontStep: 0, contrast: false, underline: false, reduceMotion: false, dyslexia: false };

  function loadPrefs() {
    try { return Object.assign({}, defaults, JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}')); }
    catch (e) { return Object.assign({}, defaults); }
  }
  function savePrefs(p) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(p)); } catch (e) { /* storage unavailable, ignore */ }
  }

  let prefs = loadPrefs();

  // ── Apply preferences to <html> root ───────────────────────
  function applyPrefs() {
    const root = document.documentElement;
    root.classList.remove('a11y-fs-1', 'a11y-fs-2', 'a11y-fs-3');
    if (prefs.fontStep > 0) root.classList.add('a11y-fs-' + prefs.fontStep);
    root.classList.toggle('a11y-contrast', !!prefs.contrast);
    root.classList.toggle('a11y-underline', !!prefs.underline);
    root.classList.toggle('a11y-reduce-motion', !!prefs.reduceMotion);
    root.classList.toggle('a11y-dyslexia', !!prefs.dyslexia);
  }

  // Apply immediately (before the bar even renders) to avoid flash-of-default
  applyPrefs();

  // ── Inject styles ───────────────────────────────────────────
  const style = document.createElement('style');
  style.textContent = `
    #a11yBar { position:sticky; top:0; z-index:9999; display:flex; align-items:center;
      justify-content:space-between; gap:.5rem; flex-wrap:wrap; background:#0f1f12; color:#f5f0e6;
      font-family:'Cairo', Tahoma, sans-serif; font-size:13px; padding:6px 12px; direction:rtl; }
    #a11yBar .a11y-group { display:flex; align-items:center; gap:4px; flex-wrap:wrap; }
    #a11yBar button { background:transparent; border:1px solid rgba(245,240,230,.35); color:#f5f0e6;
      border-radius:6px; padding:4px 8px; font-size:12px; cursor:pointer; line-height:1.3;
      font-family:inherit; transition:background .15s, border-color .15s; }
    #a11yBar button:hover { background:rgba(245,240,230,.12); }
    #a11yBar button[aria-pressed="true"] { background:#B8860B; border-color:#B8860B; color:#0f1f12; font-weight:700; }
    #a11yBar button:focus-visible, #a11yBar a:focus-visible {
      outline:3px solid #fff; outline-offset:2px; }
    #a11yBar .a11y-mecca { display:flex; align-items:center; gap:8px; font-weight:700; white-space:nowrap; }
    #a11yBar .a11y-mecca .a11y-icon { opacity:.85; }
    #a11yBar .a11y-skip { position:absolute; right:-9999px; top:auto; background:#B8860B; color:#0f1f12;
      border:none; padding:6px 10px; border-radius:6px; font-weight:700; cursor:pointer; }
    #a11yBar .a11y-skip:focus { position:static; right:auto; display:inline-block; }
    #a11yBar .a11y-divider { width:1px; height:18px; background:rgba(245,240,230,.25); margin:0 2px; }
    @media (max-width:640px) {
      #a11yBar { font-size:12px; }
      #a11yBar .a11y-mecca-temp { display:none; }
    }

    /* ── Font size steps ── */
    html.a11y-fs-1 { font-size:107%; }
    html.a11y-fs-2 { font-size:115%; }
    html.a11y-fs-3 { font-size:124%; }

    /* ── High contrast ── */
    html.a11y-contrast { filter: contrast(1.18) saturate(1.05); }
    html.a11y-contrast body { background:#000 !important; color:#fff !important; }
    html.a11y-contrast a { color:#ffd54a !important; }
    html.a11y-contrast img, html.a11y-contrast canvas, html.a11y-contrast video { filter: contrast(1.1); }

    /* ── Underline links ── */
    html.a11y-underline a { text-decoration:underline !important; text-decoration-thickness:2px !important; }

    /* ── Reduce motion ── */
    html.a11y-reduce-motion *, html.a11y-reduce-motion *::before, html.a11y-reduce-motion *::after {
      animation-duration:.001ms !important; animation-iteration-count:1 !important;
      transition-duration:.001ms !important; scroll-behavior:auto !important; }

    /* ── Dyslexia-friendly font ── */
    html.a11y-dyslexia, html.a11y-dyslexia * { font-family: 'Comic Sans MS', 'Comic Sans', Tahoma, sans-serif !important; letter-spacing:.02em !important; }
  `;
  document.head.appendChild(style);

  // ── Build bar markup ────────────────────────────────────────
  const bar = document.createElement('div');
  bar.id = 'a11yBar';
  bar.setAttribute('role', 'region');
  bar.setAttribute('aria-label', 'شريط إمكانية الوصول وتوقيت مكة المكرمة');
  bar.innerHTML = `
    <button type="button" id="a11ySkip" class="a11y-skip">تخطي إلى المحتوى الرئيسي</button>

    <div class="a11y-group" role="toolbar" aria-label="أدوات إمكانية الوصول">
      <button type="button" id="a11yFontDec" aria-label="تصغير حجم الخط">A-</button>
      <button type="button" id="a11yFontInc" aria-label="تكبير حجم الخط">A+</button>
      <span class="a11y-divider" aria-hidden="true"></span>
      <button type="button" id="a11yContrast" aria-pressed="false">تباين عالي</button>
      <button type="button" id="a11yUnderline" aria-pressed="false">تسطير الروابط</button>
      <button type="button" id="a11yMotion" aria-pressed="false">تقليل الحركة</button>
      <button type="button" id="a11yDyslexia" aria-pressed="false">خط سهل القراءة</button>
      <span class="a11y-divider" aria-hidden="true"></span>
      <button type="button" id="a11yReset">إعادة الضبط</button>
    </div>

    <div class="a11y-mecca" aria-live="off">
      <span class="a11y-icon" aria-hidden="true">🕋</span>
      <span>مكة المكرمة</span>
      <span id="a11yMeccaTime">—</span>
      <span class="a11y-mecca-temp" id="a11yMeccaTempWrap">
        <span aria-hidden="true">·</span>
        <span id="a11yMeccaTemp">—</span>
      </span>
    </div>
  `;
  document.body.insertBefore(bar, document.body.firstChild);

  // ── Wire up toggle buttons ──────────────────────────────────
  function setPressed(btn, val) { btn.setAttribute('aria-pressed', val ? 'true' : 'false'); }

  const fontDec = document.getElementById('a11yFontDec');
  const fontInc = document.getElementById('a11yFontInc');
  const contrastBtn = document.getElementById('a11yContrast');
  const underlineBtn = document.getElementById('a11yUnderline');
  const motionBtn = document.getElementById('a11yMotion');
  const dyslexiaBtn = document.getElementById('a11yDyslexia');
  const resetBtn = document.getElementById('a11yReset');
  const skipBtn = document.getElementById('a11ySkip');

  skipBtn.addEventListener('click', function () {
    const target = document.getElementById('main') || document.querySelector('main') || document.querySelector('h1');
    if (target) {
      if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
      target.focus();
      target.scrollIntoView({ block: 'start' });
    }
  });

  function refreshButtonStates() {
    setPressed(contrastBtn, prefs.contrast);
    setPressed(underlineBtn, prefs.underline);
    setPressed(motionBtn, prefs.reduceMotion);
    setPressed(dyslexiaBtn, prefs.dyslexia);
  }
  refreshButtonStates();

  fontInc.addEventListener('click', function () {
    prefs.fontStep = Math.min(3, prefs.fontStep + 1);
    applyPrefs(); savePrefs(prefs);
  });
  fontDec.addEventListener('click', function () {
    prefs.fontStep = Math.max(0, prefs.fontStep - 1);
    applyPrefs(); savePrefs(prefs);
  });
  contrastBtn.addEventListener('click', function () {
    prefs.contrast = !prefs.contrast; applyPrefs(); savePrefs(prefs); refreshButtonStates();
  });
  underlineBtn.addEventListener('click', function () {
    prefs.underline = !prefs.underline; applyPrefs(); savePrefs(prefs); refreshButtonStates();
  });
  motionBtn.addEventListener('click', function () {
    prefs.reduceMotion = !prefs.reduceMotion; applyPrefs(); savePrefs(prefs); refreshButtonStates();
  });
  dyslexiaBtn.addEventListener('click', function () {
    prefs.dyslexia = !prefs.dyslexia; applyPrefs(); savePrefs(prefs); refreshButtonStates();
  });
  resetBtn.addEventListener('click', function () {
    prefs = Object.assign({}, defaults); applyPrefs(); savePrefs(prefs); refreshButtonStates();
  });

  // ── Mecca live clock (updates every second, real local time, no fetch needed) ──
  const timeEl = document.getElementById('a11yMeccaTime');
  const timeFmt = new Intl.DateTimeFormat('ar-EG', {
    timeZone: MECCA_TZ, hour: '2-digit', minute: '2-digit', hour12: true
  });
  function tickClock() {
    timeEl.textContent = timeFmt.format(new Date());
  }
  tickClock();
  setInterval(tickClock, 1000 * 15); // 15s is plenty for a minute-resolution clock

  // ── Mecca live temperature (Open-Meteo, free, no API key) ──
  const tempEl = document.getElementById('a11yMeccaTemp');
  async function fetchMeccaTemp() {
    try {
      const url = `https://api.open-meteo.com/v1/forecast?latitude=${MECCA_LAT}&longitude=${MECCA_LON}&current_weather=true`;
      const res = await fetch(url);
      if (!res.ok) throw new Error('weather fetch failed');
      const data = await res.json();
      const t = data && data.current_weather ? Math.round(data.current_weather.temperature) : null;
      tempEl.textContent = t !== null ? `${t}°م` : 'غير متاح';
    } catch (e) {
      tempEl.textContent = 'غير متاح';
    }
  }
  fetchMeccaTemp();
  setInterval(fetchMeccaTemp, 1000 * 60 * 10); // refresh every 10 minutes

  // Update full ARIA description for the Mecca cluster (for SR users) without spamming live updates
  const meccaCluster = bar.querySelector('.a11y-mecca');
  function updateMeccaAria() {
    meccaCluster.setAttribute('aria-label', `الوقت الآن في مكة المكرمة ${timeEl.textContent}، درجة الحرارة ${tempEl.textContent}`);
  }
  setInterval(updateMeccaAria, 1000 * 30);
  updateMeccaAria();
})();
