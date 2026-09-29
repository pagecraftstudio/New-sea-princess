/**
 * supabase/functions/send-communication/index.ts
 * Phase 12 — Traveler Communication Hub
 *
 * Sends outbound messages (email via Resend, WhatsApp link, etc.)
 * and logs them to trip_communications + updates communication_queue.
 *
 * Required secrets:
 *   RESEND_API_KEY   — for email channel
 *   ALLOWED_ORIGINS  — comma-separated allowed origins (production; empty = dev wildcard)
 *   SITE_URL         — base URL for links in emails
 *
 * Request body:
 *   {
 *     queue_id?:      string,   // if sending a queued item
 *     trip_file_id?:  string,
 *     booking_id?:    string,
 *     channel:        'email' | 'whatsapp' | 'in_app',
 *     recipient_email?: string,
 *     recipient_phone?: string,
 *     recipient_name?:  string,
 *     subject?:        string,
 *     body:            string,  // final rendered body
 *     trigger_event?:  string,
 *     template_id?:    string,
 *     is_automated?:   boolean,
 *   }
 */

import { serve }        from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// CORS — origin-whitelist pattern. Set ALLOWED_ORIGINS in Supabase secrets
// (comma-separated, e.g. https://flowtravel.com,http://localhost:3000).
// When unset (dev), falls back to wildcard with a console warning.
const RAW_ORIGINS  = Deno.env.get('ALLOWED_ORIGINS') || '';
const ALLOWED_SET  = new Set(RAW_ORIGINS.split(',').map(s => s.trim()).filter(Boolean));

function getCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || '';
  if (ALLOWED_SET.size === 0) {
    console.warn('[send-communication] ALLOWED_ORIGINS not set — CORS wildcard active (dev mode only)');
    return {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    };
  }
  return {
    'Access-Control-Allow-Origin': ALLOWED_SET.has(origin) ? origin : 'null',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };
}

