/**
 * package-detail.js — نيو سي برنسيس فرع الزقازيق فرع الزقازيق
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

    // ── Hotels + Room Tiers (dynamic multi-hotel) ──────────────
    const hotelsSection = document.getElementById('hotelsSection');

    // Selection state
    let selectedHotelId   = null;   // 'mecca-0', 'madina-1', etc.
    let selectedTierId    = null;   // 'mecca-0-tier-1', etc.
    let selectedTierPrice = null;   // null = use package base price

    function renderHotelsSection() {
      const meccaHotels  = Array.isArray(data.mecca_hotels)  ? data.mecca_hotels  : [];
      const madinaHotels = Array.isArray(data.madina_hotels) ? data.madina_hotels : [];

      // Fallback: build single-hotel list from legacy flat fields
      const meccaList  = meccaHotels.length  ? meccaHotels  : (data.mecca_hotel  ? [{ name: data.mecca_hotel,  stars: data.mecca_hotel_stars,  nights: data.nights_mecca,  distance: data.mecca_hotel_distance,  room_tiers: [] }] : []);
      const madinaList = madinaHotels.length ? madinaHotels : (data.medina_hotel ? [{ name: data.medina_hotel, stars: data.medina_hotel_stars, nights: data.nights_medina, distance: data.medina_hotel_distance, room_tiers: [] }] : []);

      const cityBlock = (cityKey, hotels, icon, label, colorClass, borderClass) => {
        if (!hotels.length) return '';
        return `
          <div>
            <h3 class="font-bold text-lg mb-3 flex items-center gap-2">
              <i class="fa-solid fa-${icon} ${colorClass}"></i> ${label}
            </h3>
            <div class="space-y-4">
              ${hotels.map((h, hi) => {
                const hotelId  = `${cityKey}-${hi}`;
                const isHotelSelected = selectedHotelId === hotelId;
                const stars    = '★'.repeat(h.stars||0);
                const tiers    = Array.isArray(h.room_tiers) ? h.room_tiers : [];
                return `
                  <div class="border-2 rounded-xl overflow-hidden transition-all ${isHotelSelected ? borderClass + ' shadow-md' : 'border-gray-200'}">
                    <!-- Hotel Card -->
                    <button type="button"
                            onclick="selectHotel('${hotelId}')"
                            class="w-full text-right p-4 flex items-start gap-4 hover:bg-gray-50 transition">
                      <div class="flex-shrink-0 w-10 h-10 rounded-full flex items-center justify-center ${isHotelSelected ? 'bg-primary text-white' : 'bg-gray-100 text-gray-400'}">
                        ${isHotelSelected ? '<i class="fa-solid fa-check"></i>' : `<span class="font-bold text-sm">${hi+1}</span>`}
                      </div>
                      <div class="flex-1">
                        <div class="flex items-center justify-between flex-wrap gap-1">
                          <h4 class="font-bold text-darkBg text-lg">${h.name}</h4>
                          <span class="text-gold text-sm font-bold">${stars}</span>
                        </div>
                        ${h.distance ? `<p class="text-sm text-gray-500 mt-0.5"><i class="fa-solid fa-location-dot ml-1"></i>${h.distance}</p>` : ''}
                        ${h.description ? `<p class="text-sm text-gray-600 mt-1">${h.description}</p>` : ''}
                        ${h.nights ? `<p class="text-xs text-gray-400 mt-1"><i class="fa-solid fa-moon ml-1"></i>إقامة ${h.nights} ليالي</p>` : ''}
                        ${tiers.length === 0 ? '<p class="text-xs text-primary font-semibold mt-1">اضغط لاختيار هذا الفندق</p>' : '<p class="text-xs text-primary font-semibold mt-1">اضغط لاختيار واختيار نوع الغرفة</p>'}
                      </div>
                    </button>

                    <!-- Room Tiers (shown when hotel selected and has tiers) -->
                    ${isHotelSelected && tiers.length > 0 ? `
                      <div class="border-t border-gray-100 bg-gray-50 p-4">
                        <p class="text-sm font-bold text-gray-700 mb-3"><i class="fa-solid fa-bed ml-1 text-gold"></i>اختر نوع الغرفة:</p>
                        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                          ${tiers.map((t, ti) => {
                            const tierId = `${hotelId}-tier-${ti}`;
                            const isTierSelected = selectedTierId === tierId;
                            return `
                              <button type="button"
                                      onclick="selectTier('${hotelId}','${tierId}',${t.price||0})"
                                      class="text-right p-3 rounded-xl border-2 transition-all ${isTierSelected ? 'border-primary bg-green-50 shadow-sm' : 'border-gray-200 bg-white hover:border-primary hover:shadow-sm'}">
                                <div class="flex items-start justify-between gap-1 mb-1">
                                  <span class="font-bold text-darkBg text-sm">${t.label}</span>
                                  ${isTierSelected ? '<i class="fa-solid fa-circle-check text-primary text-lg shrink-0"></i>' : ''}
                                </div>
                                ${t.description ? `<p class="text-xs text-gray-500 mb-1">${t.description}</p>` : ''}
                                <p class="text-gold font-bold text-base mt-1">${window.formatCurrency(t.price||0)}</p>
                              </button>
                            `;
                          }).join('')}
                        </div>
                      </div>
                    ` : ''}
                  </div>
                `;
              }).join('')}
            </div>
          </div>
        `;
      };

      hotelsSection.innerHTML = `
        <div class="space-y-8">
          ${cityBlock('mecca',  meccaList,  'kaaba',  'مكة المكرمة',    'text-primary',    'border-primary')}
          ${cityBlock('madina', madinaList, 'mosque', 'المدينة المنورة', 'text-blue-600',   'border-blue-500')}
        </div>
      `;
    }

    window.selectHotel = function(hotelId) {
      if (selectedHotelId === hotelId) {
        // Deselect
        selectedHotelId   = null;
        selectedTierId    = null;
        selectedTierPrice = null;
      } else {
        selectedHotelId   = hotelId;
        selectedTierId    = null;
        selectedTierPrice = null;
      }
      updateSidebarPrice();
      renderHotelsSection();
    };

    window.selectTier = function(hotelId, tierId, price) {
      selectedHotelId   = hotelId;
      selectedTierId    = tierId;
      selectedTierPrice = price;
      updateSidebarPrice();
      renderHotelsSection();
    };

    function updateSidebarPrice() {
      const displayPrice = selectedTierPrice !== null ? selectedTierPrice : data.price_per_person;
      const priceEl = document.getElementById('priceAdult');
      const hintEl  = document.getElementById('priceHint');
      if (priceEl) priceEl.innerText = window.formatCurrency(displayPrice);
      if (hintEl && window.getCurrencyHint) {
        hintEl.innerHTML = `<span class="price-hint">${window.getCurrencyHint(displayPrice)}</span>`;
      }
      // Show tier label under price
      let tierLabelEl = document.getElementById('selectedTierLabel');
      if (!tierLabelEl) {
        tierLabelEl = document.createElement('p');
        tierLabelEl.id = 'selectedTierLabel';
        tierLabelEl.className = 'text-xs text-primary font-bold mt-1';
        priceEl?.parentNode?.insertBefore(tierLabelEl, hintEl);
      }
      tierLabelEl.textContent = selectedTierId ? '✔ ' + getTierLabel(selectedHotelId, selectedTierId) : '';
    }

    function getTierLabel(hotelId, tierId) {
      const [city, hi, , ti] = tierId.split('-');
      const hotels = city === 'mecca' ? (data.mecca_hotels||[]) : (data.madina_hotels||[]);
      const hotel  = hotels[parseInt(hi)];
      return hotel?.room_tiers?.[parseInt(ti)]?.label || '';
    }

    renderHotelsSection();

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
        // Check if there are hotels and rooms that require selection
        const meccaHotels  = Array.isArray(data.mecca_hotels)  ? data.mecca_hotels  : [];
        const madinaHotels = Array.isArray(data.madina_hotels) ? data.madina_hotels : [];
        const allHotels    = [...meccaHotels, ...madinaHotels];
        const hasMultipleHotels   = allHotels.length > 1;
        const hasAnyRoomTiers     = allHotels.some(h => h.room_tiers?.length > 0);

        // If there are multiple hotels, a selection is required
        if (hasMultipleHotels && !selectedHotelId) {
            const btn = document.getElementById('startBookingBtn');
            btn.classList.add('animate-bounce');
            setTimeout(() => btn.classList.remove('animate-bounce'), 1000);
            // Scroll to hotels section
            document.getElementById('hotelsSection')?.scrollIntoView({ behavior:'smooth', block:'center' });
            alert('يرجى اختيار الفندق المناسب قبل الحجز');
            return;
        }
        // If hotel has room tiers, a tier must be selected
        if (hasAnyRoomTiers && selectedHotelId && !selectedTierId) {
            document.getElementById('hotelsSection')?.scrollIntoView({ behavior:'smooth', block:'center' });
            alert('يرجى اختيار نوع الغرفة قبل الحجز');
            return;
        }

        const { data: { session } } = await window.db.auth.getSession();

        // Build booking URL with selections
        let bookingUrl = `/booking.html?package=${data.id}`;
        if (selectedHotelId)   bookingUrl += `&hotel=${encodeURIComponent(selectedHotelId)}`;
        if (selectedTierId)    bookingUrl += `&tier=${encodeURIComponent(selectedTierId)}`;
        if (selectedTierPrice) bookingUrl += `&tierPrice=${selectedTierPrice}`;

        if (!session) {
            window.location.href = '/login.html?next=' + encodeURIComponent(bookingUrl);
            return;
        }
        window.location.href = bookingUrl;
    };
    document.getElementById('waContactBtn').href = `https://wa.me/201031777295?text=${encodeURIComponent(`مرحباً، أود الاستفسار عن ${data.title}`)}`;
    document.getElementById('compareFromDetail').href = `/packages.html?preselect=${data.id}`;

    } catch (err) {
    console.error(err);
    document.getElementById('loader').innerHTML = '<p class="text-error font-bold">حدث خطأ. لم يتم العثور على البرنامج.</p>';
    }
});
