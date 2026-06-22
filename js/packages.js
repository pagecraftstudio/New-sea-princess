/**
 * packages.js
 * Handles fetching, filtering, and displaying packages on packages.html
 */

let allPackages = [];
let compareList = []; // up to 2 IDs

function toggleCompare(id, title) {
  const idx = compareList.indexOf(id);
  if (idx > -1) {
    compareList.splice(idx, 1);
  } else {
    if (compareList.length >= 2) {
      alert('يمكنك مقارنة برنامجين فقط في نفس الوقت. أزل أحدهما أولاً.');
      return;
    }
    compareList.push(id);
  }
  updateCompareBanner();
  // re-render buttons state only
  document.querySelectorAll('[data-compare-id]').forEach(btn => {
    const isSelected = compareList.includes(btn.dataset.compareId);
    btn.classList.toggle('bg-primary', isSelected);
    btn.classList.toggle('text-white', isSelected);
    btn.classList.toggle('bg-gray-100', !isSelected);
    btn.classList.toggle('text-gray-600', !isSelected);
    btn.innerHTML = isSelected
      ? '<i class="fa-solid fa-check"></i> تمت الإضافة'
      : '<i class="fa-solid fa-code-compare"></i> قارن';
  });
}

function updateCompareBanner() {
  let banner = document.getElementById('compareBanner');
  if (!banner) {
    banner = document.createElement('div');
    banner.id = 'compareBanner';
    banner.className = 'fixed bottom-5 left-1/2 -translate-x-1/2 z-50 bg-darkBg text-white px-6 py-3 rounded-2xl shadow-2xl flex items-center gap-4 transition-all duration-300';
    document.body.appendChild(banner);
  }
  if (compareList.length === 0) { banner.style.display = 'none'; return; }
  banner.style.display = 'flex';
  const canCompare = compareList.length === 2;
  banner.innerHTML = `
    <i class="fa-solid fa-code-compare text-gold text-lg"></i>
    <span class="text-sm font-bold">${compareList.length === 1 ? 'اختر برنامجاً ثانياً للمقارنة' : 'جاهز للمقارنة!'}</span>
    ${canCompare ? `<button onclick="goCompare()" class="bg-gold hover:bg-lightGold text-white font-bold px-4 py-1.5 rounded-lg text-sm transition">عرض المقارنة</button>` : ''}
    <button onclick="compareList=[];updateCompareBanner();document.querySelectorAll('[data-compare-id]').forEach(b=>{b.classList.add('bg-gray-100','text-gray-600');b.classList.remove('bg-primary','text-white');b.innerHTML='<i class=\\'fa-solid fa-code-compare\\'></i> قارن'});" class="text-gray-400 hover:text-white text-xs underline">إلغاء</button>
  `;
}

function goCompare() {
  if (compareList.length < 2) return;
  window.location.href = `/compare.html?a=${compareList[0]}&b=${compareList[1]}`;
}


async function loadPackages() {
    if (!window.db) return;
    try {
        const { data, error } = await window.db
            .from('packages')
            .select('*')
            .eq('is_active', true)
            .order('created_at', { ascending: false });

        if (error) throw error;
        allPackages = data;
        
        // Auto-apply filters from URL if coming from home page
        const urlParams = new URLSearchParams(window.location.search);
        const catParam    = urlParams.get('cat');
        const seasonParam = urlParams.get('season');
        const priceParam  = urlParams.get('priceMax');

        if (catParam) {
            document.querySelectorAll('.filter-cat').forEach(cb => {
                if (cb.value === catParam) cb.checked = true;
            });
        }
        if (seasonParam) {
            document.getElementById('filterSeason').value = seasonParam;
        }
        if (priceParam) {
            const slider = document.getElementById('filterPriceMax');
            const label  = document.getElementById('priceMaxLabel');
            if (slider) {
                slider.value = priceParam;
                if (label) label.textContent = Number(priceParam).toLocaleString('ar-EG');
            }
        }

        applyFilters();
    } catch (err) {
        console.error("Error loading packages:", err);
        document.getElementById('packagesList').innerHTML = `<p class="col-span-full text-center text-error border p-4 rounded">حدث خطأ أثناء تحميل البرامج.</p>`;
    }
}

