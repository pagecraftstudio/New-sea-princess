/**
 * print-utils.js — New Sea Princess Tourism
 * Redesigned professional print templates v2
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

const LOGO_URL = '/assets/logo-white.png';

function _openPrint(html) {
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url; a.target = '_blank'; a.rel = 'noopener';
  document.body.appendChild(a); a.click();
  setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(url); }, 1500);
}

const _AP = '<scr'+'ipt>window.onload=()=>{document.getElementById("printBtn").style.display="none";window.print();document.getElementById("printBtn").style.display="";};</'+'script>';

const _FONTS = '<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@300;400;600;700;900&display=swap" rel="stylesheet">';

const _STATUS = {
  awaiting_payment:'في انتظار الدفع', pending:'قيد التلقي', confirmed:'مؤكد',
  visa_processing:'جاري التأشيرة', tickets_issued:'تذاكر صادرة',
  travelling:'في السفر', completed:'مكتمل', cancelled:'ملغي'
};
const _SCOLOR = {
  awaiting_payment:'#ea580c', pending:'#ca8a04', confirmed:'#16a34a',
  visa_processing:'#2563eb', tickets_issued:'#4f46e5',
  travelling:'#0d9488', completed:'#7c3aed', cancelled:'#dc2626'
};

// ══════════════════════════════════════════════════════════
//  SHARED HEADER COMPONENT
// ══════════════════════════════════════════════════════════
function _header(docType, subtitle) {
  return `
  <div class="doc-header">
    <div class="header-left">
      <img src="${LOGO_URL}" alt="نيو سي برنسيس" class="header-logo" onerror="this.style.display='none'">
    </div>
    <div class="header-center">
      <div class="company-name">نيو سي برنسيس لسياحة</div>
      <div class="company-sub">إشراف د. شيماء السعداوي ود. محمد دحروج | شركة سياحة (أ) ترخيص رقم 926</div>
      <div class="doc-type">${docType}</div>
    </div>
    <div class="header-right">
      <div class="contact-line"><i>📞</i> 01555154996</div>
      <div class="contact-line"><i>📞</i> 01031777295</div>
      <div class="contact-line"><i>📞</i> 01093475254</div>
    </div>
  </div>
  ${subtitle ? `<div class="doc-subtitle">${subtitle}</div>` : ''}`;
}

// ══════════════════════════════════════════════════════════
//  SHARED FOOTER COMPONENT
// ══════════════════════════════════════════════════════════
function _footer() {
  return `
  <div class="doc-footer">
    <div class="footer-seal">
      <div class="seal-circle">ختم الشركة</div>
      <div class="seal-label">الختم الرسمي</div>
    </div>
    <div class="footer-center">
      نيو سي برنسيس لسياحة &nbsp;•&nbsp; 01555154996 &nbsp;•&nbsp; 01031777295 &nbsp;•&nbsp; 01093475254<br>
      <span style="color:#B8860B">شكراً لاختياركم. تقبل الله طاعتكم وجعل رحلتكم مباركة 🤲</span>
    </div>
    <div class="footer-sign">
      <div class="sign-line"></div>
      <div class="sign-name">د. شيماء السعداوي</div>
      <div class="sign-title">المشرف العام — التوقيع</div>
    </div>
    <div class="footer-sign">
      <div class="sign-line"></div>
      <div class="sign-name">د. محمد دحروج</div>
      <div class="sign-title">المشرف العام — التوقيع</div>
    </div>
  </div>`;
}

// ══════════════════════════════════════════════════════════
//  BASE CSS (shared across all documents)
// ══════════════════════════════════════════════════════════
const _BASE_CSS = `
  *, *::before, *::after {
    margin: 0; padding: 0; box-sizing: border-box;
    -webkit-print-color-adjust: exact !important;
    print-color-adjust: exact !important;
  }
  body {
    font-family: 'Cairo', sans-serif;
    font-size: 13px;
    color: #1a1a1a;
    background: #f1f5f9;
    direction: rtl;
  }
  .page-wrap {
    background: #fff;
    max-width: 900px;
    margin: 20px auto;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 8px 40px rgba(0,0,0,.12);
  }

  /* ── Header ── */
  .doc-header {
    background: linear-gradient(135deg, #1B5E20 0%, #2E7D32 60%, #1a5e1a 100%);
    padding: 24px 28px;
    display: grid;
    grid-template-columns: 100px 1fr 130px;
    gap: 16px;
    align-items: center;
  }
  .header-logo { width: 90px; height: 90px; object-fit: contain; border-radius: 8px; background: rgba(255,255,255,.1); padding: 6px; }
  .header-center { text-align: center; }
  .company-name { font-size: 22px; font-weight: 900; color: #fff; letter-spacing: .5px; }
  .company-sub  { font-size: 10px; color: rgba(255,255,255,.75); margin-top: 3px; }
  .doc-type     { display: inline-block; margin-top: 8px; background: rgba(184,134,11,.3); border: 1px solid rgba(184,134,11,.6); color: #FFD700; padding: 4px 20px; border-radius: 20px; font-size: 13px; font-weight: 700; letter-spacing: 1px; }
  .header-right { text-align: left; }
  .contact-line { font-size: 11px; color: rgba(255,255,255,.8); margin-bottom: 4px; }
  .doc-subtitle {
    background: #f0fdf4; border-bottom: 2px solid #B8860B;
    padding: 10px 24px; font-size: 12px; color: #374151;
    display: flex; justify-content: space-between; align-items: center;
  }

  /* ── Section ── */
  .section { padding: 18px 24px 0; }
  .section-title {
    font-size: 13px; font-weight: 700; color: #1B5E20;
    border-right: 4px solid #B8860B; padding-right: 10px;
    margin-bottom: 12px; display: flex; align-items: center; gap: 6px;
  }
  .section-title i { color: #B8860B; }

  /* ── Grid info ── */
  .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .info-grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; }
  .info-box {
    background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 10px 14px;
  }
  .info-box label { font-size: 10px; color: #94a3b8; display: block; margin-bottom: 2px; font-weight: 600; }
  .info-box p     { font-size: 13px; font-weight: 700; color: #1e293b; }
  .info-box.highlight { background: #f0fdf4; border-color: #bbf7d0; }
  .info-box.highlight p { color: #15803d; }

  /* ── Table ── */
  .data-table { width: 100%; border-collapse: collapse; margin-top: 6px; font-size: 12px; }
  .data-table thead tr { background: #1B5E20; }
  .data-table thead th { color: #fff; padding: 9px 12px; text-align: right; font-weight: 700; font-size: 11px; }
  .data-table tbody td { padding: 9px 12px; border-bottom: 1px solid #f1f5f9; vertical-align: middle; }
  .data-table tbody tr:nth-child(even) td { background: #f8fafc; }
  .data-table tfoot td { padding: 9px 12px; font-weight: 700; background: #f0fdf4; border-top: 2px solid #1B5E20; }

  /* ── Payment summary ── */
  .pay-row { display: flex; justify-content: space-between; align-items: center; padding: 9px 14px; border-bottom: 1px solid #f1f5f9; font-size: 13px; }
  .pay-row:last-child { border-bottom: none; }
  .pay-row.total   { background: #f0fdf4; font-weight: 700; font-size: 14px; }
  .pay-row.paid    { background: #eff6ff; }
  .pay-row.remain  { border: 2px solid; border-radius: 8px; margin: 8px 0; font-weight: 900; font-size: 15px; padding: 12px 14px; }
  .pay-box { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 10px; overflow: hidden; margin-top: 6px; }

  /* ── Status badge ── */
  .status-badge {
    display: inline-block; padding: 3px 12px; border-radius: 20px;
    font-size: 11px; font-weight: 700; border: 1px solid;
  }

  /* ── Divider ── */
  .divider { height: 1px; background: linear-gradient(90deg, transparent, #e2e8f0, transparent); margin: 16px 24px; }

  /* ── KPI cards ── */
  .kpi-grid { display: grid; grid-template-columns: repeat(5,1fr); gap: 10px; padding: 0 24px 16px; }
  .kpi-card { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px; text-align: center; }
  .kpi-card .kpi-val { font-size: 18px; font-weight: 900; }
  .kpi-card .kpi-lbl { font-size: 10px; color: #94a3b8; margin-top: 2px; }

  /* ── Group block ── */
  .group-block { margin: 0 24px 24px; border: 1px solid #e2e8f0; border-radius: 10px; overflow: hidden; page-break-inside: avoid; }
  .group-header { background: linear-gradient(135deg,#1B5E20,#2E7D32); color:#fff; padding: 12px 16px; display: flex; justify-content: space-between; align-items: center; }
  .group-header-title { font-size: 15px; font-weight: 700; }
  .group-header-sub   { font-size: 11px; opacity: .8; margin-top: 2px; }
  .group-header-stats { text-align: left; font-size: 11px; }

  /* ── Footer ── */
  .doc-footer {
    background: #f8fafc; border-top: 2px solid #e2e8f0;
    padding: 20px 24px; margin-top: 24px;
    display: grid; grid-template-columns: 100px 1fr 120px 120px; gap: 14px; align-items: center;
  }
  .seal-circle { width: 80px; height: 80px; border: 2px dashed #cbd5e1; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 10px; color: #cbd5e1; font-weight: 700; margin: 0 auto; }
  .seal-label  { font-size: 10px; color: #94a3b8; text-align: center; margin-top: 6px; }
  .footer-center { text-align: center; font-size: 11px; color: #64748b; line-height: 1.7; }
  .sign-line  { border-bottom: 1.5px solid #1B5E20; width: 110px; height: 50px; margin: 0 auto; }
  .sign-name  { font-size: 11px; font-weight: 700; color: #1B5E20; text-align: center; margin-top: 6px; }
  .sign-title { font-size: 9px; color: #94a3b8; text-align: center; }

  @media print {
    .doc-footer { grid-template-columns: 100px 1fr 120px 120px; }
  }

  /* ── Print button ── */
  #printBtn {
    display: block; width: calc(100% - 40px); margin: 16px 20px 0;
    padding: 12px; background: #1B5E20; color: #fff;
    font-family: 'Cairo',sans-serif; font-size: 15px; font-weight: 700;
    border: none; border-radius: 8px; cursor: pointer;
  }
  #printBtn:hover { background: #2E7D32; }

  @media print {
    body { background: #fff; }
    .page-wrap { box-shadow: none; margin: 0; border-radius: 0; }
    #printBtn { display: none !important; }
  }
`;

// ══════════════════════════════════════════════════════════
//  1. INVOICE
// ══════════════════════════════════════════════════════════
function printInvoice(b) {
  const paid      = Number(b.paid_amount  || 0);
  const total     = Number(b.total_price  || 0);
  const remaining = Number(b.remaining_amount ?? (total - paid));
  const isPaid    = remaining <= 0;
  const paidColor = isPaid ? '#16a34a' : '#dc2626';
  const statusCol = _SCOLOR[b.status] || '#6b7280';
  const statusLbl = _STATUS[b.status] || b.status;
  const fmtDate   = d => d ? new Date(d).toLocaleDateString('ar-EG') : '—';
  const fmt       = n => Number(n||0).toLocaleString('ar-EG');

  const travRows = (b.travelers||[]).map((t,i) =>
    `<tr>
      <td style="text-align:center">${i+1}</td>
      <td><strong>${t.name||'—'}</strong></td>
      <td style="text-align:center">${t.type==='child'?'طفل':'بالغ'}</td>
      <td dir="ltr" style="text-align:center">${t.passport||'—'}</td>
      <td style="text-align:center">${t.national_id||'—'}</td>
    </tr>`
  ).join('');

  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8">
<title>فاتورة حجز — ${b.booking_number||''}</title>
${_FONTS}
<style>${_BASE_CSS}</style>
</head><body>
<button id="printBtn" onclick="window.print()">🖨️ طباعة / حفظ كـ PDF</button>
<div class="page-wrap">

  ${_header('فـاتـورة حـجـز', `
    <span>رقم الفاتورة: <strong style="color:#1B5E20">${b.booking_number||'—'}</strong></span>
    <span>تاريخ الحجز: <strong>${fmtDate(b.booking_date)}</strong></span>
    <span>تاريخ الطباعة: <strong>${fmtDate(new Date())}</strong></span>
    <span class="status-badge" style="color:${statusCol};border-color:${statusCol};background:${statusCol}18">${statusLbl}</span>
  `)}

  <!-- Payment Status Banner -->
  <div style="margin:0;padding:14px 24px;background:${isPaid?'#f0fdf4':'#fff1f2'};border-bottom:2px solid ${isPaid?'#bbf7d0':'#fecdd3'};display:flex;align-items:center;justify-content:space-between;">
    <div style="display:flex;align-items:center;gap:10px;">
      <div style="width:44px;height:44px;border-radius:50%;background:${isPaid?'#16a34a':'#dc2626'};display:flex;align-items:center;justify-content:center;font-size:20px;color:#fff;flex-shrink:0">
        ${isPaid ? '✓' : '!'}
      </div>
      <div>
        <div style="font-size:16px;font-weight:900;color:${paidColor}">${isPaid?'تم الدفع بالكامل':'يوجد رصيد مستحق'}</div>
        <div style="font-size:11px;color:#64748b;margin-top:1px">${isPaid?'تم سداد كامل المبلغ المطلوب':'يرجى سداد المبلغ المتبقي في أقرب وقت'}</div>
      </div>
    </div>
    <div style="text-align:left">
      <div style="font-size:24px;font-weight:900;color:${paidColor}">${fmt(remaining)} ج.م</div>
      <div style="font-size:10px;color:#94a3b8;text-align:center">المتبقي</div>
    </div>
  </div>

  <!-- Customer + Trip Info -->
  <div class="section">
    <div class="info-grid" style="margin-top:4px">
      <div>
        <div class="section-title"><i>👤</i> بيانات العميل</div>
        <div class="info-grid">
          <div class="info-box"><label>الاسم الكامل</label><p>${b.customer_name||'—'}</p></div>
          <div class="info-box"><label>رقم الهاتف</label><p dir="ltr">${b.customer_phone||'—'}</p></div>
          ${b.customer_email?`<div class="info-box"><label>البريد</label><p dir="ltr" style="font-size:11px">${b.customer_email}</p></div>`:''}
          ${b.customer_national_id?`<div class="info-box"><label>الرقم القومي</label><p>${b.customer_national_id}</p></div>`:''}
        </div>
      </div>
      <div>
        <div class="section-title"><i>✈️</i> بيانات الرحلة</div>
        <div class="info-grid">
          <div class="info-box highlight" style="grid-column:span 2"><label>اسم البرنامج</label><p>${b.package_title||'—'}</p></div>
          <div class="info-box"><label>تاريخ المغادرة</label><p>${fmtDate(b.package_departure)}</p></div>
          <div class="info-box"><label>الأفراد</label><p>${b.adults_count||0} بالغ / ${b.children_count||0} طفل</p></div>
        </div>
      </div>
    </div>
  </div>

  <div class="divider"></div>

  <!-- Payment Summary -->
  <div class="section">
    <div class="section-title"><i>💰</i> ملخص المدفوعات</div>
    <div class="pay-box">
      <div class="pay-row total">
        <span>إجمالي قيمة البرنامج</span>
        <strong style="font-size:15px;color:#1B5E20">${fmt(total)} ج.م</strong>
      </div>
      <div class="pay-row paid">
        <span>المبلغ المدفوع</span>
        <strong style="color:#2563eb">${fmt(paid)} ج.م</strong>
      </div>
      ${Number(b.discount_amount)>0?`<div class="pay-row"><span>الخصم المطبّق ${b.coupon_code?'('+b.coupon_code+')':''}</span><strong style="color:#7c3aed">- ${fmt(b.discount_amount)} ج.م</strong></div>`:''}
      <div class="pay-row remain" style="color:${paidColor};border-color:${paidColor};background:${isPaid?'#f0fdf4':'#fff1f2'}">
        <span>${isPaid?'✅ تم السداد بالكامل':'⚠️ الرصيد المتبقي'}</span>
        <strong>${fmt(remaining)} ج.م</strong>
      </div>
    </div>

    <!-- Exchange Rate Note -->
    <div style="margin-top:10px;background:#f8f9fa;border:1px solid #e5e7eb;border-radius:8px;padding:11px 14px;font-size:11px;color:#374151;">
      <div style="font-weight:700;color:#1B5E20;margin-bottom:7px;display:flex;align-items:center;gap:6px;">
        <span style="font-size:13px;">💱</span> التوضيح بالريال السعودي
        <span style="font-weight:400;color:#9ca3af;font-size:10px;">(سعر الصرف التقريبي: 1 ج.م ≈ 0.074 ر.س)</span>
      </div>
      <table style="width:100%;border-collapse:collapse;">
        <thead>
          <tr style="background:#f0fdf4;font-size:10px;color:#6b7280;">
            <th style="padding:5px 8px;text-align:right;border:1px solid #e5e7eb;font-weight:700;">البيان</th>
            <th style="padding:5px 8px;text-align:center;border:1px solid #e5e7eb;font-weight:700;">المبلغ بالجنيه المصري</th>
            <th style="padding:5px 8px;text-align:center;border:1px solid #e5e7eb;font-weight:700;">ما يعادله بالريال السعودي</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;">إجمالي قيمة البرنامج</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;">${fmt(total)} ج.م</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;color:#1B5E20;">${(total*0.074).toLocaleString('ar-EG',{maximumFractionDigits:1})} ر.س</td>
          </tr>
          <tr style="background:#f9fafb;">
            <td style="padding:5px 8px;border:1px solid #e5e7eb;">المبلغ المدفوع</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;">${fmt(paid)} ج.م</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;color:#2563eb;">${(paid*0.074).toLocaleString('ar-EG',{maximumFractionDigits:1})} ر.س</td>
          </tr>
          ${remaining>0?`<tr>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;">الرصيد المتبقي</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;">${fmt(remaining)} ج.م</td>
            <td style="padding:5px 8px;border:1px solid #e5e7eb;text-align:center;font-weight:600;color:#dc2626;">${(remaining*0.074).toLocaleString('ar-EG',{maximumFractionDigits:1})} ر.س</td>
          </tr>`:''}
        </tbody>
      </table>
      <p style="margin-top:6px;font-size:10px;color:#9ca3af;">* سعر الصرف تقريبي وقابل للتغيير — يُرجى التحقق من البنك أو شركة الصرافة عند الحاجة.</p>
    </div>
  </div>

  <!-- Travelers -->
  ${travRows ? `
  <div class="divider"></div>
  <div class="section">
    <div class="section-title"><i>👥</i> بيانات المسافرين</div>
    <table class="data-table">
      <thead><tr><th style="text-align:center">#</th><th>الاسم الكامل</th><th style="text-align:center">النوع</th><th style="text-align:center">رقم الجواز</th><th style="text-align:center">الرقم القومي</th></tr></thead>
      <tbody>${travRows}</tbody>
    </table>
  </div>` : ''}

  ${b.special_requests?`
  <div class="divider"></div>
  <div class="section">
    <div class="section-title"><i>📝</i> طلبات خاصة</div>
    <div style="background:#fffbeb;border:1px solid #fde68a;border-radius:8px;padding:12px;font-size:12px;color:#92400e">${b.special_requests}</div>
  </div>`:''}

  ${b.status==='cancelled'&&b.status_details?`
  <div class="divider"></div>
  <div class="section">
    <div class="section-title" style="color:#dc2626;border-color:#dc2626"><i>🚫</i> سبب الإلغاء</div>
    <div style="background:#fff1f2;border:1px solid #fecdd3;border-radius:8px;padding:12px;font-size:12px;color:#dc2626">${b.status_details}</div>
  </div>`:''}

  <div style="padding:0 24px">
  ${_footer()}
  </div>
</div>
${_AP}</body></html>`;

  _openPrint(html);
}

// ══════════════════════════════════════════════════════════
//  2. TRIP SHEET
// ══════════════════════════════════════════════════════════
async function printTripSheet(b) {
  let pkg = null;
  if (b.package_id && window.db) {
    const { data } = await window.db.from('packages').select('*').eq('id', b.package_id).single();
    pkg = data;
  }

  const fmtDate = d => d ? new Date(d).toLocaleDateString('ar-EG', {weekday:'long',year:'numeric',month:'long',day:'numeric'}) : '—';
  const stars   = n => '★'.repeat(n||0) + '☆'.repeat(5-(n||0));
  const statusCol = _SCOLOR[b.status] || '#6b7280';
  const statusLbl = _STATUS[b.status] || b.status;

  const travRows = (b.travelers||[]).map((t,i) =>
    `<tr>
      <td style="text-align:center">${i+1}</td>
      <td><strong>${t.name||'—'}</strong></td>
      <td style="text-align:center">${t.type==='child'?'طفل':'بالغ'}</td>
      <td dir="ltr" style="text-align:center">${t.passport||'—'}</td>
      <td dir="ltr" style="text-align:center">${t.passport_expiry||'—'}</td>
    </tr>`
  ).join('');

  const itinerary = pkg?.itinerary || [];
  const itinHtml = itinerary.length
    ? itinerary.map(day => `
        <div style="display:flex;gap:14px;margin-bottom:14px;align-items:flex-start;page-break-inside:avoid">
          <div style="min-width:40px;height:40px;background:#1B5E20;color:#fff;border-radius:50%;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:15px;flex-shrink:0;box-shadow:0 2px 8px rgba(27,94,32,.3)">${day.day}</div>
          <div style="flex:1;background:#f8fafc;border:1px solid #e2e8f0;border-right:3px solid #B8860B;border-radius:0 8px 8px 0;padding:10px 14px">
            <div style="font-weight:700;color:#1B5E20;font-size:13px;margin-bottom:4px">${day.title||''}</div>
            <div style="font-size:12px;color:#475569;line-height:1.6">${day.description||''}</div>
          </div>
        </div>`).join('')
    : '<p style="color:#94a3b8;font-size:12px;font-style:italic;padding:8px 0">لا يوجد جدول يومي مضاف لهذا البرنامج</p>';

  const includes = (pkg?.includes||[]).map(i=>`<div style="display:flex;align-items:center;gap:6px;padding:5px 0;border-bottom:1px dashed #e2e8f0;font-size:12px"><span style="color:#16a34a;font-size:14px">✓</span>${i}</div>`).join('') || '<p style="color:#94a3b8;font-size:12px">—</p>';
  const excludes = (pkg?.excludes||[]).map(i=>`<div style="display:flex;align-items:center;gap:6px;padding:5px 0;border-bottom:1px dashed #e2e8f0;font-size:12px"><span style="color:#dc2626;font-size:14px">✗</span>${i}</div>`).join('') || '<p style="color:#94a3b8;font-size:12px">—</p>';

  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8">
<title>تفاصيل الرحلة — ${b.booking_number||''}</title>
${_FONTS}
<style>${_BASE_CSS}
.hotel-card{background:#f0fdf4;border:1px solid #bbf7d0;border-radius:10px;padding:14px 16px;}
.hotel-name{font-size:16px;font-weight:700;color:#15803d;margin-bottom:4px}
.hotel-stars{color:#f59e0b;font-size:16px;letter-spacing:2px}
.hotel-detail{font-size:11px;color:#64748b;margin-top:6px}
</style>
</head><body>
<button id="printBtn" onclick="window.print()">🖨️ طباعة / حفظ كـ PDF</button>
<div class="page-wrap">

  ${_header('تفاصيـل الرحلـة', `
    <span>رقم الحجز: <strong style="color:#1B5E20;font-family:monospace">${b.booking_number||'—'}</strong></span>
    <span>تاريخ الطباعة: <strong>${new Date().toLocaleDateString('ar-EG')}</strong></span>
    <span class="status-badge" style="color:${statusCol};border-color:${statusCol};background:${statusCol}18">${statusLbl}</span>
  `)}

  <!-- Quick Info -->
  <div class="section">
    <div class="info-grid-3" style="margin-top:4px">
      <div class="info-box highlight" style="grid-column:span 2"><label>اسم البرنامج</label><p style="font-size:15px">${b.package_title||'—'}</p></div>
      <div class="info-box"><label>الحالة</label><p><span class="status-badge" style="color:${statusCol};border-color:${statusCol};background:${statusCol}18">${statusLbl}</span></p></div>
      <div class="info-box"><label>العميل</label><p>${b.customer_name||'—'}</p></div>
      <div class="info-box"><label>الهاتف</label><p dir="ltr">${b.customer_phone||'—'}</p></div>
      <div class="info-box"><label>عدد الأفراد</label><p>${b.adults_count||0} بالغ / ${b.children_count||0} طفل</p></div>
      <div class="info-box"><label>تاريخ المغادرة</label><p>${fmtDate(b.package_departure)}</p></div>
      <div class="info-box"><label>تاريخ العودة</label><p>${fmtDate(pkg?.return_date)}</p></div>
      <div class="info-box"><label>مدة الإقامة</label><p>${pkg?.duration_nights||'—'} ليلة</p></div>
      <div class="info-box"><label>مدينة الانطلاق</label><p>${pkg?.departure_city||'—'}</p></div>
      <div class="info-box"><label>الطيران</label><p>${pkg?.airline||pkg?.flight_type||'—'}</p></div>
      <div class="info-box"><label>نوع الرحلة</label><p>${pkg?.transport_type||'—'}</p></div>
    </div>
  </div>

  <div class="divider"></div>

  <!-- Hotels -->
  <div class="section">
    <div class="section-title"><i>🏨</i> تفاصيل الإقامة</div>
    <div class="info-grid">
      <div class="hotel-card">
        <div style="font-size:10px;color:#64748b;font-weight:700;margin-bottom:6px;text-transform:uppercase;letter-spacing:1px">🕋 مكة المكرمة</div>
        <div class="hotel-name">${pkg?.mecca_hotel||'—'}</div>
        <div class="hotel-stars">${stars(pkg?.mecca_hotel_stars)}</div>
        <div class="hotel-detail">عدد الليالي: <strong>${pkg?.nights_mecca||'—'}</strong>${pkg?.mecca_hotel_distance?` &nbsp;|&nbsp; المسافة من الحرم: <strong>${pkg.mecca_hotel_distance}</strong>`:''}</div>
      </div>
      <div class="hotel-card">
        <div style="font-size:10px;color:#64748b;font-weight:700;margin-bottom:6px;text-transform:uppercase;letter-spacing:1px">🕌 المدينة المنورة</div>
        <div class="hotel-name">${pkg?.medina_hotel||'—'}</div>
        <div class="hotel-stars">${stars(pkg?.medina_hotel_stars)}</div>
        <div class="hotel-detail">عدد الليالي: <strong>${pkg?.nights_medina||'—'}</strong>${pkg?.medina_hotel_distance?` &nbsp;|&nbsp; المسافة من الحرم: <strong>${pkg.medina_hotel_distance}</strong>`:''}</div>
      </div>
    </div>
  </div>

  ${travRows?`
  <div class="divider"></div>
  <div class="section">
    <div class="section-title"><i>👥</i> المسافرون</div>
    <table class="data-table">
      <thead><tr><th style="text-align:center">#</th><th>الاسم</th><th style="text-align:center">النوع</th><th style="text-align:center">رقم الجواز</th><th style="text-align:center">تاريخ انتهاء الجواز</th></tr></thead>
      <tbody>${travRows}</tbody>
    </table>
  </div>`:''}

  <div class="divider"></div>

  <!-- Includes / Excludes -->
  <div class="section">
    <div class="info-grid">
      <div>
        <div class="section-title"><i>✅</i> يشمل البرنامج</div>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:10px 14px">${includes}</div>
      </div>
      <div>
        <div class="section-title"><i>❌</i> لا يشمل البرنامج</div>
        <div style="background:#fff1f2;border:1px solid #fecdd3;border-radius:8px;padding:10px 14px">${excludes}</div>
      </div>
    </div>
  </div>

  <div class="divider"></div>

  <!-- Itinerary -->
  <div class="section">
    <div class="section-title"><i>📅</i> الجدول اليومي للرحلة</div>
    ${itinHtml}
  </div>

  ${b.special_requests?`
  <div class="divider"></div>
  <div class="section">
    <div class="section-title"><i>📝</i> طلبات خاصة</div>
    <div style="background:#fffbeb;border:1px solid #fde68a;border-radius:8px;padding:12px;font-size:12px;color:#92400e">${b.special_requests}</div>
  </div>`:''}

  <div style="padding:0 24px">
  ${_footer()}
  </div>
</div>
${_AP}</body></html>`;

  _openPrint(html);
}

// ══════════════════════════════════════════════════════════
//  3. GROUPED REPORT
// ══════════════════════════════════════════════════════════
function exportGroupedReport() {
  const data = (window.filteredBookings?.length) ? window.filteredBookings : (window.allBookings||[]);
  if (!data.length) { alert('لا توجد حجوزات لتصديرها'); return; }

  const groups = {};
  data.forEach(b => {
    const k = b.package_title || 'بدون برنامج';
    if (!groups[k]) groups[k] = [];
    groups[k].push(b);
  });

  const sum = (arr, fn) => arr.reduce((s,b) => s+(fn(b)||0), 0);
  const fmt = n => Number(n||0).toLocaleString('ar-EG');
  const fmtDate = d => d ? new Date(d).toLocaleDateString('ar-EG') : '—';

  const totalRev    = sum(data.filter(b=>b.status!=='cancelled'), b=>Number(b.total_price));
  const totalPaid   = sum(data, b=>Number(b.paid_amount));
  const totalRemain = sum(data, b=>Number(b.remaining_amount||(b.total_price-b.paid_amount)));
  const totalPax    = sum(data, b=>Number(b.adults_count||0)+Number(b.children_count||0));

  const kpiCards = [
    { lbl:'إجمالي الحجوزات',  val:data.length,            col:'#1B5E20', bg:'#f0fdf4', br:'#bbf7d0' },
    { lbl:'إجمالي المسافرين', val:totalPax,                col:'#0d9488', bg:'#f0fdfa', br:'#99f6e4' },
    { lbl:'إجمالي الإيرادات', val:fmt(totalRev)+' ج.م',   col:'#15803d', bg:'#f0fdf4', br:'#bbf7d0' },
    { lbl:'المحصّل',          val:fmt(totalPaid)+' ج.م',  col:'#2563eb', bg:'#eff6ff', br:'#bfdbfe' },
    { lbl:'المتبقي',          val:fmt(totalRemain)+' ج.م',col:'#dc2626', bg:'#fff1f2', br:'#fecdd3' },
  ].map(k =>
    `<div class="kpi-card" style="background:${k.bg};border-color:${k.br}">
      <div class="kpi-val" style="color:${k.col}">${k.val}</div>
      <div class="kpi-lbl">${k.lbl}</div>
    </div>`
  ).join('');

  const groupsHtml = Object.entries(groups).map(([pkgTitle, bks]) => {
    const pkgRev    = sum(bks.filter(b=>b.status!=='cancelled'), b=>Number(b.total_price));
    const pkgPaid   = sum(bks, b=>Number(b.paid_amount));
    const pkgRemain = sum(bks, b=>Number(b.remaining_amount||(b.total_price-b.paid_amount)));
    const pkgPax    = sum(bks, b=>Number(b.adults_count||0)+Number(b.children_count||0));
    const dep       = bks[0]?.package_departure ? fmtDate(bks[0].package_departure) : '—';

    const rows = bks.map((b,i) => {
      const ttl = Number(b.total_price||0);
      const pd  = Number(b.paid_amount||0);
      const rem = Number(b.remaining_amount??(ttl-pd));
      const col = _SCOLOR[b.status]||'#6b7280';
      const lbl = _STATUS[b.status]||b.status;
      return `<tr>
        <td style="text-align:center;color:#94a3b8;font-size:11px">${i+1}</td>
        <td><strong style="color:#1B5E20;font-family:monospace;font-size:11px">${b.booking_number||'—'}</strong></td>
        <td>
          <div style="font-weight:700;font-size:12px">${b.customer_name||'—'}</div>
          <div style="font-size:10px;color:#94a3b8" dir="ltr">${b.customer_phone||''}</div>
        </td>
        <td style="text-align:center;font-size:11px">${Number(b.adults_count||0)}ب / ${Number(b.children_count||0)}ط</td>
        <td style="text-align:left;font-weight:700;color:#15803d">${fmt(ttl)} ج.م</td>
        <td style="text-align:left;color:#2563eb;font-weight:600">${fmt(pd)} ج.م</td>
        <td style="text-align:left;font-weight:700;color:${rem>0?'#dc2626':'#16a34a'}">${fmt(rem)} ج.م</td>
        <td style="text-align:center">
          <span class="status-badge" style="color:${col};border-color:${col};background:${col}18;font-size:10px">${lbl}</span>
        </td>
      </tr>`;
    }).join('');

    return `<div class="group-block">
      <div class="group-header">
        <div>
          <div class="group-header-title">${pkgTitle}</div>
          <div class="group-header-sub">المغادرة: ${dep} &nbsp;|&nbsp; ${bks.length} حجز &nbsp;|&nbsp; ${pkgPax} مسافر</div>
        </div>
        <div class="group-header-stats">
          <div>الإجمالي: <strong>${fmt(pkgRev)} ج.م</strong></div>
          <div style="color:#86efac">المدفوع: ${fmt(pkgPaid)} ج.م</div>
          <div style="color:#fca5a5">المتبقي: ${fmt(pkgRemain)} ج.م</div>
        </div>
      </div>
      <table class="data-table">
        <thead><tr>
          <th style="text-align:center">#</th>
          <th>رقم الحجز</th>
          <th>العميل</th>
          <th style="text-align:center">الأفراد</th>
          <th style="text-align:left">الإجمالي</th>
          <th style="text-align:left">المدفوع</th>
          <th style="text-align:left">المتبقي</th>
          <th style="text-align:center">الحالة</th>
        </tr></thead>
        <tbody>${rows}</tbody>
        <tfoot><tr>
          <td colspan="4" style="color:#1B5E20">إجمالي البرنامج (${bks.filter(b=>b.status!=='cancelled').length} حجز فعّال)</td>
          <td style="text-align:left;color:#15803d">${fmt(pkgRev)} ج.م</td>
          <td style="text-align:left;color:#2563eb">${fmt(pkgPaid)} ج.م</td>
          <td style="text-align:left;color:#dc2626">${fmt(pkgRemain)} ج.م</td>
          <td></td>
        </tr></tfoot>
      </table>
    </div>`;
  }).join('');

  const fParts = [];
  const n = document.getElementById('filterName');
  const s = document.getElementById('filterStatus');
  const p = document.getElementById('filterPackage');
  if (n?.value) fParts.push('اسم: '+n.value);
  if (s?.value) fParts.push('الحالة: '+(_STATUS[s.value]||s.value));
  if (p?.value) fParts.push('برنامج: '+p.value);

  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8">
<title>تقرير الحجوزات — نيو سي برنسيس</title>
${_FONTS}
<style>${_BASE_CSS}</style>
</head><body>
<button id="printBtn" onclick="window.print()">🖨️ طباعة / حفظ كـ PDF</button>
<div class="page-wrap">

  ${_header('تقرير الحجوزات', `
    <span>تاريخ الطباعة: <strong>${new Date().toLocaleDateString('ar-EG')}</strong></span>
    <span>إجمالي السجلات: <strong style="color:#1B5E20">${data.length}</strong></span>
    ${fParts.length?`<span style="color:#7c3aed">فلاتر مطبّقة: ${fParts.join(' | ')}</span>`:''}
  `)}

  <!-- KPIs -->
  <div class="kpi-grid" style="padding:16px 24px">
    ${kpiCards}
  </div>

  <div class="divider"></div>

  <!-- Groups -->
  <div style="padding:0 0 4px">
    <div style="padding:4px 24px 12px;font-size:13px;font-weight:700;color:#374151">
      تفاصيل الحجوزات مجمّعة حسب البرنامج — <span style="color:#1B5E20">${Object.keys(groups).length} برامج</span>
    </div>
    ${groupsHtml}
  </div>

  <div style="padding:0 24px">
  ${_footer()}
  </div>
</div>
${_AP}</body></html>`;

  _openPrint(html);
}

// ══════════════════════════════════════════════════════════
//  4. PACKAGE DETAILS (PDF)
// ══════════════════════════════════════════════════════════
function printPackagePDF() {
  const data = window.currentPackage;

  // Fallback: if for any reason the package data isn't available yet,
  // don't print a near-empty page — let the user know instead.
  if (!data) {
    alert('برجاء الانتظار حتى يتم تحميل بيانات البرنامج بالكامل ثم المحاولة مرة أخرى');
    return;
  }

  const fmtDate = d => d ? window.formatDate(d) : '—';
  const fmtPrice = n => (n || n === 0) ? window.formatCurrency(n) : '—';
  const stars = n => n ? '★'.repeat(n) : '—';

  const infoBoxes = [
    { lbl: 'تاريخ المغادرة', val: fmtDate(data.departure_date) },
    { lbl: 'مدة الرحلة',     val: data.duration_nights ? `${data.duration_nights} ليالي` : '—' },
    { lbl: 'مدينة الانطلاق', val: data.departure_city || '—' },
    { lbl: 'نوع الرحلة',     val: data.flight_type || 'مباشر' },
  ].map(b => `
    <div class="info-box">
      <label>${b.lbl}</label>
      <p>${b.val}</p>
    </div>`).join('');

  const hotelBlock = (name, label, hotel, starsCount, nights, distance) => `
    <div class="info-box" style="margin-bottom:10px">
      <label>${label}</label>
      <p>${hotel || '—'} ${starsCount ? `<span style="color:#B8860B">${stars(starsCount)}</span>` : ''}</p>
      <div style="font-size:11px;color:#64748b;margin-top:4px">
        ${nights ? `إقامة لـ ${nights} ليالي` : ''}${distance ? ` &nbsp;•&nbsp; ${distance}` : ''}
      </div>
    </div>`;

  const hotelsHtml = hotelBlock('مكة', 'فندق مكة المكرمة', data.mecca_hotel, data.mecca_hotel_stars, data.nights_mecca, data.mecca_hotel_distance)
    + hotelBlock('المدينة', 'فندق المدينة المنورة', data.medina_hotel, data.medina_hotel_stars, data.nights_medina, data.medina_hotel_distance);

  const listHtml = (arr, emptyTxt, color) => {
    if (!arr || !arr.length) return `<p style="font-size:12px;color:#94a3b8">${emptyTxt}</p>`;
    return `<ul style="list-style:none;display:grid;grid-template-columns:1fr 1fr;gap:6px">
      ${arr.map(item => `<li style="font-size:12px;color:#374151"><span style="color:${color};font-weight:700">✓</span> ${item}</li>`).join('')}
    </ul>`;
  };

  const itineraryHtml = (data.itinerary && data.itinerary.length)
    ? data.itinerary.map(item => `
        <div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:12px 14px;margin-bottom:8px">
          <div style="font-weight:700;color:#1B5E20;font-size:13px;margin-bottom:4px">اليوم ${item.day}: ${item.title || ''}</div>
          <div style="font-size:12px;color:#475569;line-height:1.7">${item.description || ''}</div>
        </div>`).join('')
    : `<p style="font-size:12px;color:#94a3b8">برنامج الرحلة التفصيلي غير متوفر</p>`;

  const priceHtml = `
    <div class="pay-box">
      <div class="pay-row total">
        <span>سعر الفرد (بالغ)</span>
        <strong>${fmtPrice(data.price_per_person)}</strong>
      </div>
      ${data.price_child ? `
      <div class="pay-row">
        <span>سعر الطفل المرافق</span>
        <strong>${fmtPrice(data.price_child)}</strong>
      </div>` : ''}
      <div class="pay-row">
        <span>المقاعد المتاحة</span>
        <strong>${data.available_seats ?? '—'}</strong>
      </div>
    </div>`;

  const imageHtml = data.thumbnail_url
    ? `<div style="padding:0 24px;margin-top:18px"><img src="${data.thumbnail_url}" style="width:100%;max-height:280px;object-fit:cover;border-radius:10px" onerror="this.parentElement.style.display='none'"></div>`
    : '';

  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8">
<title>تفاصيل - ${data.title || ''}</title>
${_FONTS}
<style>${_BASE_CSS}</style>
</head><body>
<button id="printBtn" onclick="window.print()">🖨️ طباعة / حفظ كـ PDF</button>
<div class="page-wrap">

  ${_header('تفاصيل البرنامج', `
    <span style="font-size:14px;font-weight:700;color:#1B5E20">${data.title || ''}</span>
    ${data.category ? `<span style="color:#B8860B">التصنيف: ${data.category}</span>` : ''}
  `)}

  ${imageHtml}

  <div class="section">
    <div class="section-title"><i>ℹ️</i> معلومات الرحلة الأساسية</div>
    <div class="info-grid">${infoBoxes}</div>
  </div>

  <div class="section">
    <div class="section-title"><i>🏨</i> الإقامة الفندقية</div>
    ${hotelsHtml}
  </div>

  <div class="section">
    <div class="section-title"><i>✅</i> يشمل البرنامج</div>
    ${listHtml(data.includes, 'لا يوجد بيانات', '#16a34a')}
  </div>

  <div class="section">
    <div class="section-title"><i>✖️</i> لا يشمل البرنامج</div>
    ${listHtml(data.excludes, 'لا يوجد بيانات', '#dc2626')}
  </div>

  <div class="section">
    <div class="section-title"><i>🗓️</i> برنامج الرحلة اليومي</div>
    ${itineraryHtml}
  </div>

  <div class="section" style="padding-bottom:18px">
    <div class="section-title"><i>💰</i> الأسعار والمقاعد</div>
    ${priceHtml}
  </div>

  <div class="divider"></div>

  <div style="padding:0 24px">
  ${_footer()}
  </div>
</div>
${_AP}</body></html>`;

  _openPrint(html);
}
