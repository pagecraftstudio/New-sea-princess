/**
 * admin-nav.js — نيو سي برنسيس
 * Single source of truth for the admin sidebar navigation.
 * Renders both the desktop <aside> and the mobile drawer <nav>,
 * marks the active link, and wires up the mobile toggle.
 *
 * Usage (every admin page):
 *   1. In <head>: <script src="/js/admin-nav.js"></script>
 *   2. In <body>: place <div id="adminNavMount"></div> where the sidebar should appear.
 *      The script will inject: mobile top-bar + mobile drawer + desktop aside.
 *   3. Call NSPNav.init() after DOMContentLoaded (or let it auto-init).
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * ─────────────────────────────────────────────────────────
 */

(function () {
  'use strict';

  // ── NAV STRUCTURE ─────────────────────────────────────────────────────────
  // Edit here ONCE and it propagates to every admin page.
  const NAV_SECTIONS = [
    {
      id:    'overview',
      flat:  true,   // rendered outside any <details> group
      items: [
        { href: '/nsp-control-8x4k/dashboard.html', icon: 'fa-chart-pie', label: 'نظرة عامة' },
      ],
    },
    {
      id:    'operations',
      label: 'العمليات',
      icon:  'fa-plane-departure',
      items: [
        { href: '/nsp-control-8x4k/bookings.html',  icon: 'fa-address-book',    label: 'الحجوزات' },
        { href: '/nsp-control-8x4k/packages.html',  icon: 'fa-suitcase-rolling', label: 'برامج الرحلات' },
        { href: '/nsp-control-8x4k/reviews.html',   icon: 'fa-comments',         label: 'الآراء والتقييمات' },
        { href: '/nsp-control-8x4k/newsletter.html',icon: 'fa-bell',             label: 'النشرة البريدية' },
        { href: '/nsp-control-8x4k/suppliers.html', icon: 'fa-truck',            label: 'الموردون' },
      ],
    },
    {
      id:    'finance',
      label: 'المالية والمحاسبة',
      icon:  'fa-coins',
      items: [
        { href: '/nsp-control-8x4k/customers.html',           icon: 'fa-users',                label: 'العملاء' },
        { href: '/nsp-control-8x4k/financial-dashboard.html', icon: 'fa-landmark',             label: 'المالية - نظرة عامة' },
        { href: '/nsp-control-8x4k/accounting-dashboard.html',icon: 'fa-book',                 label: 'لوحة المحاسبة' },
        { href: '/nsp-control-8x4k/journal-entries.html',     icon: 'fa-journal-whills',       label: 'القيود اليومية' },
        { href: '/nsp-control-8x4k/invoices-payments.html',   icon: 'fa-file-invoice-dollar',  label: 'الفواتير والمدفوعات' },
        { href: '/nsp-control-8x4k/credit-debit-notes.html',  icon: 'fa-file-circle-plus',     label: 'إشعارات الخصم والإضافة' },
        { href: '/nsp-control-8x4k/expenses.html',            icon: 'fa-receipt',              label: 'المصاريف' },
        { href: '/nsp-control-8x4k/cash-bank-wallets.html',   icon: 'fa-vault',                label: 'الخزينة والبنوك' },
        { href: '/nsp-control-8x4k/bank-reconciliation.html', icon: 'fa-scale-balanced',       label: 'المطابقة البنكية' },
        { href: '/nsp-control-8x4k/ar-ap.html',               icon: 'fa-scale-unbalanced-flip',label: 'الذمم المدينة/الدائنة' },
        { href: '/nsp-control-8x4k/profitability.html',       icon: 'fa-chart-line',           label: 'تحليل الربحية' },
        { href: '/nsp-control-8x4k/accounting-coa.html',      icon: 'fa-list-ol',              label: 'دليل الحسابات' },
        { href: '/nsp-control-8x4k/fiscal-periods.html',      icon: 'fa-calendar-days',        label: 'الفترات المالية' },
        { href: '/nsp-control-8x4k/reports.html',             icon: 'fa-file-chart-column',    label: 'التقارير المالية' },
      ],
    },
    {
      id:    'users',
      label: 'المستخدمون والصلاحيات',
      icon:  'fa-users-gear',
      items: [
        { href: '/nsp-control-8x4k/users.html',            icon: 'fa-user',         label: 'المستخدمون' },
        { href: '/nsp-control-8x4k/admins.html',           icon: 'fa-user-shield',  label: 'إدارة الأدمن' },
        { href: '/nsp-control-8x4k/roles-permissions.html',icon: 'fa-lock',         label: 'الأدوار والصلاحيات' },
      ],
    },
    {
      id:    'system',
      label: 'النظام',
      icon:  'fa-gear',
      items: [
        { href: '/nsp-control-8x4k/audit-log.html',         icon: 'fa-clipboard-list', label: 'سجل العمليات' },
        { href: '/nsp-control-8x4k/accounting-health.html', icon: 'fa-heart-pulse',    label: 'سلامة النظام' },
      ],
    },
  ];

  // ── HELPERS ───────────────────────────────────────────────────────────────
  const currentPath = window.location.pathname;

  function isActive(href) {
    return currentPath === href || currentPath.startsWith(href.replace('.html', ''));
  }

  function linkHTML(item, mobile) {
    const active  = isActive(item.href) ? ' active' : '';
    const onclick = mobile ? ' onclick="NSPNav.closeDrawer()"' : '';
    return `<a href="${item.href}" class="nav-link${active}"${onclick}><i class="fa-solid ${item.icon} w-5"></i>${item.label}</a>`;
  }

  function sectionHTML(section, mobile) {
    if (section.flat) {
      return section.items.map(i => linkHTML(i, mobile)).join('');
    }
    // Auto-open the section that contains the active page
    const hasActive = section.items.some(i => isActive(i.href));
    const open = hasActive ? ' open' : '';
    return `
      <details class="nav-group"${open}>
        <summary class="nav-section-header">
          <i class="fa-solid ${section.icon}"></i>
          <span>${section.label}</span>
          <i class="fa-solid fa-chevron-down nav-chevron"></i>
        </summary>
        ${section.items.map(i => linkHTML(i, mobile)).join('')}
      </details>`;
  }

  function allSectionsHTML(mobile) {
    return NAV_SECTIONS.map(s => sectionHTML(s, mobile)).join('');
  }

  // ── RENDER ─────────────────────────────────────────────────────────────────
  function buildHTML() {
    return `
    <!-- ══ MOBILE TOP BAR ══ -->
    <header class="md:hidden sticky top-0 z-50 bg-darkBg text-white flex items-center justify-between px-4 py-3 shadow-lg no-print">
      <div class="flex items-center gap-2 font-bold text-lg text-gold">
        <i class="fa-solid fa-moon"></i> الإدارة
      </div>
      <button id="nspMobileMenuBtn" class="text-white text-2xl p-1" aria-label="القائمة">
        <i class="fa-solid fa-bars"></i>
      </button>
    </header>

    <!-- ══ MOBILE DRAWER ══ -->
    <div id="nspMobileDrawer" class="md:hidden fixed inset-0 z-[60] hidden no-print">
      <div id="nspDrawerOverlay" class="absolute inset-0 bg-black/60"></div>
      <nav class="absolute top-0 right-0 h-full w-64 bg-darkBg text-white flex flex-col shadow-2xl">
        <div class="h-16 flex items-center justify-between px-4 border-b border-gray-800">
          <span class="text-gold font-bold">القائمة</span>
          <button id="nspDrawerClose" class="text-gray-400 hover:text-white text-xl" aria-label="إغلاق">
            <i class="fa-solid fa-xmark"></i>
          </button>
        </div>
        <div class="flex-1 overflow-y-auto py-3">
          ${allSectionsHTML(true)}
        </div>
        <div class="p-4 border-t border-gray-800">
          <p class="text-xs text-gray-500 mb-2 text-center" id="adminUserEmailMobile"></p>
          <button onclick="adminLogout()" class="w-full bg-red-900/50 text-red-300 hover:bg-red-800 py-2 rounded transition flex justify-center items-center gap-2">
            <i class="fa-solid fa-right-from-bracket"></i> تسجيل خروج
          </button>
        </div>
      </nav>
    </div>

    <!-- ══ FLEX ROW WRAPPER: desktop sidebar + main content ══ -->
    <div class="flex min-h-screen md:min-h-[calc(100vh-0px)]">

    <!-- ══ DESKTOP SIDEBAR ══ -->
    <aside class="hidden md:flex w-64 bg-darkBg text-white flex-col sticky top-0 h-screen shrink-0 no-print">
      <div class="h-16 flex items-center justify-center border-b border-gray-800 text-gold font-bold text-xl px-4">
        <img src="/assets/logo-white.png" alt="" class="h-8 w-auto ml-2" onerror="this.style.display='none'" decoding="async"> الإدارة
      </div>

      <!-- Search -->
      <div class="px-3 pt-3 pb-1">
        <div class="relative">
          <i class="fa-solid fa-magnifying-glass absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 text-xs"></i>
          <input id="nspNavSearch" type="text" placeholder="ابحث في القائمة…"
            class="w-full bg-gray-800/60 text-gray-200 text-xs rounded-lg py-2 pr-8 pl-3 outline-none border border-gray-700 focus:border-gold placeholder-gray-600 font-sans"
            style="font-family:'Cairo',sans-serif;"
            oninput="NSPNav.filterNav(this.value)">
        </div>
      </div>

      <nav id="nspDesktopNav" class="flex-1 overflow-y-auto py-2">
        ${allSectionsHTML(false)}
      </nav>
      <div class="p-4 border-t border-gray-800">
        <p class="text-xs text-gray-500 mb-2 text-center" id="adminUserEmail"></p>
        <button onclick="adminLogout()" class="w-full bg-red-900/50 text-red-300 hover:bg-red-800 py-2 rounded transition flex justify-center items-center gap-2">
          <i class="fa-solid fa-right-from-bracket"></i> تسجيل خروج
        </button>
      </div>
    </aside>
    <!-- ↑ closing </div class="flex"> must come AFTER <main> in the page -->`;
  }

  // ── NAV SEARCH ────────────────────────────────────────────────────────────
  function filterNav(query) {
    const q = query.trim().toLowerCase();
    const nav = document.getElementById('nspDesktopNav');
    if (!nav) return;

    if (!q) {
      // Restore full nav
      nav.innerHTML = allSectionsHTML(false);
      return;
    }

    // Flat filtered list
    const matches = NAV_SECTIONS.flatMap(s => s.items)
      .filter(i => i.label.includes(q) || i.href.includes(q));

    nav.innerHTML = matches.length
      ? matches.map(i => linkHTML(i, false)).join('')
      : '<p style="color:#6b7280;font-size:12px;text-align:center;padding:24px 12px;">لا توجد نتائج</p>';
  }

  // ── MOBILE DRAWER TOGGLE ──────────────────────────────────────────────────
  function openDrawer()  {
    const d = document.getElementById('nspMobileDrawer');
    if (d) { d.classList.remove('hidden'); document.body.style.overflow = 'hidden'; }
  }
  function closeDrawer() {
    const d = document.getElementById('nspMobileDrawer');
    if (d) { d.classList.add('hidden'); document.body.style.overflow = ''; }
  }

  // ── MOUNT ─────────────────────────────────────────────────────────────────
  function mount() {
    const mountEl = document.getElementById('adminNavMount');
    if (!mountEl) return;

    // Inject nav HTML (replaces the mount div)
    mountEl.outerHTML = buildHTML();

    // Make body a flex column so mobile header stacks above the flex row
    document.body.classList.add('flex', 'flex-col', 'bg-gray-100', 'min-h-screen');

    // Move <main> inside the flex wrapper (alongside <aside>)
    // buildHTML() opens a <div class="flex"> containing <aside> but leaves it unclosed.
    // <main> is a sibling of adminNavMount in the page HTML, so after injection
    // we must move it inside the flex wrapper div.
    const main = document.querySelector('main');
    const flexWrapper = document.querySelector('div.flex.min-h-screen, div[class*="min-h-screen"]');
    if (main && flexWrapper && !flexWrapper.contains(main)) {
      flexWrapper.appendChild(main);
    }

    // Wire up events
    document.getElementById('nspMobileMenuBtn')?.addEventListener('click', openDrawer);
    document.getElementById('nspDrawerClose')?.addEventListener('click', closeDrawer);
    document.getElementById('nspDrawerOverlay')?.addEventListener('click', closeDrawer);

    // Keyboard shortcut: Ctrl+K / Cmd+K focuses nav search
    document.addEventListener('keydown', e => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
        e.preventDefault();
        document.getElementById('nspNavSearch')?.focus();
      }
    });

    // Sync logged-in admin email to sidebar footer
    if (window.db) {
      window.db.auth.getSession().then(({ data }) => {
        const email = data?.session?.user?.email || '';
        document.querySelectorAll('#adminUserEmail, #adminUserEmailMobile').forEach(el => {
          if (el) el.textContent = email;
        });
      });
    }
  }

  // ── SKELETON HELPERS (for pages to call) ──────────────────────────────────
  // Usage: NSPNav.skeleton(count) returns an HTML string of skeleton cards
  function skeleton(count = 4, type = 'card') {
    if (type === 'row') {
      return Array.from({ length: count }, () => `
        <tr class="animate-pulse">
          <td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-24"></div></td>
          <td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-32"></div></td>
          <td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-20"></div></td>
          <td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-16"></div></td>
          <td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-12"></div></td>
        </tr>`).join('');
    }
    return Array.from({ length: count }, () => `
      <div class="bg-white rounded-xl border border-gray-200 p-4 shadow-sm animate-pulse">
        <div class="h-3 bg-gray-200 rounded w-1/2 mb-3"></div>
        <div class="h-7 bg-gray-100 rounded w-3/4"></div>
      </div>`).join('');
  }

  // ── AUTO-INIT ─────────────────────────────────────────────────────────────
  function init() {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', mount);
    } else {
      mount();
    }
  }

  // ── PUBLIC API ────────────────────────────────────────────────────────────
  window.NSPNav = { init, mount, openDrawer, closeDrawer, filterNav, skeleton };

  // Auto-run
  init();

})();
