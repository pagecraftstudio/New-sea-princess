/**
 * admin.js
 * Common logic for admin dashboard, auth control, and simple stats loading.
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

async function adminCheckAuth() {
    // Retry up to 10 times (5 seconds) waiting for db to initialize
    let attempts = 0;
    while (!window.db && attempts < 10) {
        await new Promise(r => setTimeout(r, 500));
        attempts++;
    }
    if (!window.db) { window.location.href = '/nsp-control-8x4k/login.html'; return false; }

    const { data: { session } } = await window.db.auth.getSession();
    if (!session) { window.location.href = '/nsp-control-8x4k/login.html'; return false; }

    // جلب الدور من قاعدة البيانات
    const { data: role, error: roleErr } = await window.db.rpc('get_admin_role');
    if (roleErr || !role) {
        await window.db.auth.signOut();
        window.location.href = '/nsp-control-8x4k/login.html';
        return false;
    }

    // حفظ الدور عالمياً
    window.ADMIN_ROLE = role; // 'super_admin' | 'admin' | 'viewer'

    // جلب الصلاحيات وحفظها عالمياً لاستخدامها في القائمة الجانبية
    try {
        const { data: permsData } = await window.db.rpc('get_my_permissions');
        window.ADMIN_PERMISSIONS = (permsData && permsData.permissions) ? permsData.permissions : [];
    } catch (e) {
        // super_admin يحصل على كل الصلاحيات كـ fallback
        window.ADMIN_PERMISSIONS = role === 'super_admin' ? ['__all__'] : [];
    }

    // إعادة رسم القائمة الجانبية بعد تحميل الصلاحيات
    if (window.NSPNav && typeof window.NSPNav.refreshPermissions === 'function') {
        window.NSPNav.refreshPermissions();
    }

    // تحديث UI باسم المستخدم + شارة الدور
    const userDisplay = document.getElementById('adminUserEmail');
    if (userDisplay) {
        const roleLabel = ROLE_LABELS[role] || role;
        const roleColor = {
            super_admin:       '#DAA520',
            admin:             '#3b82f6',
            financial_manager: '#10b981',
            accountant:        '#06b6d4',
            cashier:           '#8b5cf6',
            sales_agent:       '#f59e0b',
            booking_agent:     '#f97316',
            auditor:           '#64748b',
            viewer:            '#9ca3af',
        }[role] || '#9ca3af';
        userDisplay.innerHTML = `
            <i class="fa-solid fa-circle-user ml-1"></i> ${session.user.email}
            <span style="display:block;margin-top:4px;font-size:10px;font-weight:800;color:${roleColor};">
                ${roleLabel}
            </span>`;
    }

    // تطبيق إخفاء العناصر حسب الدور
    applyRoleUI();

    return true;
}

// ── التحقق قبل أي عملية حساسة ──
// ── Role hierarchy (H1 fix: all 9 roles mapped) ──────────────────────────────
// Hierarchy reflects trust level for UI gating.
// For sensitive operations, prefer has_permission() DB check instead.
const ROLE_HIERARCHY = {
    viewer:            0,
    auditor:           1,  // read-only across finance + bookings
    cashier:           2,  // payments only
    accountant:        3,  // financial write, no approval
    booking_agent:     4,  // booking write, no finance
    sales_agent:       4,  // same tier as booking_agent
    financial_manager: 5,  // financial write + approval
    admin:             6,
    super_admin:       7,
};

// Role display labels (Arabic)
const ROLE_LABELS = {
    super_admin:       'مدير عام',
    financial_manager: 'مدير مالي',
    accountant:        'محاسب',
    cashier:           'أمين صندوق',
    sales_agent:       'موظف مبيعات',
    booking_agent:     'موظف حجوزات',
    auditor:           'مراجع حسابات',
    admin:             'مشرف',
    viewer:            'مشاهد',
};

function requireRole(minimumRole) {
    const current  = ROLE_HIERARCHY[window.ADMIN_ROLE]  ?? -1;
    const required = ROLE_HIERARCHY[minimumRole]         ?? 99;
    if (current < required) {
        if (typeof showToast === 'function') {
            showToast('ليس لديك صلاحية لهذه العملية', true);
        } else {
            alert('ليس لديك صلاحية لهذه العملية');
        }
        return false;
    }
    return true;
}

// ── إخفاء/تعطيل العناصر الحساسة حسب الدور ──────────────────────────────────
function applyRoleUI() {
    const role  = window.ADMIN_ROLE;
    const level = ROLE_HIERARCHY[role] ?? -1;

    // Show role label wherever [data-role-label] exists
    document.querySelectorAll('[data-role-label]').forEach(el => {
        el.textContent = ROLE_LABELS[role] || role || '';
    });

    // Hide elements that require a higher role than current user has
    // data-role="super_admin"       → visible only to super_admin
    // data-role="admin"             → visible to admin + super_admin
    // data-role="financial_manager" → visible to financial_manager and above
    // data-role="sales_agent"       → visible to sales_agent tier and above
    // data-role="viewer"            → visible to everyone (never hidden)
    document.querySelectorAll('[data-role]').forEach(el => {
        const required = ROLE_HIERARCHY[el.dataset.role] ?? 0;
        if (level < required) {
            el.style.display  = 'none';
            el.disabled       = true;
            el.style.opacity  = '0.4';
            el.style.cursor   = 'not-allowed';
            el.title          = 'ليس لديك صلاحية لهذه العملية';
        }
    });

    // viewer: disable all action buttons not already hidden
    if (role === 'viewer') {
        document.querySelectorAll('button:not([data-role]), a.btn:not([data-role])').forEach(el => {
            el.disabled      = true;
            el.style.opacity = '0.4';
            el.style.cursor  = 'not-allowed';
            el.title         = 'ليس لديك صلاحية لهذه العملية';
        });
    }

    // إضافة رابط إدارة الأدمن للـ super_admin فقط
    if (role === 'super_admin') {
        document.querySelectorAll('.admin-sidebar-nav, .sidebar-nav').forEach(nav => {
            if (!nav.querySelector('a[href="/nsp-control-8x4k/admins.html"]')) {
                const link = document.createElement('a');
                link.href = '/nsp-control-8x4k/admins.html';
                link.className = 'nav-link';
                link.innerHTML = '<i class="fa-solid fa-user-shield w-5"></i>إدارة الأدمن';
                nav.appendChild(link);
            }
        });
    }
}

async function adminLogout() {
    if (!window.db) return;
    await window.db.auth.signOut();
    window.location.href = '/nsp-control-8x4k/login.html';
}

// ══════════════════════════════════════════════════════════
//  AUDIT LOG — تسجيل كل عملية إضافة/تعديل/حذف في اللوحة
// ══════════════════════════════════════════════════════════
/**
 * @param {string} action      'create' | 'update' | 'delete'
 * @param {string} tableName   اسم الجدول المتأثر
 * @param {string} recordId    id السجل المتأثر (اختياري)
 * @param {string} recordLabel وصف مختصر يسهل القراءة (مثال: اسم البرنامج)
 * @param {object} details     تفاصيل إضافية اختيارية (مثال: { from: 'pending', to: 'confirmed' })
 */
