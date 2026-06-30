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
    #a11yBar { position:sticky; z-index:9990; display:flex; align-items:center;
      justify-content:space-between; gap:10px; flex-wrap:wrap; direction:rtl;
      font-family:'Cairo', Tahoma, sans-serif; font-size:13px;
      padding:8px 16px; color:#f5f0e6;
      background:linear-gradient(180deg, rgba(15,31,18,.88), rgba(13,27,16,.82));
      backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px);
      border-bottom:1px solid rgba(184,134,11,.28);
      box-shadow:0 6px 18px -8px rgba(0,0,0,.35); }

    #a11yBar .a11y-group { display:flex; align-items:center; gap:6px; flex-wrap:wrap;
      background:rgba(255,255,255,.04); border:1px solid rgba(255,255,255,.08);
      border-radius:999px; padding:4px; }

    #a11yBar button { background:transparent; border:none; color:#e9e4d8;
      border-radius:999px; width:32px; height:32px; display:inline-flex; align-items:center;
      justify-content:center; font-size:13px; cursor:pointer; line-height:1;
      font-family:inherit; transition:background .18s ease, color .18s ease, transform .12s ease; }
    #a11yBar button.a11y-text-btn { width:auto; padding:0 12px; gap:6px; font-size:12px; font-weight:600; }
    #a11yBar button:hover { background:rgba(255,255,255,.12); transform:translateY(-1px); }
    #a11yBar button:active { transform:translateY(0); }
    #a11yBar button[aria-pressed="true"] {
      background:linear-gradient(135deg, #DAA520, #B8860B); color:#10210f; font-weight:700;
      box-shadow:0 2px 8px rgba(184,134,11,.4); }
    #a11yBar button:focus-visible, #a11yBar a:focus-visible {
      outline:2.5px solid #ffd54a; outline-offset:2px; }

    #a11yBar .a11y-divider { width:1px; height:18px; background:rgba(255,255,255,.14); margin:0 2px; }

    #a11yBar .a11y-mecca { display:flex; align-items:center; gap:10px; font-weight:600;
      white-space:nowrap; background:rgba(255,255,255,.04); border:1px solid rgba(255,255,255,.08);
      border-radius:999px; padding:5px 14px; }
    #a11yBar .a11y-mecca .a11y-kaaba { font-size:15px; filter:drop-shadow(0 0 4px rgba(184,134,11,.5)); }
    #a11yBar .a11y-mecca .a11y-mecca-label { color:#cfc8b4; font-weight:600; font-size:12px; }
    #a11yBar .a11y-mecca .a11y-mecca-time { color:#ffd54a; font-weight:700; letter-spacing:.02em; }
    #a11yBar .a11y-mecca .a11y-mecca-temp { display:flex; align-items:center; gap:4px; color:#f5f0e6; }
    #a11yBar .a11y-mecca .a11y-sep { width:1px; height:14px; background:rgba(255,255,255,.18); }

    #a11yBar .a11y-skip { position:absolute; right:-9999px; top:auto; width:auto; height:auto;
      background:#DAA520; color:#10210f; border:none; padding:8px 14px; border-radius:8px;
      font-weight:700; font-size:13px; cursor:pointer; }
    #a11yBar .a11y-skip:focus { position:static; right:auto; display:inline-flex; }

    @media (max-width:760px) {
      #a11yBar { font-size:12px; padding:6px 10px; }
      #a11yBar .a11y-mecca-label { display:none; }
    }
    @media (max-width:560px) {
      #a11yBar .a11y-mecca .a11y-mecca-temp { display:none; }
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
      <button type="button" id="a11yFontDec" aria-label="تصغير حجم الخط" title="تصغير الخط">
        <i class="fa-solid fa-magnifying-glass-minus" aria-hidden="true"></i>
      </button>
      <button type="button" id="a11yFontInc" aria-label="تكبير حجم الخط" title="تكبير الخط">
        <i class="fa-solid fa-magnifying-glass-plus" aria-hidden="true"></i>
      </button>
      <span class="a11y-divider" aria-hidden="true"></span>
      <button type="button" id="a11yContrast" aria-pressed="false" aria-label="تباين عالي" title="تباين عالي">
        <i class="fa-solid fa-circle-half-stroke" aria-hidden="true"></i>
      </button>
      <button type="button" id="a11yUnderline" aria-pressed="false" aria-label="تسطير الروابط" title="تسطير الروابط">
        <i class="fa-solid fa-underline" aria-hidden="true"></i>
      </button>
      <button type="button" id="a11yMotion" aria-pressed="false" aria-label="تقليل الحركة" title="تقليل الحركة">
        <i class="fa-solid fa-person-walking" aria-hidden="true"></i>
      </button>
      <button type="button" id="a11yDyslexia" aria-pressed="false" aria-label="خط سهل القراءة" title="خط سهل القراءة">
        <i class="fa-solid fa-font" aria-hidden="true"></i>
      </button>
      <span class="a11y-divider" aria-hidden="true"></span>
      <button type="button" id="a11yReset" class="a11y-text-btn" aria-label="إعادة الضبط">
        <i class="fa-solid fa-rotate-right" aria-hidden="true"></i> إعادة الضبط
      </button>
    </div>

    <div class="a11y-mecca">
      <span class="a11y-kaaba" aria-hidden="true">🕋</span>
      <span class="a11y-mecca-label">مكة المكرمة</span>
      <span class="a11y-mecca-time" id="a11yMeccaTime">—</span>
      <span class="a11y-sep" aria-hidden="true"></span>
      <span class="a11y-mecca-temp">
        <i class="fa-solid fa-temperature-half" aria-hidden="true"></i>
        <span id="a11yMeccaTemp">—</span>
      </span>
    </div>
  `;

  // ── Place bar directly under the page's navbar/header ───────
  const header = document.querySelector('header');
  if (header) {
    header.insertAdjacentElement('afterend', bar);
  } else {
    document.body.insertBefore(bar, document.body.firstChild);
  }

  function syncStickyOffset() {
    if (header) {
      const rect = header.getBoundingClientRect();
      // Header is itself sticky at top:0, so the bar should stick right beneath it.
      bar.style.top = Math.max(0, rect.height) + 'px';
    } else {
      bar.style.top = '0px';
    }
  }
  syncStickyOffset();
  window.addEventListener('resize', syncStickyOffset);
  window.addEventListener('load', syncStickyOffset);
  if (window.ResizeObserver && header) {
    new ResizeObserver(syncStickyOffset).observe(header);
  }

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
