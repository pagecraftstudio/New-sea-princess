/**
 * reviews.js
 * Handles fetching approved reviews and submitting new ones.
 */

async function loadReviews() {
    if (!window.db) return;
    try {
        const { data, error } = await window.db
            .from('reviews')
            .select('*')
            .eq('is_approved', true)
            .order('created_at', { ascending: false });

        if (error) throw error;
        renderReviews(data);
    } catch (err) {
        console.error("Error loading reviews:", err);
        document.getElementById('reviewsGrid').innerHTML = `<p class="col-span-full text-center text-error border p-4 rounded">حدث خطأ أثناء تحميل الآراء.</p>`;
    }
}

function renderReviews(reviews) {
    const container = document.getElementById('reviewsGrid');
    if (reviews.length === 0) {
        container.innerHTML = '<p class="col-span-full text-center text-gray-500 py-8">لا توجد تقييمات معتمدة حتى الآن.</p>';
        return;
    }

    container.innerHTML = reviews.map(rev => {
        const starsHtml = '<i class="fa-solid fa-star"></i>'.repeat(rev.rating) + '<i class="fa-regular fa-star"></i>'.repeat(5 - rev.rating);
        return `
        <div class="bg-white p-6 rounded-xl shadow-sm border border-gray-100 flex flex-col relative overflow-hidden">
            <i class="fa-solid fa-quote-left absolute top-4 left-4 text-5xl text-gray-100"></i>
            <div class="text-gold text-lg mb-3 relative z-10">${starsHtml}</div>
            <p class="text-gray-700 mb-6 flex-1 leading-relaxed relative z-10">"${rev.review_text}"</p>
            
            <div class="border-t border-gray-100 pt-4 mt-auto">
                <p class="font-bold text-primary">${rev.customer_name}</p>
                <div class="flex justify-between items-center text-xs text-gray-500 mt-1">
                    <span><i class="fa-solid fa-location-dot ml-1"></i> ${rev.customer_city || 'غير محدد'}</span>
                    <span><i class="fa-solid fa-calendar ml-1"></i> ${rev.travel_year || ''} - ${rev.package_title || ''}</span>
                </div>
            </div>
        </div>
        `;
    }).join('');
}

function toggleReviewForm() {
    const form = document.getElementById('reviewFormArea');
    form.classList.toggle('hidden');
}

async function submitReview() {
    if (!window.db) return;
    const name = document.getElementById('revName').value;
    const text = document.getElementById('revText').value;
    
    if(!name || !text) {
        alert("يرجى إدخال الاسم وتفاصيل التجربة.");
        return;
    }

    const btn = document.getElementById('revSubmitBtn');
    btn.disabled = true;
    btn.innerHTML = 'جاري الإرسال...';

    const payload = {
        customer_name: name,
        customer_city: document.getElementById('revCity').value,
        customer_phone: document.getElementById('revPhone')?.value.trim() || null,
        package_title: document.getElementById('revPackage').value,
        travel_year: parseInt(document.getElementById('revYear').value) || null,
        rating: parseInt(document.getElementById('revRating').value),
        review_text: text,
        is_approved: false // Requires admin approval
    };

    try {
        const { error } = await window.db.from('reviews').insert(payload);
        if(error) throw error;
        
        document.getElementById('revSuccess').classList.remove('hidden');
        setTimeout(() => {
            toggleReviewForm();
            // clean form
            document.getElementById('revName').value = '';
            document.getElementById('revText').value = '';
            const phoneEl = document.getElementById('revPhone');
            if (phoneEl) phoneEl.value = '';
            document.getElementById('revSuccess').classList.add('hidden');
            btn.innerHTML = 'إرسال التقييم';
            btn.disabled = false;
        }, 3000);

    } catch(err) {
        console.error(err);
        alert("حدث خطأ. حاول مرة أخرى.");
        btn.innerHTML = 'إرسال التقييم';
        btn.disabled = false;
    }
}

document.addEventListener('DOMContentLoaded', async () => { await loadReviews(); });