serve(async (req) => {
  const CORS = getCorsHeaders(req);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const supabaseUrl    = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const anonKey        = Deno.env.get('SUPABASE_ANON_KEY')!;
  const resendKey      = Deno.env.get('RESEND_API_KEY');
  const siteUrl        = Deno.env.get('SITE_URL') || 'https://newseaprincess.vercel.app';

  // Auth
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: CORS });

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return new Response(JSON.stringify({ error: 'Invalid token' }), { status: 401, headers: CORS });

  const db = createClient(supabaseUrl, serviceRoleKey);

  // Verify admin
  const { data: adminUser } = await db.from('admin_users').select('role').eq('id', user.id).single();
  if (!adminUser) return new Response(JSON.stringify({ error: 'Access denied' }), { status: 403, headers: CORS });

  try {
    const body = await req.json();
    const {
      queue_id, trip_file_id, booking_id,
      channel, recipient_email, recipient_phone,
      recipient_name, subject, body: msgBody,
      trigger_event, template_id, is_automated = false,
    } = body;

    if (!channel || !msgBody) {
      return new Response(JSON.stringify({ error: 'channel and body required' }), { status: 400, headers: CORS });
    }

    let externalId: string | null = null;
    let sendStatus = 'sent';
    let errorMsg: string | null = null;

    // ── EMAIL via Resend ──────────────────────────────────────────────────────
    if (channel === 'email') {
      if (!recipient_email) {
        return new Response(JSON.stringify({ error: 'recipient_email required for email channel' }), { status: 400, headers: CORS });
      }
      if (!resendKey) {
        console.warn('[send-communication] RESEND_API_KEY not set — email not sent');
        sendStatus = 'not_configured';
        errorMsg   = 'RESEND_API_KEY not configured — email was not sent';
      } else {
        // Build branded HTML email
        const htmlBody = `
<!DOCTYPE html>
<html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><style>
  body{font-family:'Cairo',Arial,sans-serif;background:#f3f4f6;margin:0;padding:20px;}
  .container{max-width:560px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 16px rgba(0,0,0,.08);}
  .header{background:linear-gradient(135deg,#1B5E20,#2E7D32);padding:28px 32px;text-align:center;}
  .header img{height:40px;}
  .header h1{color:#fff;font-size:20px;margin:12px 0 0;font-weight:800;}
  .body{padding:32px;color:#374151;font-size:15px;line-height:1.8;white-space:pre-line;}
  .footer{background:#f9fafb;padding:16px 32px;text-align:center;font-size:12px;color:#9ca3af;border-top:1px solid #e5e7eb;}
  .btn{display:inline-block;background:#1B5E20;color:#fff;padding:12px 28px;border-radius:8px;text-decoration:none;font-weight:700;margin-top:16px;}
</style></head>
<body>
<div class="container">
  <div class="header">
    <h1>🌍 Flow Travel</h1>
  </div>
  <div class="body">${msgBody.replace(/\n/g, '<br>')}</div>
  <div class="footer">
    Flow Travel &amp; Tourism · جميع الحقوق محفوظة<br>
    <a href="${siteUrl}" style="color:#1B5E20;">www.flowtravel.com</a>
  </div>
</div>
</body></html>`;

        const resendRes = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${resendKey}` },
          body: JSON.stringify({
            from:    'Flow Travel <noreply@flowtravel.com>',
            to:      [recipient_email],
            subject: subject || 'رسالة من Flow Travel',
            html:    htmlBody,
            text:    msgBody,
          }),
        });

        const resendData = await resendRes.json();
        if (!resendRes.ok) {
          sendStatus = 'failed';
          errorMsg   = resendData.message || JSON.stringify(resendData);
          console.error('[send-communication] Resend error:', resendData);
        } else {
          externalId = resendData.id;
        }
      }
    }

    // ── WhatsApp / SMS — no API integration yet (P2.1 fix) ─────────────────
    // Do NOT mark as sent unless an actual provider confirms delivery.
    // WhatsApp Business API requires approved WABA + template setup.
    // SMS requires a configured gateway (Twilio, Vonage, etc).
    // These are logged so staff can dispatch manually via wa.me links.
    if (channel === 'whatsapp' || channel === 'sms') {
      sendStatus = 'pending_manual';
      errorMsg   = channel === 'whatsapp'
        ? 'WhatsApp API not integrated — logged for manual dispatch via wa.me'
        : 'SMS gateway not integrated — logged for manual dispatch';
    }
    // in_app: writing to DB IS the delivery mechanism — mark sent
    if (channel === 'in_app') {
      sendStatus = 'sent';
    }

    const now = new Date().toISOString();

    // ── Update queue record if this was queued ────────────────────────────────
    if (queue_id) {
      await db.from('communication_queue').update({
        status:        sendStatus,
        sent_at:       sendStatus === 'sent' ? now : null,
        error_msg:     errorMsg,
        status_reason: errorMsg,
        external_id:   externalId,
      }).eq('id', queue_id);
    }

    // ── Insert into communication_queue if new ────────────────────────────────
    let finalQueueId = queue_id;
    if (!queue_id) {
      const { data: qRow } = await db.from('communication_queue').insert({
        trip_file_id, booking_id, template_id,
        channel, recipient_type: 'customer',
        recipient_name, recipient_email, recipient_phone,
        subject, body: msgBody,
        trigger_event, is_automated,
        status:        sendStatus,
        status_reason: errorMsg,
        scheduled_at:  now,
        sent_at:       sendStatus === 'sent' ? now : null,
        error_msg:     errorMsg,
        external_id:   externalId,
        created_by:  user.id,
      }).select('id').single();
      finalQueueId = qRow?.id;
    }

    // ── Log to trip_communications ────────────────────────────────────────────
    if (trip_file_id) {
      await db.from('trip_communications').insert({
        trip_file_id,
        channel,
        direction:     'outbound',
        recipient_type: 'customer',
        recipient_name,
        subject,
        summary:       msgBody.slice(0, 300),
        sent_by:       user.id,
        sent_at:       now,
        is_automated,
        queue_id:      finalQueueId,
        template_id,
      });
    }

    return new Response(JSON.stringify({
      success: sendStatus === 'sent',
      status:  sendStatus,
      queue_id: finalQueueId,
      external_id: externalId,
      error: errorMsg,
    }), { headers: { ...CORS, 'Content-Type': 'application/json' } });

  } catch (err) {
    console.error('[send-communication] error:', err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: CORS,
    });
  }
});