async function logAudit(action, tableName, recordId, recordLabel, details) {
    try {
        if (!window.db) return;
        const { data: { session } } = await window.db.auth.getSession();
        const adminEmail = session?.user?.email || 'غير معروف';
        const adminId    = session?.user?.id || null;

        await window.db.from('audit_logs').insert({
            admin_email:  adminEmail,
            admin_id:     adminId,
            action:       action,
            table_name:   tableName,
            record_id:    recordId || null,
            record_label: recordLabel || null,
            details:      details || null,
        });
    } catch (err) {
        // لا نوقف العملية الأساسية لو فشل تسجيل اللوج
        console.error('Audit log error:', err);
    }
}


// Logic specifically for dashboard.html
async function loadDashboardStats() {
    try {
        // Bookings KPIs & Revenue
        const { data: bookings, error: bErr } = await window.db.from('bookings').select('total_price, status, booking_number, customer_name, package_title');
        if (bErr) throw bErr;

        const total   = bookings.length;
        // Fix 4: count both pending AND awaiting_payment as "pending"
        const pending = bookings.filter(b => b.status === 'pending' || b.status === 'awaiting_payment').length;
        const revenue = bookings.reduce((sum, b) => b.status !== 'cancelled' ? sum + Number(b.total_price) : sum, 0);

        document.getElementById('kpiTotal').innerText   = total;
        document.getElementById('kpiPending').innerText = pending;
        document.getElementById('kpiRev').innerText     = window.formatCurrency(revenue).replace('ج.م.', '').trim();

        // Packages KPI
        const { count: pkgCount, error: pErr } = await window.db.from('packages').select('*', { count: 'exact', head: true }).eq('is_active', true);
        if (!pErr) document.getElementById('kpiPkgs').innerText = pkgCount;

        // Recent Bookings Table
        const recent = [...bookings].sort((a, b) => a.booking_number < b.booking_number ? 1 : -1).slice(0, 5);
        renderRecentBookings(recent);

    } catch (err) {
        console.error('Dashboard error:', err);
    }
}

function renderRecentBookings(rows) {
    const table = document.getElementById('recentBookingsTable');
    if (!table) return;

    if (rows.length === 0) {
        table.innerHTML = '<tr><td colspan="5" class="p-4 text-center">لا توجد حجوزات</td></tr>';
        return;
    }

    // Fix 7: full badge map including awaiting_payment
    const badges = {
        awaiting_payment: `<span class="bg-orange-100 text-orange-800 px-2 py-0.5 rounded text-xs font-bold">في انتظار الدفع</span>`,
        pending:          `<span class="bg-yellow-100 text-yellow-800 px-2 py-0.5 rounded text-xs font-bold">قيد المراجعة</span>`,
        confirmed:        `<span class="bg-green-100 text-green-800 px-2 py-0.5 rounded text-xs font-bold">مؤكد</span>`,
        visa_processing:  `<span class="bg-blue-100 text-blue-800 px-2 py-0.5 rounded text-xs font-bold">جاري التأشيرة</span>`,
        tickets_issued:   `<span class="bg-indigo-100 text-indigo-800 px-2 py-0.5 rounded text-xs font-bold">تذاكر صادرة</span>`,
        completed:        `<span class="bg-purple-100 text-purple-800 px-2 py-0.5 rounded text-xs font-bold">مكتمل</span>`,
        cancelled:        `<span class="bg-red-100 text-red-800 px-2 py-0.5 rounded text-xs font-bold">ملغي</span>`,
    };

    table.innerHTML = rows.map(r => `
        <tr class="hover:bg-gray-50 border-b border-gray-50 last:border-0">
            <td class="p-3 font-mono font-bold text-primary text-xs">${r.booking_number}</td>
            <td class="p-3">${r.customer_name}</td>
            <td class="p-3 truncate max-w-[150px]" title="${r.package_title}">${r.package_title}</td>
            <td class="p-3 font-bold">${window.formatCurrency(r.total_price)}</td>
            <td class="p-3">${badges[r.status] || `<span class="bg-gray-100 text-gray-600 px-2 py-0.5 rounded text-xs">${r.status}</span>`}</td>
        </tr>
    `).join('');
}
