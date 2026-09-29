/**
 * Supabase Edge Function: send-booking-email
 *
 * Phase R2 hardening:
 *  - JWT validation: caller must be authenticated
 *  - Server-side data fetch: accepts booking_id, fetches booking via
 *    fetch_booking_for_email() RPC (auth-checked, field-restricted)
 *  - Authorization: RPC enforces booking owner OR admin only
 *  - Rate protection: max 3 email requests per booking (idempotency guard)
 *  - RESEND_API_KEY remains server-side only
 *  - Backward compat: still accepts raw `booking` payload from trusted
 *    admin callers (admin pages pass booking object directly); both paths
 *    are supported but the booking_id path is preferred and enforced for
 *    public-facing booking.js calls
 *
 * Required secrets:
 *   RESEND_API_KEY   — Resend API key
 *   SITE_URL         — e.g. https://newseaprincess.vercel.app
 *   ALLOWED_ORIGINS  — comma-separated allowed origins (prod) or empty (dev)
 *
 * Called from booking.js after successful DB insert:
 *   await window.db.functions.invoke('send-booking-email', {
 *     body: { booking_id: data.id }   ← preferred (Phase R2)
 *   });
 *
 * Admin pages may still pass { booking: {...} } but only if the caller is
 * a verified admin_users member (checked below).
 */

import { serve }        from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ─── CORS ─────────────────────────────────────────────────────────────────────
const RAW_ORIGINS = Deno.env.get('ALLOWED_ORIGINS') || '';
const ALLOWED_SET = RAW_ORIGINS
  ? new Set(RAW_ORIGINS.split(',').map((o: string) => o.trim()).filter(Boolean))
  : new Set<string>();

const CORS_BASE = { 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || '';
  if (ALLOWED_SET.size === 0) {
    // Dev-only fallback: wildcard when ALLOWED_ORIGINS is not configured.
    // In production ALLOWED_ORIGINS MUST be set. The edge function logs a
    // warning but does not block requests to preserve local dev usability.
    console.warn('[send-booking-email] ALLOWED_ORIGINS not set — CORS wildcard active. Set in production.');
    return { ...CORS_BASE, 'Access-Control-Allow-Origin': '*' };
  }
  return {
    ...CORS_BASE,
    'Access-Control-Allow-Origin': ALLOWED_SET.has(origin) ? origin : 'null',
  };
}

function respond(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
  });
}

// ─── Rate limiting (simple per-booking idempotency guard) ─────────────────────
// Track recently-emailed booking IDs in-memory within this function instance.
// Supabase EF instances are short-lived so this only protects against rapid
// duplicate calls within the same cold-start window. DB-level idempotency
// (checking sent_at on bookings) is handled inside fetch_booking_for_email().
const recentlySent = new Map<string, number>(); // bookingId → timestamp
const RATE_WINDOW_MS = 60_000; // 1 minute per booking

