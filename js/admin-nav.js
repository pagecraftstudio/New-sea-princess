/**
 * admin-nav.js — Flow Travel & Tourism / DMC Operating System
 * ─────────────────────────────────────────────────────────────
 * Single source of truth for ALL admin dashboard navigation.
 * Renders: mobile top-bar · mobile drawer · desktop sticky sidebar.
 *
 * Features:
 *  • 8 collapsible navigation sections
 *  • Auto-expands section containing the current page
 *  • localStorage persistence (user-controlled collapse state)
 *  • Detail-page → parent item highlighting
 *  • Keyboard shortcut: Ctrl+K / ⌘K → search focus
 *  • Mobile off-canvas drawer
 *
 * Usage:
 *  1. <script src="/js/admin-nav.js"></script> in <head>
 *  2. <div id="adminNavMount"></div> in <body> (before <main>)
 *
 * © 2026 New Sea Princess Tourism & Pagecraft Studio
 */

(function () {
  'use strict';

  var BASE = '/nsp-control-8x4k/';

  /* ── NAV STRUCTURE ── */
  // ── PERMISSION-AWARE NAV ──────────────────────────────────────
  // Each item may have a `permission` key matching permission_matrix.
  // null / undefined = always visible (no permission gate).
  // Items are filtered at render time against window.ADMIN_PERMISSIONS.
  // super_admin always sees everything.
  var NAV = [
    {
      id: 'overview', label: 'نظرة عامة', icon: 'fa-house',
      items: [
        { id: 'dashboard', href: BASE+'dashboard.html',  icon: 'fa-chart-pie',   label: 'لوحة التحكم' },
        { id: 'reports',   href: BASE+'reports.html',    icon: 'fa-chart-bar',   label: 'التقارير',      permission: 'read_reports' },
      ]
    },
    {
      id: 'sales', label: 'المبيعات والـ CRM', icon: 'fa-handshake',
      items: [
        { id: 'crm-dashboard',      href: BASE+'crm-dashboard.html',      icon: 'fa-gauge-high',    label: 'لوحة المبيعات',         permission: 'view_crm_dashboard' },
        { id: 'sales-intelligence', href: BASE+'sales-intelligence.html', icon: 'fa-chart-line',    label: 'ذكاء المبيعات',         permission: 'view_crm_dashboard' },
        { id: 'leads',              href: BASE+'leads.html',              icon: 'fa-user-plus',     label: 'العملاء المحتملون',     permission: 'read_customers' },
        { id: 'opportunities',      href: BASE+'opportunities.html',      icon: 'fa-crosshairs',    label: 'الفرص البيعية',         permission: 'read_customers' },
        { id: 'customers',          href: BASE+'customers.html',          icon: 'fa-address-card',  label: 'العملاء 360°',          permission: 'read_customers' },
        { id: 'newsletter',         href: BASE+'newsletter.html',         icon: 'fa-envelope',      label: 'النشرة البريدية',       permission: 'manage_customers' },
        { id: 'reviews',            href: BASE+'reviews.html',            icon: 'fa-star',          label: 'الآراء والتقييمات',     permission: 'manage_customers' },
      ]
    },
    {
      id: 'quotations', label: 'عروض الأسعار والمنتجات', icon: 'fa-file-contract',
      items: [
        { id: 'quotations',        href: BASE+'quotations.html',       icon: 'fa-file-contract',    label: 'عروض الأسعار',          permission: 'read_customers' },
        { id: 'packages',          href: BASE+'packages.html',         icon: 'fa-suitcase-rolling', label: 'برامج الرحلات',         permission: 'read_packages' },
        { id: 'itinerary-builder', href: BASE+'itinerary-builder.html',icon: 'fa-pencil-ruler',     label: 'منشئ الجداول',          permission: 'manage_itineraries' },
        { id: 'itineraries',       href: BASE+'itineraries.html',      icon: 'fa-map-location-dot', label: 'الجداول السياحية',      permission: 'view_itineraries' },
        { id: 'service-catalog',   href: BASE+'service-catalog.html',  icon: 'fa-boxes-stacked',    label: 'كتالوج الخدمات',        permission: 'manage_service_catalog' },
        { id: 'pricing-rates',     href: BASE+'pricing-rates.html',    icon: 'fa-tags',             label: 'خطط التسعير',           permission: 'view_pricing_engine' },
        { id: 'pricing-margins',   href: BASE+'pricing-margins.html',  icon: 'fa-percent',          label: 'هوامش الربح',           permission: 'view_pricing_engine' },
        { id: 'profitability',     href: BASE+'profitability.html',    icon: 'fa-arrow-trend-up',   label: 'تحليل الربحية',         permission: 'view_profitability' },
      ]
    },
    {
      id: 'operations', label: 'الحجوزات والعمليات', icon: 'fa-calendar-check',
      items: [
        { id: 'bookings',       href: BASE+'bookings.html',       icon: 'fa-calendar-check', label: 'الحجوزات',                permission: 'read_bookings' },
        { id: 'trip-files',     href: BASE+'trip-files.html',     icon: 'fa-folder-open',    label: 'ملفات الرحلات',           permission: 'read_bookings' },
        { id: 'procurement',    href: BASE+'procurement.html',    icon: 'fa-truck-ramp-box', label: 'المشتريات والتأكيدات',    permission: 'read_procurement' },
        { id: 'resources',      href: BASE+'resources.html',      icon: 'fa-users-gear',     label: 'السائقون والمرشدون',      permission: 'read_bookings' },
        { id: 'assignments',    href: BASE+'assignments.html',    icon: 'fa-calendar-day',   label: 'جدول التعيينات',          permission: 'read_bookings' },
        { id: 'communications', href: BASE+'communications.html', icon: 'fa-comments',       label: 'مركز التواصل',            permission: 'manage_communications' },
      ]
    },
    {
      id: 'groups-corporate', label: 'المجموعات والشركات', icon: 'fa-building-user',
      items: [
        { id: 'group-files',        href: BASE+'group-files.html',       icon: 'fa-people-group', label: 'ملفات المجموعات',        permission: 'read_bookings' },
        { id: 'series-tours',       href: BASE+'series-tours.html',      icon: 'fa-repeat',       label: 'الرحلات المتكررة',       permission: 'read_bookings' },
        { id: 'corporate-accounts', href: BASE+'corporate-accounts.html',icon: 'fa-building',     label: 'حسابات الشركات',         permission: 'read_bookings' },
        { id: 'mice-events',        href: BASE+'mice-events.html',       icon: 'fa-star',         label: 'MICE والفعاليات',        permission: 'read_bookings' },
      ]
    },
    {
      id: 'finance', label: 'المالية والمحاسبة', icon: 'fa-coins',
      items: [
        { id: 'financial-dashboard',  href: BASE+'financial-dashboard.html',  icon: 'fa-landmark',              label: 'نظرة مالية عامة',       permission: 'read_invoices' },
        { id: 'accounting-dashboard', href: BASE+'accounting-dashboard.html', icon: 'fa-book',                  label: 'لوحة المحاسبة',          permission: 'read_journal' },
        { id: 'accounting-health',    href: BASE+'accounting-health.html',    icon: 'fa-heart-pulse',           label: 'سلامة المحاسبة',         permission: 'read_journal' },
        { id: 'invoices-payments',    href: BASE+'invoices-payments.html',    icon: 'fa-file-invoice-dollar',   label: 'الفواتير والمدفوعات',    permission: 'read_invoices' },
        { id: 'expenses',             href: BASE+'expenses.html',             icon: 'fa-receipt',               label: 'المصاريف',               permission: 'write_expenses' },
        { id: 'ar-ap',                href: BASE+'ar-ap.html',               icon: 'fa-scale-unbalanced-flip', label: 'الذمم المدينة/الدائنة',  permission: 'read_invoices' },
        { id: 'cash-bank-wallets',    href: BASE+'cash-bank-wallets.html',   icon: 'fa-vault',                 label: 'الخزينة والبنوك',        permission: 'read_cash_bank' },
        { id: 'bank-reconciliation',  href: BASE+'bank-reconciliation.html', icon: 'fa-scale-balanced',        label: 'المطابقة البنكية',       permission: 'read_cash_bank' },
        { id: 'credit-debit-notes',   href: BASE+'credit-debit-notes.html',  icon: 'fa-file-circle-plus',      label: 'إشعارات الخصم والإضافة',permission: 'approve_credit_notes' },
        { id: 'journal-entries',      href: BASE+'journal-entries.html',     icon: 'fa-journal-whills',        label: 'القيود اليومية',         permission: 'read_journal' },
        { id: 'accounting-coa',       href: BASE+'accounting-coa.html',      icon: 'fa-list-ol',               label: 'دليل الحسابات',          permission: 'read_coa' },
        { id: 'fiscal-periods',       href: BASE+'fiscal-periods.html',      icon: 'fa-calendar-days',         label: 'الفترات المالية',        permission: 'read_fiscal' },
      ]
    },
    {
      id: 'suppliers', label: 'الموردون والعقود', icon: 'fa-truck',
      items: [
        { id: 'suppliers',             href: BASE+'suppliers.html',             icon: 'fa-truck',          label: 'إدارة الموردين',        permission: 'read_suppliers' },
        { id: 'supplier-contracts',    href: BASE+'supplier-contracts.html',    icon: 'fa-file-signature', label: 'عقود الموردين',         permission: 'view_supplier_contracts' },
        { id: 'supplier-intelligence', href: BASE+'supplier-intelligence.html', icon: 'fa-chart-bar',      label: 'تحليل الموردين',        permission: 'read_suppliers' },
      ]
    },
    {
      id: 'b2b', label: 'الشراكات B2B', icon: 'fa-handshake-simple',
      items: [
        { id: 'b2b-partners',   href: BASE+'b2b-partners.html',   icon: 'fa-building', label: 'شركاء B2B',      permission: 'manage_partner_inquiries' },
        { id: 'partner-rates',  href: BASE+'partner-rates.html',  icon: 'fa-percent',  label: 'أسعار الشركاء', permission: 'manage_supplier_rates' },
        { id: 'partner-portal', href: BASE+'partner-portal.html', icon: 'fa-globe',    label: 'بوابة الشركاء', permission: 'manage_partner_portal' },
      ]
    },
    {
      id: 'marketing', label: 'التسويق والأتمتة', icon: 'fa-bullhorn',
      items: [
        { id: 'marketing-dashboard', href: BASE+'marketing-dashboard.html', icon: 'fa-bullhorn',        label: 'لوحة التسويق',           permission: 'manage_customers' },
        { id: 'marketing-campaigns', href: BASE+'marketing-campaigns.html', icon: 'fa-paper-plane',     label: 'الحملات التسويقية',      permission: 'manage_customers' },
        { id: 'automation-rules',    href: BASE+'automation-rules.html',    icon: 'fa-robot',           label: 'قواعد الأتمتة',          permission: 'manage_customers' },
        { id: 'automation-log',      href: BASE+'automation-log.html',      icon: 'fa-list-check',      label: 'سجل الأتمتة',            permission: 'manage_customers' },
        { id: 'abandoned-bookings',  href: BASE+'abandoned-bookings.html',  icon: 'fa-cart-arrow-down', label: 'الحجوزات المهجورة',      permission: 'manage_customers' },
      ]
    },
    {
      id: 'ai', label: 'الذكاء الاصطناعي', icon: 'fa-microchip-ai',
      items: [
        { id: 'ai-dashboard',      href: BASE+'ai-dashboard.html',      icon: 'fa-sparkles', label: 'لوحة الذكاء الاصطناعي', permission: 'view_ai_dashboard' },
        { id: 'ai-command-center', href: BASE+'ai-command-center.html', icon: 'fa-terminal', label: 'مركز الأوامر الذكي',     permission: 'use_ai_command_center' },
      ]
    },
    {
      id: 'admin', label: 'الإدارة', icon: 'fa-shield-halved',
      items: [
        { id: 'users',             href: BASE+'users.html',             icon: 'fa-users',          label: 'المستخدمون',     permission: 'manage_users' },
        { id: 'admins',            href: BASE+'admins.html',            icon: 'fa-user-shield',    label: 'مديرو النظام',   permission: 'manage_admins' },
        { id: 'roles-permissions', href: BASE+'roles-permissions.html', icon: 'fa-lock',           label: 'الأدوار والصلاحيات', permission: 'manage_admins' },
        { id: 'audit-log',         href: BASE+'audit-log.html',         icon: 'fa-clipboard-list', label: 'سجل العمليات',   permission: 'view_audit_log' },
      ]
    },
  ];

  /* detail page → parent item id */
  var PARENT_MAP = {
    'lead-detail.html':          'leads',
    'sales-intelligence.html':   'sales-intelligence',
    'customer-detail.html':      'customers',
    'quote-detail.html':         'quotations',
    'b2b-partners.html':         'b2b-partners',
    'partner-rates.html':        'partner-rates',
    'supplier-contracts.html':   'supplier-contracts',
    'trip-file.html':            'trip-files',
    'group-detail.html':         'group-files',
  };

  var ROLE_LABELS = {
    super_admin:'مدير عام', admin:'مشرف', financial_manager:'مدير مالي',
    accountant:'محاسب', cashier:'أمين صندوق', sales_agent:'موظف مبيعات',
    booking_agent:'موظف حجوزات', auditor:'مراجع حسابات', viewer:'مشاهد'
  };

  /* ── PERMISSION FILTERING ── */
  // Returns true if user can see this nav item.
  // super_admin → always true.
  // No permission key → always visible (public admin page).
  // Otherwise checks window.ADMIN_PERMISSIONS array.
  function canSeeItem(item) {
    if (!item.permission) return true;
    var perms = window.ADMIN_PERMISSIONS || [];
    if (perms.indexOf('__all__') !== -1) return true; // super_admin fallback
    return perms.indexOf(item.permission) !== -1;
  }

  // Returns filtered copy of NAV with items user can see.
  // Sections with zero visible items are excluded.
  function filteredNav() {
    var result = [];
    NAV.forEach(function(section) {
      var visibleItems = section.items.filter(canSeeItem);
      if (visibleItems.length > 0) {
        result.push({ id: section.id, label: section.label, icon: section.icon, items: visibleItems });
      }
    });
    return result;
  }

  /* ── ACTIVE DETECTION ── */
  var currentFile = window.location.pathname.split('/').pop() || 'dashboard.html';
  var parentItemId = PARENT_MAP[currentFile] || null;

  function getActiveItemId() {
    if (parentItemId) return parentItemId;
    for (var s = 0; s < NAV.length; s++) {
      for (var i = 0; i < NAV[s].items.length; i++) {
        var item = NAV[s].items[i];
        if (item.href.split('/').pop() === currentFile) return item.id;
      }
    }
    return null;
  }

  function getActiveSectionId() {
    var aId = getActiveItemId();
    if (!aId) return null;
    for (var s = 0; s < NAV.length; s++) {
      for (var i = 0; i < NAV[s].items.length; i++) {
        if (NAV[s].items[i].id === aId) return NAV[s].id;
      }
    }
    return null;
  }

  var ACTIVE_ITEM_ID    = getActiveItemId();
  var ACTIVE_SECTION_ID = getActiveSectionId();

  /* ── LOCALSTORAGE ── */
  var LS_KEY = 'nsp_nav_v2_open';

  function loadOpenSections() {
    try {
      var v = localStorage.getItem(LS_KEY);
      if (v) {
        var parts = v.split(',').filter(Boolean);
        var set = {};
        parts.forEach(function(p){ set[p] = true; });
        return set;
      }
    } catch(e) {}
    return {};
  }

  function saveOpenSections() {
    try {
      var open = [];
      document.querySelectorAll('details.nav-group[open]').forEach(function(el) {
        if (el.dataset.sectionId) open.push(el.dataset.sectionId);
      });
      localStorage.setItem(LS_KEY, open.join(','));
    } catch(e) {}
  }

  function isSectionOpen(sId) {
    if (sId === ACTIVE_SECTION_ID) return true;
    return !!loadOpenSections()[sId];
  }

  /* ── HTML BUILDERS ── */
  function itemHTML(item, isMobile) {
    var isActive = (item.id === ACTIVE_ITEM_ID);
    var closeAttr = isMobile ? ' onclick="NSPNav.closeDrawer()"' : '';
    return '<a href="'+item.href+'" class="nav-link'+(isActive?' active':'')+'"'+
      (isActive?' aria-current="page"':'')+closeAttr+
      ' title="'+item.label+'">'+
      '<i class="fa-solid '+item.icon+' nav-item-icon"></i>'+
      '<span class="nav-item-label">'+item.label+'</span>'+
      '</a>';
  }

  function sectionHTML(section, isMobile) {
    var open = isSectionOpen(section.id);
    var items = section.items.map(function(i){ return itemHTML(i, isMobile); }).join('');
    return '<details class="nav-group" data-section-id="'+section.id+'"'+(open?' open':'')+'>'+
      '<summary class="nav-section-header" aria-expanded="'+(open?'true':'false')+'">'+
        '<i class="fa-solid '+section.icon+' nav-section-icon"></i>'+
        '<span class="nav-section-label">'+section.label+'</span>'+
        '<i class="fa-solid fa-chevron-down nav-chevron"></i>'+
      '</summary>'+
      '<div class="nav-group-items">'+items+'</div>'+
    '</details>';
  }

  function allSectionsHTML(isMobile) {
    return filteredNav().map(function(s){ return sectionHTML(s, isMobile); }).join('');
  }

  /* ── MAIN HTML ── */
  function buildHTML() {
    return '\
<!-- MOBILE TOP BAR -->\
<header class="md:hidden sticky top-0 z-50 flex items-center justify-between px-4 py-3 shadow-lg no-print" style="background:#0D1B0E">\
  <div class="flex items-center gap-3">\
    <div class="w-8 h-8 rounded-lg flex items-center justify-center shrink-0" style="background:linear-gradient(135deg,#1B5E20,#B8860B)">\
      <i class="fa-solid fa-plane text-white text-sm"></i>\
    </div>\
    <div><div class="font-bold text-sm leading-tight" style="color:#B8860B">Flow Travel</div>\
    <div class="text-xs" style="color:#6b7280">DMC Operating System</div></div>\
  </div>\
  <button id="nspMobileMenuBtn" class="p-2 rounded-lg transition hover:bg-white/10" style="color:white" aria-label="فتح القائمة" aria-expanded="false">\
    <i class="fa-solid fa-bars text-xl"></i>\
  </button>\
</header>\
\
<!-- MOBILE DRAWER -->\
<div id="nspMobileDrawer" class="md:hidden fixed inset-0 z-[100] hidden no-print" role="dialog" aria-modal="true">\
  <div id="nspDrawerOverlay" class="absolute inset-0 bg-black/60" style="backdrop-filter:blur(2px)"></div>\
  <nav class="absolute top-0 right-0 h-full w-72 flex flex-col shadow-2xl" style="background:#0D1B0E">\
    <div class="flex items-center justify-between px-4 py-4 border-b shrink-0" style="border-color:#1a2e1c">\
      <div class="flex items-center gap-3">\
        <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background:linear-gradient(135deg,#1B5E20,#B8860B)">\
          <i class="fa-solid fa-plane text-white text-sm"></i>\
        </div>\
        <span class="font-bold text-sm" style="color:#B8860B">Flow Travel</span>\
      </div>\
      <button id="nspDrawerClose" class="p-1.5 rounded transition" style="color:#9ca3af" aria-label="إغلاق">\
        <i class="fa-solid fa-xmark text-lg"></i>\
      </button>\
    </div>\
    <div class="flex-1 overflow-y-auto py-2">'+allSectionsHTML(true)+'</div>\
    <div class="p-3 border-t shrink-0" style="border-color:#1a2e1c">\
      <div class="flex items-center gap-3 mb-3">\
        <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold shrink-0" style="background:#1B5E20;color:#B8860B" id="userAvatarMobile">—</div>\
        <div class="min-w-0"><p class="text-xs font-semibold truncate" style="color:#d1d5db" id="adminUserEmailMobile">—</p>\
        <p class="text-xs" style="color:#6b7280" id="userRoleMobile">—</p></div>\
      </div>\
      <button onclick="adminLogout()" class="w-full py-2 rounded-lg text-xs font-semibold flex items-center justify-center gap-2 transition"\
        style="background:#2d1b1b;color:#fca5a5"\
        onmouseover="this.style.background=\'#7f1d1d\'" onmouseout="this.style.background=\'#2d1b1b\'">\
        <i class="fa-solid fa-right-from-bracket"></i> تسجيل الخروج\
      </button>\
    </div>\
  </nav>\
</div>\
\
<!-- FLEX WRAPPER -->\
<div class="flex flex-1 min-h-0">\
\
<!-- DESKTOP SIDEBAR -->\
<aside class="hidden md:flex w-64 shrink-0 flex-col sticky top-0 h-screen no-print" style="background:#0D1B0E;border-left:1px solid #1a2e1c">\
  <div class="flex items-center gap-3 px-4 border-b shrink-0" style="border-color:#1a2e1c;min-height:64px">\
    <div class="w-9 h-9 rounded-xl flex items-center justify-center shrink-0" style="background:linear-gradient(135deg,#1B5E20,#B8860B)">\
      <i class="fa-solid fa-plane text-white text-base"></i>\
    </div>\
    <div class="min-w-0">\
      <div class="font-bold text-sm leading-tight" style="color:#B8860B">Flow Travel</div>\
      <div class="text-xs leading-tight truncate" style="color:#6b7280">DMC Operating System</div>\
    </div>\
  </div>\
  <div class="px-3 pt-3 pb-2 shrink-0">\
    <div class="relative">\
      <i class="fa-solid fa-magnifying-glass absolute right-3 top-1/2 -translate-y-1/2 text-xs pointer-events-none" style="color:#6b7280"></i>\
      <input id="nspNavSearch" type="text" placeholder="ابحث… (Ctrl+K)" autocomplete="off"\
        class="w-full text-xs rounded-lg py-2 pr-8 pl-3 outline-none border transition-colors"\
        style="background:#111827;color:#d1d5db;border-color:#374151;font-family:Cairo,sans-serif"\
        onfocus="this.style.borderColor=\'#B8860B\'" onblur="this.style.borderColor=\'#374151\'"\
        oninput="NSPNav.filterNav(this.value)" aria-label="بحث في القائمة">\
    </div>\
  </div>\
  <nav id="nspDesktopNav" class="flex-1 overflow-y-auto" style="scrollbar-width:thin;scrollbar-color:#1a2e1c transparent">\
    '+allSectionsHTML(false)+'\
  </nav>\
  <div class="p-3 border-t shrink-0" style="border-color:#1a2e1c">\
    <div class="flex items-center gap-3 mb-3 px-1">\
      <div class="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold shrink-0" style="background:#1B5E20;color:#B8860B" id="userAvatar">—</div>\
      <div class="min-w-0 flex-1">\
        <p class="text-xs font-semibold truncate" style="color:#d1d5db" id="adminUserEmail">جاري التحميل…</p>\
        <p class="text-xs" style="color:#6b7280" id="userRole">—</p>\
      </div>\
    </div>\
    <button onclick="adminLogout()" class="w-full py-2 rounded-lg text-xs font-semibold flex items-center justify-center gap-2 transition"\
      style="background:#2d1b1b;color:#fca5a5"\
      onmouseover="this.style.background=\'#7f1d1d\'" onmouseout="this.style.background=\'#2d1b1b\'">\
      <i class="fa-solid fa-right-from-bracket"></i> تسجيل الخروج\
    </button>\
  </div>\
</aside>';
  }

  /* ── NAV SEARCH ── */
  function filterNav(query) {
    var q = (query||'').trim();
    var nav = document.getElementById('nspDesktopNav');
    if (!nav) return;
    if (!q) { nav.innerHTML = allSectionsHTML(false); bindSectionToggle(); return; }

    var matches = [];
    filteredNav().forEach(function(s) {
      s.items.forEach(function(i) {
        if (i.label.indexOf(q) !== -1 || i.id.indexOf(q.toLowerCase()) !== -1) {
          matches.push(i);
        }
      });
    });
    nav.innerHTML = matches.length
      ? '<div style="padding:6px 12px 2px;font-size:10px;color:#6b7280;font-weight:700">نتائج البحث</div>' +
        matches.map(function(i){ return itemHTML(i, false); }).join('')
      : '<p style="color:#6b7280;font-size:11px;text-align:center;padding:24px 12px">لا توجد نتائج</p>';
  }

  /* ── SECTION TOGGLE PERSISTENCE ── */
  function bindSectionToggle() {
    document.querySelectorAll('details.nav-group').forEach(function(det) {
      det.addEventListener('toggle', function() {
        var sum = det.querySelector('summary');
        if (sum) sum.setAttribute('aria-expanded', det.open ? 'true' : 'false');
        saveOpenSections();
      });
    });
  }

  /* ── MOBILE DRAWER ── */
  function openDrawer() {
    var d = document.getElementById('nspMobileDrawer');
    var b = document.getElementById('nspMobileMenuBtn');
    if (d) { d.classList.remove('hidden'); document.body.style.overflow='hidden'; }
    if (b) b.setAttribute('aria-expanded','true');
  }
  function closeDrawer() {
    var d = document.getElementById('nspMobileDrawer');
    var b = document.getElementById('nspMobileMenuBtn');
    if (d) { d.classList.add('hidden'); document.body.style.overflow=''; }
    if (b) b.setAttribute('aria-expanded','false');
  }

  /* ── USER INFO ── */
  function populateUserInfo() {
    if (!window.db) return;
    window.db.auth.getSession().then(function(r) {
      var session = r && r.data && r.data.session;
      if (!session) return;
      var email = session.user.email || '';
      var initial = email.charAt(0).toUpperCase();
      ['adminUserEmail','adminUserEmailMobile'].forEach(function(id){
        var el = document.getElementById(id);
        if (el) el.textContent = email;
      });
      ['userAvatar','userAvatarMobile'].forEach(function(id){
        var el = document.getElementById(id);
        if (el) el.textContent = initial;
      });
      var role = window.ADMIN_ROLE || '';
      var roleLabel = ROLE_LABELS[role] || role;
      ['userRole','userRoleMobile'].forEach(function(id){
        var el = document.getElementById(id);
        if (el) el.textContent = roleLabel;
      });
    }).catch(function(){});
  }

  /* ── MOUNT ── */
  function mount() {
    var mountEl = document.getElementById('adminNavMount');
    if (!mountEl) return;

    var tmp = document.createElement('div');
    tmp.innerHTML = buildHTML();
    while (tmp.firstChild) mountEl.parentNode.insertBefore(tmp.firstChild, mountEl);
    mountEl.remove();

    document.body.classList.add('flex','flex-col','min-h-screen');

    var flexWrapper = document.querySelector('div.flex.flex-1');
    var main = document.querySelector('main');
    if (flexWrapper && main && !flexWrapper.contains(main)) {
      flexWrapper.appendChild(main);
    }

    document.getElementById('nspMobileMenuBtn') && document.getElementById('nspMobileMenuBtn').addEventListener('click', openDrawer);
    document.getElementById('nspDrawerClose')   && document.getElementById('nspDrawerClose').addEventListener('click', closeDrawer);
    document.getElementById('nspDrawerOverlay') && document.getElementById('nspDrawerOverlay').addEventListener('click', closeDrawer);

    document.addEventListener('keydown', function(e) {
      if (e.key === 'Escape') closeDrawer();
      if ((e.ctrlKey||e.metaKey) && e.key === 'k') { e.preventDefault(); var s = document.getElementById('nspNavSearch'); if(s) s.focus(); }
    });

    bindSectionToggle();
    populateUserInfo();
    setTimeout(populateUserInfo, 900);
  }

  /* ── SKELETON ── */
  function skeleton(count, type) {
    count = count || 4;
    if (type === 'row') {
      return Array(count).fill(0).map(function(){ return '<tr class="animate-pulse"><td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-24"></div></td><td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-32"></div></td><td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-20"></div></td><td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-16"></div></td><td class="px-4 py-3"><div class="h-3 bg-gray-200 rounded w-12"></div></td></tr>'; }).join('');
    }
    return Array(count).fill(0).map(function(){ return '<div class="bg-white rounded-xl border border-gray-200 p-4 shadow-sm animate-pulse"><div class="h-3 bg-gray-200 rounded w-1/2 mb-3"></div><div class="h-7 bg-gray-100 rounded w-3/4"></div></div>'; }).join('');
  }

  function init() {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
    else mount();
  }

  // ── PERMISSION REFRESH ───────────────────────────────────────
  // Called after adminCheckAuth() sets window.ADMIN_PERMISSIONS.
  // Re-renders the nav sections to apply permission filtering.
  function refreshPermissions() {
    var desktopNav = document.getElementById('nspDesktopNav');
    if (desktopNav) {
      desktopNav.innerHTML = allSectionsHTML(false);
      bindSectionToggle();
    }
    // Mobile drawer: nav items are in the flex-1 overflow-y-auto container inside the drawer
    var mobileContainer = document.querySelector('#nspMobileDrawer .flex-1.overflow-y-auto');
    if (mobileContainer) {
      mobileContainer.innerHTML = allSectionsHTML(true);
    }
  }

  window.NSPNav = { init: init, mount: mount, openDrawer: openDrawer, closeDrawer: closeDrawer, filterNav: filterNav, skeleton: skeleton, refreshPermissions: refreshPermissions };
  init();

})();
