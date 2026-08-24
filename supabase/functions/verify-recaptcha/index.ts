// Supabase Edge Function: verify-recaptcha
// Verifies a reCAPTCHA v2 token server-side before allowing sensitive actions.
// Deploy: supabase functions deploy verify-recaptcha
// Secret: supabase secrets set RECAPTCHA_SECRET_KEY=<your_secret>

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const { token } = await req.json();
    if (!token) return new Response(JSON.stringify({ success: false, error: 'missing_token' }), { status: 400, headers: CORS });

    const secret = Deno.env.get('RECAPTCHA_SECRET_KEY');
    if (!secret) return new Response(JSON.stringify({ success: false, error: 'server_misconfigured' }), { status: 500, headers: CORS });

    const res = await fetch('https://www.google.com/recaptcha/api/siteverify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: `secret=${secret}&response=${token}`,
    });

    const data = await res.json();

    return new Response(JSON.stringify({ success: data.success }), {
      status: data.success ? 200 : 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ success: false, error: e.message }), { status: 500, headers: CORS });
  }
});