function updatePriceLabel(val) {
    document.getElementById('priceMaxLabel').textContent = Number(val).toLocaleString('ar-EG');
}

function applyFilters() {
    const checkedCats = Array.from(document.querySelectorAll('.filter-cat:checked')).map(cb => cb.value);
    const season = document.getElementById('filterSeason').value;
    const sortBy = document.getElementById('sortOptions').value;

    const checkedDurs = Array.from(document.querySelectorAll('.filter-dur:checked')).map(cb => Number(cb.value));
    const priceMax = Number(document.getElementById('filterPriceMax')?.value || 30000);

    let filtered = allPackages.filter(pkg => {
        let match = true;
        if (checkedCats.length > 0 && !checkedCats.includes(pkg.category)) match = false;
        if (season && pkg.season !== season) match = false;
        if (pkg.price_per_person > priceMax) match = false;
        if (checkedDurs.length > 0) {
            const nights = pkg.duration_nights;
            const inDur = checkedDurs.some(d => d === 21 ? nights >= 21 : nights === d);
            if (!inDur) match = false;
        }
        return match;
    });

    if (sortBy === 'price_asc') {
        filtered.sort((a,b) => a.price_per_person - b.price_per_person);
    } else if (sortBy === 'price_desc') {
        filtered.sort((a,b) => b.price_per_person - a.price_per_person);
    } else {
        // newest (default order already applied but let's re-ensure by date)
        filtered.sort((a,b) => new Date(b.created_at) - new Date(a.created_at));
    }

    renderPackages(filtered);
}

