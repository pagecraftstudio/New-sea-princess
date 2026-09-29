/**
 * partner-layout.js
 * Renders the shared sidebar nav for all partner portal pages.
 * Call PartnerLayout.init() after requirePartnerAuth() resolves.
 */
window.PartnerLayout = (() => {

  const NAV = [
    { href:'dashboard.html',  icon:'fa-gauge-high',      label:'لوحة التحكم' },
    { href:'inquiries.html',  icon:'fa-paper-plane',     label:'طلباتي' },
    { href:'quotes.html',     icon:'fa-file-contract',   label:'عروض الأسعار' },
    { href:'bookings.html',   icon:'fa-calendar-check',  label:'الحجوزات' },
    { href:'invoices.html',   icon:'fa-file-invoice',    label:'الفواتير' },
    { href:'account.html',    icon:'fa-user-gear',       label:'حسابي' },
  ];

  function init() {
    const mount = document.getElementById('partnerNavMount');
    if (!mount) return;

    const current = window.location.pathname.split('/').pop();

    mount.innerHTML = `
    <!-- Mobile top bar -->
    <div class="md:hidden flex items-center justify-between bg-green-900 text-white px-4 py-3 sticky top-0 z-50">
      <div class="flex items-center gap-2">
        <i class="fa-solid fa-handshake-simple text-gold text-lg" style="color:#B8860B"></i>
        <span class="font-bold text-sm" id="companyName">Flow Partner</span>
      </div>
      <button onclick="document.getElementById('mobileMenu').classList.toggle('hidden')" class="text-white">
        <i class="fa-solid fa-bars"></i>
      </button>
    </div>

    <!-- Mobile menu -->
    <div id="mobileMenu" class="hidden md:hidden bg-green-950 text-white">
      ${NAV.map(n => `
        <a href="${n.href}" class="flex items-center gap-3 px-5 py-3 text-sm font-bold border-b border-green-900 ${current===n.href?'text-yellow-400':'text-gray-300'} hover:text-white">
          <i class="fa-solid ${n.icon} w-4 text-center"></i>${n.label}
        </a>`).join('')}
      <button onclick="PartnerAuth.signOut()" class="flex items-center gap-3 px-5 py-3 text-sm font-bold text-red-400 w-full hover:text-red-300">
        <i class="fa-solid fa-right-from-bracket w-4 text-center"></i>تسجيل الخروج
      </button>
    </div>

    <!-- Desktop sidebar -->
    <aside class="hidden md:flex flex-col w-64 min-h-screen bg-green-950 text-white sticky top-0 shrink-0">
      <!-- Logo -->
      <div class="px-6 py-5 border-b border-green-800">
        <div class="flex items-center gap-2 mb-1">
          <i class="fa-solid fa-handshake-simple text-yellow-400 text-xl"></i>
          <span class="font-black text-base text-white">Flow Travel</span>
        </div>
        <p class="text-xs text-green-400 font-bold">بوابة الشركاء</p>
      </div>

      <!-- Partner info -->
      <div class="px-5 py-4 border-b border-green-800">
        <div class="flex items-center gap-3">
          <div class="w-10 h-10 rounded-full bg-yellow-500/20 flex items-center justify-center text-yellow-400 font-black text-lg shrink-0">
            <i class="fa-solid fa-building text-base"></i>
          </div>
          <div class="min-w-0">
            <p class="font-bold text-sm text-white truncate" id="companyName">جارٍ التحميل…</p>
            <p class="text-xs text-green-400 truncate" id="partnerName"></p>
          </div>
        </div>
      </div>

      <!-- Nav links -->
      <nav class="flex-1 py-3">
        ${NAV.map(n => `
          <a href="${n.href}"
             class="flex items-center gap-3 px-5 py-3 text-sm font-bold transition-colors
               ${current===n.href
                 ? 'bg-green-800 text-white border-r-4 border-yellow-400'
                 : 'text-green-300 hover:bg-green-900 hover:text-white'}">
            <i class="fa-solid ${n.icon} w-4 text-center ${current===n.href?'text-yellow-400':''}"></i>
            ${n.label}
          </a>`).join('')}
      </nav>

      <!-- Sign out -->
      <div class="px-5 py-4 border-t border-green-800">
        <button onclick="PartnerAuth.signOut()"
          class="flex items-center gap-2 text-sm font-bold text-red-400 hover:text-red-300 transition-colors w-full">
          <i class="fa-solid fa-right-from-bracket"></i>تسجيل الخروج
        </button>
      </div>
    </aside>`;
  }

  return { init };
})();
