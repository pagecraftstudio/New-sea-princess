/**
 * tracking.js
 * Handles fetching booking status and rendering the timeline.
 */

// Fix 3: added awaiting_payment as first stage
const stagesDef = [
    { key: 'awaiting_payment', name: 'في انتظار الدفع' },
    { key: 'pending',          name: 'تم استلام الطلب، وجاري المراجعة' }, // Fix 6: space added
    { key: 'confirmed',        name: 'تم تأكيد الحجز' },
    { key: 'visa_processing',  name: 'استخراج التأشيرة' },
    { key: 'tickets_issued',   name: 'إصدار تذاكر الطيران' },
    { key: 'travelling',       name: 'الرحلة جارية — تقبل الله' },
    { key: 'completed',        name: 'اكتملت الرحلة بسلام' },
    { key: 'cancelled',        name: 'تم الإلغاء' }
];

const linearOrder = ['awaiting_payment', 'pending', 'confirmed', 'visa_processing', 'tickets_issued', 'travelling', 'completed'];

async function trackBooking() {
    const input = document.getElementById('bookingInput').value.trim().toUpperCase();
    if (!input) return;

    document.getElementById('trackBtn').innerHTML = '<div class="loader" style="width:20px;height:20px;border-width:2px;margin:auto;"></div>';
    document.getElementById('resultArea').classList.add('hidden');
    document.getElementById('errorArea').classList.add('hidden');

    if (!window.db) {
        document.getElementById('errorArea').classList.remove('hidden');
        document.getElementById('trackBtn').innerHTML = 'بحث';
        return;
    }

    try {
        const { data, error } = await window.db
            .from('bookings')
            .select('*')
            .eq('booking_number', input)
            .single();

        if (error || !data) throw error;
        renderResults(data);

    } catch (err) {
        document.getElementById('errorArea').classList.remove('hidden');
    } finally {
        document.getElementById('trackBtn').innerHTML = 'بحث';
    }
}

function renderResults(booking) {
    document.getElementById('resultArea').classList.remove('hidden');

    // Mask name for privacy
    const nameParts = booking.customer_name.split(' ');
    const maskedName = nameParts.length > 0 ? nameParts[0] + ' ****' : '****';

    document.getElementById('resNumber').innerText  = booking.booking_number;
    document.getElementById('resPackage').innerText = booking.package_title;
    document.getElementById('resName').innerText    = maskedName;
    document.getElementById('resDate').innerText    = window.formatDate(booking.package_departure);

    const badge = document.getElementById('resBadge');
    if (booking.status === 'cancelled') {
        badge.innerText   = 'ملغي';
        badge.className   = 'bg-red-500 px-3 py-1 rounded text-white text-sm font-bold shadow-sm';
    } else if (booking.status === 'awaiting_payment') {
        badge.innerText   = 'في انتظار الدفع';
        badge.className   = 'bg-orange-500 px-3 py-1 rounded text-white text-sm font-bold shadow-sm';
    } else {
        badge.innerText   = 'فعال';
        badge.className   = 'bg-green-600 px-3 py-1 rounded text-white text-sm font-bold shadow-sm';
    }

    if (booking.status_details) {
        document.getElementById('adminNotesArea').classList.remove('hidden');
        document.getElementById('adminNoteText').innerText = booking.status_details;
    } else {
        document.getElementById('adminNotesArea').classList.add('hidden');
    }

    renderTimeline(booking.status);
}

function renderTimeline(currentStatus) {
    const container = document.getElementById('timeline');
    container.innerHTML = '';

    if (currentStatus === 'cancelled') {
        container.innerHTML = `
            <div class="relative pr-6 pb-2 text-red-600 font-bold">
                <div class="absolute right-[-7px] top-1 w-4 h-4 rounded-full bg-red-500 z-10 border-2 border-white shadow"></div>
                تم إلغاء هذا الحجز. للمساعدة اتصل بخدمة العملاء.
            </div>`;
        return;
    }

    let currentIndex = linearOrder.indexOf(currentStatus);
    if (currentIndex === -1) currentIndex = 0;

    let html = '';
    linearOrder.forEach((stage, idx) => {
        let stateClass = '';
        let iconHtml   = '';
        let textColor  = 'text-gray-400';

        if (idx < currentIndex) {
            stateClass = 'bg-primary border-primary';
            iconHtml   = '<i class="fa-solid fa-check text-[10px] text-white"></i>';
            textColor  = 'text-gray-700 font-semibold';
        } else if (idx === currentIndex) {
            stateClass = 'bg-gold border-white ring-2 ring-gold shadow-md';
            iconHtml   = '<i class="fa-solid fa-spinner animate-spin text-[10px] text-white"></i>';
            textColor  = 'text-primary font-bold text-lg';
        } else {
            stateClass = 'bg-gray-200 border-white text-transparent';
            textColor  = 'text-gray-400';
        }

        const stageName = stagesDef.find(s => s.key === stage).name;

        html += `
            <div class="relative pr-8 pb-8 last:pb-0">
                <div class="absolute right-[-9px] top-1 w-5 h-5 rounded-full flex items-center justify-center z-10 border-2 ${stateClass}">
                    ${iconHtml}
                </div>
                <div class="${textColor} transition-all">${stageName}</div>
            </div>
        `;
    });

    container.innerHTML = html;
}

document.addEventListener('DOMContentLoaded', async () => {
    document.getElementById('trackBtn').addEventListener('click', trackBooking);
    document.getElementById('bookingInput').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') trackBooking();
    });

    const urlParams = new URLSearchParams(window.location.search);
    const bNum = urlParams.get('booking');
    if (bNum) {
        document.getElementById('bookingInput').value = bNum;
        trackBooking();
    }
});
