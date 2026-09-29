// Supabase Edge Function: verify-recaptcha
// Verifies a reCAPTCHA v2 token server-side before allowing sensitive actions.
// Deploy: supabase functions deploy verify-recaptcha
// Secret: supabase secrets set RECAPTCHA_SECRET_KEY=<your_secret>

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

// ─── CORS (Phase R — F6: restrict wildcard) ───────────────────────────────────
// Set ALLOWED_ORIGINS env var in Supabase dashboard (comma-separated).
// Falls back to wildcard only in local dev (no env var set).
const RAW_ORIGINS  = Deno.env.get('ALLOWED_ORIGINS') || '';
const ALLOWED_SET  = RAW_ORIGINS ? new Set(RAW_ORIGINS.split(',').map(o => o.trim())) : new Set<string>();

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || '';
  const allowed = ALLOWED_SET.size === 0 ? '*' : (ALLOWED_SET.has(origin) ? origin : '');
  if (ALLOWED_SET.size === 0) console.warn('ALLOWED_ORIGINS not set — CORS wildcard active (dev mode)');
  return {
    'Access-Control-Allow-Origin':  allowed || 'null',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };
}

serve(async (req) => {
  const cors = corsHeaders(req);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const { token } = await req.json();
    if (!token) return new Response(JSON.stringify({ success: false, error: 'missing_token' }), { status: 400, headers: cors });

    const secret = Deno.env.get('RECAPTCHA_SECRET_KEY');
    if (!secret) return new Response(JSON.stringify({ success: false, error: 'server_misconfigured' }), { status: 500, headers: cors });

    const res = await fetch('https://www.google.com/recaptcha/api/siteverify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: `secret=${secret}&response=${token}`,
    });

    const data = await res.json();

    return new Response(JSON.stringify({ success: data.success }), {
      status: data.success ? 200 : 400,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ success: false, error: e.message }), { status: 500, headers: cors });
  }
});
