/**
 * admin.js
 * Common logic for admin dashboard, auth control, and simple stats loading.
 */

async function adminCheckAuth() {
    // Retry up to 10 times (5 seconds) waiting for db to initialize
    let attempts = 0;
    while (!window.db && attempts < 10) {
        await new Promise(r => setTimeout(r, 500));
        attempts++;
    }
    if (!window.db) {
        window.location.href = '/admin/login.html';
        return false;
    }
    const { data: { session } } = await window.db.auth.getSession();
    if (!session) {
        window.location.href = '/admin/login.html';
        return false;
    }

    // تحقق فعلي إن الحساب أدمن (مش مجرد عميل مسجل دخول)
    const { data: isAdmin, error: adminErr } = await window.db.rpc('is_admin');
    if (adminErr || !isAdmin) {
        await window.db.auth.signOut();
        window.location.href = '/admin/login.html';
        return false;
    }

    const userDisplay = document.getElementById('adminUserEmail');
    if (userDisplay) {
        userDisplay.innerHTML = `<i class="fa-solid fa-circle-user ml-1"></i> ${session.user.email}`;
    }
    return true;
}

async function adminLogout() {
    if (!window.db) return;
    await window.db.auth.signOut();
    window.location.href = '/admin/login.html';
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