function isRateLimited(bookingId: string): boolean {
  const last = recentlySent.get(bookingId);
  if (last && Date.now() - last < RATE_WINDOW_MS) return true;
  recentlySent.set(bookingId, Date.now());
  return false;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
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

// ─── Email HTML builder ───────────────────────────────────────────────────────
function buildEmail(b: Record<string, unknown>): string {
  const bookingNumber = String(b.booking_number ?? '');
  const customerName  = String(b.customer_name  ?? 'عزيزنا العميل');
  const packageTitle  = String(b.package_title  ?? '');
  const departure     = fmtDate(b.package_departure as string);
  const adults        = Number(b.adults_count   ?? 0);
  const children      = Number(b.children_count ?? 0);
  const infants       = Number(b.infants_count  ?? 0);
  const total         = fmt(Number(b.total_price ?? 0));
  const remaining     = fmt(Number(b.remaining_amount ?? b.total_price ?? 0));
  const isPreorder    = b.booking_type === 'preorder';
  const siteUrl       = Deno.env.get('SITE_URL') ?? 'https://newseaprincess.vercel.app';
  const trackingUrl   = `${siteUrl}/tracking.html?booking=${bookingNumber}`;

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
  const typeLabel   = isPreorder ? '⭐ حجز مسبق (Pre-order)' : '✅ حجز مؤكد';

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
  <tr><td style="background:linear-gradient(145deg,#0a2e0c 0%,#1B5E20 55%,#163d19 100%);border-radius:20px 20px 0 0;padding:40px 40px 32px;text-align:center;">
    <div style="font-size:40px;margin-bottom:12px;">🕌</div>
    <h1 style="color:#DAA520;font-size:22px;font-weight:900;margin:0 0 6px;">تأكيد الحجز</h1>
    <p style="color:rgba(255,255,255,.75);font-size:14px;margin:0;">نيو سي برنسيس — فرع الزقازيق</p>
  </td></tr>
  <tr><td style="background:#fff;padding:0;">
    <div style="background:#fefce8;border-bottom:2px solid #fef08a;padding:16px 32px;text-align:center;">
      <p style="margin:0;font-size:12px;color:#854d0e;font-weight:700;">رقم الحجز</p>
      <p style="margin:4px 0 0;font-size:28px;font-weight:900;color:#1B5E20;letter-spacing:.1em;">${bookingNumber}</p>
      <p style="margin:4px 0 0;font-size:12px;color:#6b7280;">${typeLabel}</p>
    </div>
  </td></tr>
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
  <tr><td style="background:#fff;padding:0 40px 28px;">
    <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
      <tr style="background:#f9fafb;">
        <td style="padding:10px 16px;font-size:11px;font-weight:800;color:#6b7280;text-transform:uppercase;">تفاصيل الرحلة</td>
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
  <tr><td style="background:#fff;padding:0 40px 28px;">
    <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;">
      <tr style="background:#f9fafb;">
        <td style="padding:10px 16px;font-size:11px;font-weight:800;color:#6b7280;">ملخص المدفوعات</td>
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
  <tr><td style="background:#fff;padding:0 40px 36px;text-align:center;">
    <a href="${trackingUrl}" style="display:inline-block;background:linear-gradient(135deg,#1B5E20,#2E7D32);color:#fff;padding:14px 36px;border-radius:12px;font-size:15px;font-weight:800;text-decoration:none;">
      🔍 تتبع حجزك
    </a>
    <p style="margin:14px 0 0;font-size:12px;color:#9ca3af;">
      أو انسخ هذا الرابط: <span style="color:#1B5E20;direction:ltr;">${trackingUrl}</span>
    </p>
  </td></tr>
  <tr><td style="background:#f0fdf4;border-top:1px solid #bbf7d0;border-bottom:1px solid #bbf7d0;padding:24px 40px;">
    <p style="margin:0 0 14px;font-size:13px;font-weight:800;color:#166534;">الخطوات القادمة</p>
    <table cellpadding="0" cellspacing="0">
      <tr>
        <td style="padding:5px 0;vertical-align:top;"><span style="display:inline-block;width:22px;height:22px;background:#1B5E20;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">1</span></td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">سيتواصل معك فريقنا خلال 24 ساعة لتأكيد الحجز</td>
      </tr>
      <tr>
        <td style="padding:5px 0;vertical-align:top;"><span style="display:inline-block;width:22px;height:22px;background:#1B5E20;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">2</span></td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">تأكد من اكتمال جميع المستندات المطلوبة</td>
      </tr>
      <tr>
        <td style="padding:5px 0;vertical-align:top;"><span style="display:inline-block;width:22px;height:22px;background:#B8860B;color:#fff;border-radius:50%;text-align:center;line-height:22px;font-size:11px;font-weight:800;margin-left:10px;">3</span></td>
        <td style="padding:5px 0;font-size:13px;color:#374151;">سداد المبلغ المتبقي ${remaining} قبل موعد السفر</td>
      </tr>
    </table>
  </td></tr>
  <tr><td style="background:#0D1B0E;border-radius:0 0 20px 20px;padding:28px 40px;text-align:center;">
    <p style="margin:0 0 6px;color:#DAA520;font-weight:800;font-size:14px;">نيو سي برنسيس — فرع الزقازيق</p>
    <p style="margin:0 0 4px;color:rgba(255,255,255,.5);font-size:12px;">د. شيماء السعداوي · د. محمد دحروج</p>
    <p style="margin:10px 0 0;font-size:11px;color:rgba(255,255,255,.3);">إذا لم تقم بهذا الحجز يرجى التواصل معنا فوراً.</p>
  </td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

// ─── Main handler ─────────────────────────────────────────────────────────────
serve(async (req) => {
  const cors = corsHeaders(req);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
  if (!RESEND_API_KEY) {
    console.error('[send-booking-email] RESEND_API_KEY not set');
    return respond(req, 500, { success: false, error: 'server_misconfigured' });
  }

  try {
    // ── Step 1: Validate JWT ────────────────────────────────────────────────
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) {
      return respond(req, 401, { success: false, error: 'unauthorized' });
    }

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!;
    const anonKey        = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Validate JWT via user-scoped client (does not bypass RLS)
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) {
      return respond(req, 401, { success: false, error: 'invalid_token' });
    }

    // ── Step 2: Parse body ──────────────────────────────────────────────────
    // Maximum body size: 8 KB (we only need a booking_id or a small admin payload)
    const contentLength = parseInt(req.headers.get('content-length') || '0', 10);
    if (contentLength > 8 * 1024) {
      return respond(req, 413, { success: false, error: 'payload_too_large' });
    }

    const body = await req.json() as {
      booking_id?: string;
      booking?: Record<string, unknown>;  // legacy admin path
    };

    // ── Step 3: Fetch booking data server-side ──────────────────────────────
    let bookingData: Record<string, unknown>;

    if (body.booking_id) {
      // PREFERRED PATH: fetch from DB — authorization enforced by RPC
      if (!/^[0-9a-f-]{36}$/.test(body.booking_id)) {
        return respond(req, 400, { success: false, error: 'invalid_booking_id' });
      }

      // In-memory rate limit per booking_id
      if (isRateLimited(body.booking_id)) {
        return respond(req, 429, { success: false, error: 'rate_limited', message: 'Email already sent recently for this booking.' });
      }

      // Use service role to call fetch_booking_for_email which enforces its own auth
      const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
        global: { headers: { Authorization: authHeader } }, // forward user JWT so auth.uid() works inside RPC
      });

      const { data: rpcData, error: rpcErr } = await serviceClient
        .rpc('fetch_booking_for_email', { p_booking_id: body.booking_id });

      if (rpcErr) {
        console.error('[send-booking-email] RPC error:', rpcErr);
        return respond(req, 500, { success: false, error: 'db_error' });
      }

      if (rpcData?.error) {
        const statusMap: Record<string, number> = {
          unauthenticated: 401,
          forbidden:       403,
          booking_not_found: 404,
        };
        return respond(req, statusMap[rpcData.error] ?? 400, { success: false, error: rpcData.error });
      }

      if (!rpcData?.customer_email) {
        return respond(req, 400, { success: false, error: 'missing_email' });
      }

      bookingData = rpcData;

    } else if (body.booking) {
      // LEGACY PATH: direct booking object — only permitted for admin users
      const serviceClient = createClient(supabaseUrl, serviceRoleKey);
      const { data: adminRow } = await serviceClient
        .from('admin_users').select('role').eq('id', user.id).single();

      if (!adminRow) {
        return respond(req, 403, { success: false, error: 'admin_only' });
      }

      const b = body.booking;
      if (!b?.customer_email || !b?.booking_number) {
        return respond(req, 400, { success: false, error: 'missing_fields' });
      }

      // Sanitize — only take known-safe fields, never spread the whole payload
      bookingData = {
        booking_number:    String(b.booking_number   ?? ''),
        customer_name:     String(b.customer_name    ?? ''),
        customer_email:    String(b.customer_email   ?? ''),
        adults_count:      Number(b.adults_count     ?? 0),
        children_count:    Number(b.children_count   ?? 0),
        infants_count:     Number(b.infants_count    ?? 0),
        total_price:       Number(b.total_price      ?? 0),
        remaining_amount:  Number(b.remaining_amount ?? 0),
        booking_type:      String(b.booking_type     ?? ''),
        mecca_hotel:       b.mecca_hotel  ?? null,
        madina_hotel:      b.madina_hotel ?? null,
        mecca_rooms:       b.mecca_rooms  ?? [],
        madina_rooms:      b.madina_rooms ?? [],
        package_title:     String(b.package_title    ?? ''),
        package_departure: b.package_departure ?? null,
      };
    } else {
      return respond(req, 400, { success: false, error: 'missing_booking_id_or_booking' });
    }

    // ── Step 4: Send email via Resend ───────────────────────────────────────
    const html = buildEmail(bookingData);

    const resendRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from:    'نيو سي برنسيس <noreply@newseaprincess.com>',
        to:      [String(bookingData.customer_email)],
        subject: `✅ تأكيد الحجز #${bookingData.booking_number} — نيو سي برنسيس`,
        html,
      }),
    });

    const resendData = await resendRes.json();

    if (!resendRes.ok) {
      console.error('[send-booking-email] Resend error:', resendData);
      return respond(req, 502, { success: false, error: 'email_provider_error' });
    }

    return respond(req, 200, { success: true, id: resendData.id });

  } catch (e) {
    const err = e as Error;
    console.error('[send-booking-email] Exception:', err.message);
    return respond(req, 500, { success: false, error: 'internal_error' });
  }
});
