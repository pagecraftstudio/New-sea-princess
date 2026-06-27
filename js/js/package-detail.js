/**
 * package-detail.js — نيو سي برنسيس للسياحة
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */
document.addEventListener('DOMContentLoaded', async () => {
    const urlParams = new URLSearchParams(window.location.search);
    const packageId = urlParams.get('id');

    if (!packageId) {
    window.location.href = '/packages.html';
    return;
    }

    try {
    const { data, error } = await window.db.from('packages').select('*').eq('id', packageId).single();
    if (error) throw error;
    
    document.getElementById('loader').style.display = 'none';
    document.getElementById('packageContent').style.display = 'flex';

    // Make package data available to print-utils.js (printPackagePDF)
    window.currentPackage = data;

    // Populate Data
    document.getElementById('pkgImage').src = data.thumbnail_url || 'https://images.unsplash.com/photo-1565552643982-2d18ca2bf7fa?auto=format&fit=crop&q=80&w=1200';
    document.getElementById('pkgBadge').innerText = data.category;
    document.getElementById('pkgTitle').innerText = data.title;
    document.getElementById('pkgDate').innerText = window.formatDate(data.departure_date);
    document.getElementById('pkgDuration').innerText = data.duration_nights + ' ليالي';
    document.getElementById('pkgCity').innerText = data.departure_city;
    document.getElementById('pkgFlight').innerText = data.flight_type || 'مباشر';

    // Hotels
    document.getElementById('meccaHotel').innerText = data.mecca_hotel;
    document.getElementById('meccaStars').innerText = '★'.repeat(data.mecca_hotel_stars);
    document.getElementById('meccaNights').innerText = `إقامة لـ ${data.nights_mecca} ليالي`;
    if(data.mecca_hotel_distance) document.getElementById('meccaDist').innerHTML += data.mecca_hotel_distance;

    document.getElementById('medinaHotel').innerText = data.medina_hotel;
    document.getElementById('medinaStars').innerText = '★'.repeat(data.medina_hotel_stars);
    document.getElementById('medinaNights').innerText = `إقامة لـ ${data.nights_medina} ليالي`;
    if(data.medina_hotel_distance) document.getElementById('medinaDist').innerHTML += data.medina_hotel_distance;

    // Optional arrays render helper
    const renderList = (elId, arr) => {
        const el = document.getElementById(elId);
        if(!el) return;
        if(arr && arr.length > 0) {
            el.innerHTML = arr.map(item => `<li><i class="fa-solid fa-check text-gold ml-2"></i>${item}</li>`).join('');
        } else {
            el.innerHTML = '<li class="text-gray-400">لا يوجد بيانات</li>';
        }
    };

    renderList('pkgIncludes', data.includes);
    renderList('pkgExcludes', data.excludes);

    // Itinerary List
    const itineraryEl = document.getElementById('pkgItinerary');
    if (itineraryEl) {
        if(data.itinerary && data.itinerary.length > 0) {
            itineraryEl.innerHTML = data.itinerary.map(item => `
                <div class="mb-4 bg-gray-50 p-4 rounded border border-gray-100">
                    <h4 class="font-bold text-lg mb-2 text-primary">اليوم ${item.day}: ${item.title}</h4>
                    <p class="text-sm text-gray-700">${item.description}</p>
                </div>
            `).join('');
        } else {
            itineraryEl.innerHTML = '<p class="text-gray-400">برنامج الرحلة غير متوفر</p>';
        }
    }

    // Prices & Sidebar
    document.getElementById('priceAdult').innerText = window.formatCurrency(data.price_per_person);

    // Funnel tracking: package_view
    if (window.trackEvent) {
      window.trackEvent('package_view', {
        package_id:    data.id,
        package_title: data.title
      });
    }

    // Currency hint (uses currency-hint.js)
    const hintEl = document.getElementById('priceHint');
    if (hintEl && window.getCurrencyHint) {
        hintEl.dataset.egp = data.price_per_person;
        hintEl.innerHTML = `<span class="price-hint">${window.getCurrencyHint(data.price_per_person)}</span>`;
        // Wrap parent for updateAllHints compatibility
        hintEl.closest('[data-egp]') || hintEl.setAttribute('data-egp', data.price_per_person);
        if (window.fetchLiveHintRates) window.fetchLiveHintRates();
    }

    if (data.price_child) {
        const childElem = document.getElementById('priceChild');
        childElem.innerHTML = `سعر الطفل المرافق: <strong>${window.formatCurrency(data.price_child)}</strong>`;
        childElem.classList.remove('hidden');
    }
    document.getElementById('seatsAvailable').innerText = data.available_seats;
    
    // Buttons
    document.getElementById('startBookingBtn').onclick = async () => {
        const { data: { session } } = await window.db.auth.getSession();
        if (!session) {
            const returnUrl = encodeURIComponent('/booking.html?package=' + data.id);
            window.location.href = '/login.html?next=' + returnUrl;
            return;
        }
        window.location.href = `/booking.html?package=${data.id}`;
    };
    document.getElementById('waContactBtn').href = `https://wa.me/201031777295?text=${encodeURIComponent(`مرحباً، أود الاستفسار عن ${data.title}`)}`;
    document.getElementById('compareFromDetail').href = `/packages.html?preselect=${data.id}`;

    } catch (err) {
    console.error(err);
    document.getElementById('loader').innerHTML = '<p class="text-error font-bold">حدث خطأ. لم يتم العثور على البرنامج.</p>';
    }
});