function renderPackages(packages) {
    const container = document.getElementById('packagesList');
    document.getElementById('resultsCount').innerText = packages.length;

    if (packages.length === 0) {
        container.innerHTML = `
            <div class="col-span-full text-center py-12 bg-white rounded-xl border border-gray-200">
                <i class="fa-solid fa-box-open text-6xl text-gray-300 mb-4"></i>
                <h3 class="text-xl font-bold text-gray-600">لا توجد برامج تطابق هذا البحث</h3>
                <button onclick="document.getElementById('resetFilters').click()" class="mt-4 text-gold hover:underline">إعادة تعيين الفلاتر</button>
            </div>`;
        return;
    }

    container.innerHTML = packages.map(pkg => {
        let badgeColor = pkg.category === 'VIP' ? 'bg-gold' : (pkg.category === 'متميز' ? 'bg-blue-600' : 'bg-primary');
        let availablePerc = (pkg.available_seats / pkg.max_seats) * 100;
        let urgencyColor = pkg.available_seats <= 10 ? 'bg-red-500' : 'bg-green-500';

        return `
        <div class="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden hover:shadow-lg transition flex flex-col group">
            <div class="h-48 relative overflow-hidden">
                <div class="absolute top-3 right-3 ${badgeColor} text-white px-3 py-1 rounded text-sm font-bold z-10 shadow">${pkg.category}</div>
                 <div class="absolute top-3 left-3 bg-white/90 text-primary px-2 py-1 rounded text-xs font-bold z-10 shadow flex items-center gap-1">
                    <i class="fa-solid fa-moon"></i> ${pkg.season || 'طوال العام'}
                </div>
                <img src="${pkg.thumbnail_url || 'https://images.unsplash.com/photo-1565552643982-2d18ca2bf7fa?auto=format&fit=crop&q=80&w=600'}" class="w-full h-full object-cover group-hover:scale-110 transition duration-700">
                <div class="absolute bottom-0 inset-x-0 bg-gradient-to-t from-black/80 to-transparent p-3 text-white text-sm">
                    <i class="fa-regular fa-clock"></i> ${pkg.duration_nights} ليالي
                </div>
            </div>
            <div class="p-4 flex-1 flex flex-col">
                <h3 class="font-bold text-lg text-primary mb-2">${pkg.title}</h3>
                
                <div class="bg-gray-50 border border-gray-100 p-2 rounded mb-3 text-sm grid grid-cols-2 gap-2 text-gray-600">
                    <div class="truncate" title="فندق مكة"><i class="fa-solid fa-kaaba text-gold w-4 text-center"></i> ${pkg.mecca_hotel} <span class="text-gold text-xs">${'★'.repeat(pkg.mecca_hotel_stars)}</span></div>
                    <div class="truncate" title="فندق المدينة"><i class="fa-solid fa-mosque text-gold w-4 text-center"></i> ${pkg.medina_hotel} <span class="text-gold text-xs">${'★'.repeat(pkg.medina_hotel_stars)}</span></div>
                </div>

                <div class="text-sm text-gray-500 mb-4">
                    <i class="fa-solid fa-calendar-day w-4 text-center"></i> المغادرة: <span class="text-darkBg font-semibold">${window.formatDate(pkg.departure_date)}</span>
                </div>

                <div class="mt-auto mb-4">
                    <div class="flex justify-between text-xs mb-1">
                        <span>المقاعد المتبقية: <strong class="text-darkBg">${pkg.available_seats}</strong></span>
                    </div>
                    <div class="w-full bg-gray-200 rounded-full h-1.5">
                        <div class="${urgencyColor} h-1.5 rounded-full" style="width: ${availablePerc}%"></div>
                    </div>
                </div>

                <div class="border-t border-gray-100 pt-4 flex justify-between items-center mt-auto">
                    <div>
                        <div class="text-gold font-bold text-xl">${window.formatCurrency(pkg.price_per_person)}</div>
                        <div class="text-xs text-gray-400">للفرد الواحد</div>
                    </div>
                    <a href="/package-detail.html?id=${pkg.id}" class="btn-outline px-4 py-2 text-sm">التفاصيل</a>
                    <button data-compare-id="${pkg.id}" onclick="toggleCompare('${pkg.id}','${pkg.title.replace(/'/g,"\\'")}' )" class="bg-gray-100 text-gray-600 hover:bg-primary hover:text-white px-3 py-2 rounded-lg text-sm transition flex items-center gap-1">
                      <i class="fa-solid fa-code-compare"></i> قارن
                    </button>
                </div>
            </div>
        </div>
        `;
    }).join('');
}

// Event Listeners
document.addEventListener('DOMContentLoaded', async () => {
    await loadPackages();

    // If user came from a package-detail "compare" link, preselect that package
    const params = new URLSearchParams(location.search);
    const preselectId = params.get('preselect');
    if (preselectId) {
        compareList = [preselectId];
        updateCompareBanner();
        document.querySelectorAll('[data-compare-id]').forEach(btn => {
            if (btn.dataset.compareId === preselectId) {
                btn.classList.add('bg-primary', 'text-white');
                btn.classList.remove('bg-gray-100', 'text-gray-600');
                btn.innerHTML = '<i class="fa-solid fa-check"></i> تمت الإضافة';
            }
        });
    }

    document.querySelectorAll('.filter-cat').forEach(chk => {
        chk.addEventListener('change', applyFilters);
    });
    document.getElementById('filterSeason').addEventListener('change', applyFilters);
    document.getElementById('sortOptions').addEventListener('change', applyFilters);

    document.getElementById('resetFilters').addEventListener('click', () => {
        document.querySelectorAll('.filter-cat').forEach(chk => chk.checked = false);
        document.querySelectorAll('.filter-dur').forEach(chk => chk.checked = false);
        document.getElementById('filterSeason').value = '';
        document.getElementById('sortOptions').value = 'newest';
        const priceEl = document.getElementById('filterPriceMax');
        if (priceEl) { priceEl.value = 30000; updatePriceLabel(30000); }
        applyFilters();
    });
    document.querySelectorAll('.filter-dur').forEach(chk => chk.addEventListener('change', applyFilters));
});
