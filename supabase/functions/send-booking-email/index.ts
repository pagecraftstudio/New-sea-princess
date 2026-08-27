/**
 * Supabase Edge Function: send-booking-email
 *
 * Sends a booking confirmation email to the customer via Resend.
 *
 * Deploy:
 *   supabase functions deploy send-booking-email
 *
 * Required secrets (set once):
 *   supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx
 *   supabase secrets set SITE_URL=https://newseaprincess.vercel.app
 *
 * Called from booking.js after successful DB insert:
 *   await window.db.functions.invoke('send-booking-email', { body: { booking } });
 *
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team.
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ── helpers ──────────────────────────────────────────────────────────────────
function fmt(n: number): string {
  return new Intl.NumberFormat('ar-EG', {
    style: 'currency', currency: 'EGP', maximumFractionDigits: 0,
  }).format(n);
}

function fmtDate(d: string | null | undefined): string {
  if (!d) return 'سيُحدد لاحقاً';
  return new Intl.DateTimeFormat('ar-EG', {
    day: 'numeric', month: 'long', year: 'numeric',
  }).format(new Date(d));
}

// ── email HTML builder ────────────────────────────────────────────────────────
function buildEmail(b: Record<string, unknown>): string {
  const bookingNumber   = String(b.booking_number ?? '');
  const customerName    = String(b.customer_name  ?? 'عزيزنا العميل');
  const customerEmail   = String(b.customer_email ?? '');
  const packageTitle    = String(b.package_title  ?? '');
  const departure       = fmtDate(b.package_departure as string);
  const adults          = Number(b.adults_count   ?? 0);
  const children        = Number(b.children_count ?? 0);
  const infants         = Number(b.infants_count  ?? 0);
  const total           = fmt(Number(b.total_price ?? 0));
  const remaining       = fmt(Number(b.remaining_amount ?? b.total_price ?? 0));
  const isPreorder      = b.booking_type === 'preorder';
  const siteUrl         = Deno.env.get('SITE_URL') ?? 'https://newseaprincess.vercel.app';
  const trackingUrl     = `${siteUrl}/tracking.html?booking=${bookingNumber}`;

  const meccaHotel  = (b.mecca_hotel  as { name?: string } | null)?.name  ?? '';
  const madinaHotel = (b.madina_hotel as { name?: string } | null)?.name ?? '';

  const roomRows = (rows: unknown[], city: string) =>
    (rows as { label?: string; qty?: number; price_each?: number }[])
      .map(r => `<tr>
        <td style="padding:6px 12px;color:#4b5563;font-size:13px;">${city}: ${r.label}</td>
        <td style="padding:6px 12px;color:#374151;font-size:13px;text-align:left;">${r.qty} غرفة × ${fmt(r.price_each ?? 0)}</td>
      </tr>`)
      .join('');

  const meccaRooms  = roomRows((b.mecca_rooms  as unknown[]) ?? [], 'مكة');
  const madinaRooms = roomRows((b.madina_rooms as unknown[]) ?? [], 'المدينة');

  const typeLabel = isPreorder
    ? '⭐ حجز مسبق (Pre-order)'
    : '✅ حجز مؤكد';

  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>تأكيد الحجز #${bookingNumber}</title>
</head>
<body style="margin:0;padding:0;background:#f0ede6;font-family:'Cairo',Arial,sans-serif;direction:rtl;">

<table width="100%" cellpadding="0" cellspacing="0" style="background:#f0ede6;padding:32px 16px;">
<tr><td align="center">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;">

  <!-- ── Header ── -->
  <tr><td style="background:linear-gradient(145deg,#0a2e0c 0%,#1B5E20 55%,#163d19 100%);border-radius:20px 20px 0 0;padding:40px 40px 32px;text-align:center;">
    <div style="font-size:40px;margin-bottom:12px;">🕌</div>
    <h1 style="color:#DAA520;font-size:22px;font-weight:900;margin:0 0 6px;">تأكيد الحجز</h1>
    <p style="color:rgba(255,255,255,.75);font-size:14px;margin:0;">نيو سي برنسيس — فرع الزقازيق</p>
  </td></tr>

  <!-- ── Booking number badge ── -->
  <tr><td style="background:#fff;padding:0;">
    <div style="background:#fefce8;border-bottom:2px solid #fef08a;padding:16px 32px;text-align:center;">
      <p style="margin:0;font-size:12px;color:#854d0e;font-weight:700;text-transform:uppercase;letter-spacing:.05em;">رقم الحجز</p>
      <p style="margin:4px 0 0;font-size:28px;font-weight:900;color:#1B5E20;letter-spacing:.1em;">${bookingNumber}</p>
      <p style="margin:4px 0 0;font-size:12px;color:#6b7280;">${typeLabel}</p>
    </div>
  </td></tr>

  <!-- ── Greeting ── -->
  <tr><td style="background:#fff;padding:28px 40px 20px;">
    <p style="margin:0;font-size:15px;color:#374151;line-height:1.8;">
      أهلاً وسهلاً، <strong style="color:#1B5E20;">${customerName}</strong> 👋
    </p>
    <p style="margin:10px 0 0;font-size:14px;color:#6b7280;line-height:1.8;">
      ${isPreorder
        ? 'شكراً لك على تسجيل حجزك المسبق معنا. سيتواصل معك فريقنا قريباً لتأكيد التفاصيل النهائية.'
        : 'شكراً لك على ثقتك بنيو سي برنسيس. تم استلام طلب حجزك بنجاح وسيتواصل معك فريقنا قريباً لإتمام الترتيبات.'}
    </p>
  </td></tr>

  <!-- ── Booking details ── -->
  <tr><td style="background:#fff;padding:0 40px 28px;">
    <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
      <tr style="background:#f9fafb;">
        <td style="padding:10px 16px;font-size:11px;font-weight:800;color:#6b7280;text-transform:uppercase;letter-spacing:.05em;">تفاصيل الرحلة</td>
        <td></td>
      </tr>
      <tr style="border-top:1px solid #f3f4f6;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">البرنامج</td>
        <td style="padding:10px 16px;color:#111827;font-size:13px;font-weight:700;">${packageTitle}</td>
      </tr>
      <tr style="border-top:1px solid #f3f4f6;background:#fafafa;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">تاريخ المغادرة</td>
        <td style="padding:10px 16px;color:#111827;font-size:13px;">${departure}</td>
      </tr>
      <tr style="border-top:1px solid #f3f4f6;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">الأفراد</td>
        <td style="padding:10px 16px;color:#111827;font-size:13px;">
          ${adults > 0 ? `${adults} بالغ` : ''}
          ${children > 0 ? ` · ${children} طفل` : ''}
          ${infants > 0 ? ` · ${infants} رضيع` : ''}
        </td>
      </tr>
      ${meccaHotel ? `<tr style="border-top:1px solid #f3f4f6;background:#fafafa;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">فندق مكة المكرمة</td>
        <td style="padding:10px 16px;color:#111827;font-size:13px;">${meccaHotel}</td>
      </tr>` : ''}
      ${meccaRooms}
      ${madinaHotel ? `<tr style="border-top:1px solid #f3f4f6;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">فندق المدينة المنورة</td>
        <td style="padding:10px 16px;color:#111827;font-size:13px;">${madinaHotel}</td>
      </tr>` : ''}
      ${madinaRooms}
    </table>
  </td></tr>

  <!-- ── Price summary ── -->
  <tr><td style="background:#fff;padding:0 40px 28px;">
    <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
      <tr style="background:#f9fafb;">
        <td style="padding:10px 16px;font-size:11px;font-weight:800;color:#6b7280;text-transform:uppercase;letter-spacing:.05em;">ملخص المدفوعات</td>
        <td></td>
      </tr>
      <tr style="border-top:1px solid #f3f4f6;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">إجمالي الحجز</td>
        <td style="padding:10px 16px;color:#111827;font-size:14px;font-weight:800;">${total}</td>
      </tr>
      <tr style="border-top:1px solid #f3f4f6;background:#fafafa;">
        <td style="padding:10px 16px;color:#9ca3af;font-size:13px;">المبلغ المتبقي</td>
        <td style="padding:10px 16px;color:#b91c1c;font-size:14px;font-weight:800;">${remaining}</td>
      </tr>
    </table>
  </td></tr>

  <!-- ── CTA ── -->
  <tr><td style="background:#fff;padding:0 40px 36px;text-align:center;">
    <a href="${trackingUrl}" style="display:inline-block;background:linear-gradient(135deg,#1B5E20,#2E7D32);color:#fff;padding:14px 36px;border-radius:12px;font-size:15px;font-weight:800;text-decoration:none;">
      🔍 تتبع حجزك
    </a>
    <p style="margin:14px 0 0;font-size:12px;color:#9ca3af;">
      أو انسخ هذا الرابط: <span style="color:#1B5E20;direction:ltr;unicode-bidi:isolate;">${trackingUrl}</span>
    </p>
  </td></tr>

  <!-- ── What's next ── -->
  <tr><td style="background:#f0fdf4;border-top:1px solid #bbf7d0;border-bottom:1px solid #bbf7d0;padding:24px 40px;">
    <p style="margin:0 0 14px;font-size:13px;font-weight:800;color:#166534;">الخطوات القادمة</p>
    <table cellpadding="0" cellspacing="0">
      <tr>
        <td style="padding:5px 0;vertical-align:top;">
          <span style="display:inline-block;width:22px;height:22px;background:#1B5E20;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">1</span>
        </td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">سيتواصل معك فريقنا خلال 24 ساعة لتأكيد الحجز</td>
      </tr>
      <tr>
        <td style="padding:5px 0;vertical-align:top;">
          <span style="display:inline-block;width:22px;height:22px;background:#1B5E20;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">2</span>
        </td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">تأكد من اكتمال جميع المستندات المطلوبة</td>
      </tr>
      <tr>
        <td style="padding:5px 0;vertical-align:top;">
          <span style="display:inline-block;width:22px;height:22px;background:#B8860B;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">3</span>
        </td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">سداد المبلغ المتبقي ${remaining} قبل موعد السفر</td>
      </tr>
    </table>
  </td></tr>

  <!-- ── Footer ── -->
  <tr><td style="background:#0D1B0E;border-radius:0 0 20px 20px;padding:28px 40px;text-align:center;">
    <p style="margin:0 0 6px;color:#DAA520;font-weight:800;font-size:14px;">نيو سي برنسيس — فرع الزقازيق</p>
    <p style="margin:0 0 4px;color:rgba(255,255,255,.5);font-size:12px;">د. شيماء السعداوي · د. محمد دحروج</p>
    <p style="margin:10px 0 0;font-size:11px;color:rgba(255,255,255,.3);">
      إذا لم تقم بهذا الحجز يرجى التواصل معنا فوراً.
    </p>
  </td></tr>

</table>
</td></tr>
</table>

</body>
</html>`;
}

// ── handler ───────────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const { booking } = await req.json() as { booking: Record<string, unknown> };

    if (!booking?.customer_email) {
      return new Response(JSON.stringify({ success: false, error: 'missing_email' }), {
        status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
    if (!RESEND_API_KEY) {
      console.error('[send-booking-email] RESEND_API_KEY not set');
      return new Response(JSON.stringify({ success: false, error: 'server_misconfigured' }), {
        status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    const html = buildEmail(booking);

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from:    'نيو سي برنسيس <noreply@newseaprincess.com>',
        to:      [String(booking.customer_email)],
        subject: `✅ تأكيد الحجز #${booking.booking_number} — نيو سي برنسيس`,
        html,
      }),
    });

    const data = await res.json();

    if (!res.ok) {
      console.error('[send-booking-email] Resend error:', data);
      return new Response(JSON.stringify({ success: false, error: data }), {
        status: 502, headers: { ...CORS, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ success: true, id: data.id }), {
      status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    const err = e as Error;
    console.error('[send-booking-email] Exception:', err);
    return new Response(JSON.stringify({ success: false, error: err.message }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }
});
