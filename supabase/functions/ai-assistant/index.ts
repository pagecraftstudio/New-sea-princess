/**
 * supabase/functions/ai-assistant/index.ts
 * Flow Travel DMC — Canonical AI Edge Function
 *
 * Phase B hardening:
 *  - JWT validation (unchanged)
 *  - DB-driven permission checks via permission_matrix (C2)
 *  - History validation: role whitelist, count+size limits (C4)
 *  - Request size limit (C5)
 *  - CORS restricted to configured origins (C6)
 *  - Data minimization: no SELECT * on sensitive tables (H9)
 *  - Fast/smart model tier routing
 *  - OpenAI fallback provider support
 *  - Full audit logging
 *  - Request timeout
 *
 * Phase D additions (H5, M5/Phase H):
 *  - Per-user/per-feature rate limiting via check_ai_rate_limit() RPC
 *  - AI insights caching for cacheable features (daily_brief, operations_brief,
 *    recommendations, supplier_score) via get_cached_insight/set_cached_insight
 *  - Cache TTLs: daily_brief=480m, operations_brief=240m,
 *                recommendations=60m, supplier_score=720m
 *
 * Env vars:
 *   ANTHROPIC_API_KEY         — Claude key (required when AI_PROVIDER=anthropic)
 *   OPENAI_API_KEY            — OpenAI key (required when AI_PROVIDER=openai)
 *   AI_PROVIDER               — 'anthropic' (default) | 'openai' | 'demo'
 *   AI_MODEL_FAST             — fast model for Anthropic/OpenAI; default: claude-haiku-4-5-20251001
 *   AI_MODEL_SMART            — smart model for Anthropic/OpenAI; default: claude-sonnet-4-6
 *   ALLOWED_ORIGINS           — comma-separated origins, e.g. https://flowtravel.com,http://localhost:3000
 *   SUPABASE_URL              — injected by Supabase
 *   SUPABASE_SERVICE_ROLE_KEY — injected by Supabase
 *   SUPABASE_ANON_KEY         — injected by Supabase
 *   AI_DISABLE_RATE_LIMIT     — set to 'true' to disable rate limiting (local dev only)
 *   AI_DISABLE_CACHE          — set to 'true' to disable insight caching (local dev only)
 *
 * Demo provider (Phase 16.3) — set AI_PROVIDER=demo:
 *   DEMO_API_KEY              — API key for the demo provider (server-side only; NEVER in frontend)
 *   DEMO_API_BASE_URL         — OpenAI-compatible base URL; default: https://api.groq.com/openai/v1
 *   DEMO_MODEL_FAST           — fast model for demo provider; default: llama-3.1-8b-instant
 *   DEMO_MODEL_SMART          — smart model for demo provider; default: llama-3.3-70b-versatile
 *
 *   Default demo target: Groq (https://console.groq.com) — free-tier API key available.
 *   Free tier has rate limits; not for production traffic. For demo/dev only.
 *   Provider is logged in ai_requests.provider for full audit trail.
 */

import { serve }        from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── Config ───────────────────────────────────────────────────────────────────
const AI_PROVIDER    = Deno.env.get("AI_PROVIDER")       || "anthropic";
const ANTHROPIC_KEY  = Deno.env.get("ANTHROPIC_API_KEY") || "";
const OPENAI_KEY     = Deno.env.get("OPENAI_API_KEY")    || "";
const AI_MODEL_FAST  = Deno.env.get("AI_MODEL_FAST")     || "claude-haiku-4-5-20251001";
const AI_MODEL_SMART = Deno.env.get("AI_MODEL_SMART")    || "claude-sonnet-4-6";

// ─── Demo provider config (Phase 16.3) ───────────────────────────────────────
// AI_PROVIDER=demo uses a free-tier OpenAI-compatible API (Groq by default).
// Groq offers a free tier at https://console.groq.com — sign up for a free key.
// DEMO_API_BASE_URL can point to any OpenAI-compatible endpoint.
// NEVER set DEMO_API_KEY in frontend code — server-side Supabase secret only.
const DEMO_KEY         = Deno.env.get("DEMO_API_KEY")     || "";
const DEMO_BASE_URL    = Deno.env.get("DEMO_API_BASE_URL") || "https://api.groq.com/openai/v1";
const DEMO_MODEL_FAST  = Deno.env.get("DEMO_MODEL_FAST")  || "llama-3.1-8b-instant";
const DEMO_MODEL_SMART = Deno.env.get("DEMO_MODEL_SMART") || "llama-3.3-70b-versatile";

const MAX_TOKENS     = 1200;
const TIMEOUT_MS     = 28000;

// ─── Feature flags (Phase D) ──────────────────────────────────────────────────
const DISABLE_RATE_LIMIT = Deno.env.get("AI_DISABLE_RATE_LIMIT") === "true";
const DISABLE_CACHE      = Deno.env.get("AI_DISABLE_CACHE")      === "true";

// Features that support caching (non-personalized or low-personalization results)
// key = feature name, value = TTL in minutes
const CACHEABLE_FEATURES: Record<string, number> = {
  "daily_brief":       480,  // 8h — same for all admins today
  "operations_brief":  240,  // 4h — operations state changes slowly
  "supplier_score":    720,  // 12h — supplier analysis is stable
  "recommendations":    60,  // 1h — semi-personalized, short TTL
};

// ─── Size limits (C5, I) ──────────────────────────────────────────────────────
const MAX_BODY_BYTES     = 64 * 1024;   // 64 KB total body
const MAX_HISTORY_MSGS   = 20;          // max messages in history
const MAX_MSG_CHARS      = 4000;        // max chars per history message
const MAX_HISTORY_CHARS  = 40000;       // max total history chars

// ─── CORS (C6) ────────────────────────────────────────────────────────────────
const RAW_ORIGINS = Deno.env.get("ALLOWED_ORIGINS") || "";
const ALLOWED_ORIGINS: Set<string> = RAW_ORIGINS
  ? new Set(RAW_ORIGINS.split(",").map(o => o.trim()).filter(Boolean))
  : new Set(); // empty = allow all (dev fallback, warn below)

function getCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") || "";
  // If no allowed origins configured (dev), allow all with a console warning
  if (ALLOWED_ORIGINS.size === 0) {
    console.warn("ALLOWED_ORIGINS not set — CORS wildcard active (dev mode only)");
    return {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    };
  }
  // In production: only reflect allowed origins
  const allowed = ALLOWED_ORIGINS.has(origin) ? origin : "";
  return {
    "Access-Control-Allow-Origin": allowed || "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

// ─── Feature model tier ───────────────────────────────────────────────────────
const FAST_FEATURES = new Set(["follow_up_draft", "operations_brief", "recommendations"]);

// ─── Feature → required DB permission ────────────────────────────────────────
// Maps each AI feature to the permission that must exist in permission_matrix
const FEATURE_PERMISSION: Record<string, string> = {
  lead_analysis:        "use_ai_sales",
  opportunity_analysis: "use_ai_sales",
  opp_analysis:         "use_ai_sales",
  follow_up_draft:      "use_ai_sales",
  itinerary_draft:      "use_ai_sales",
  itinerary_improve:    "use_ai_sales",
  itinerary_suggest:    "use_ai_sales",
  quote_review:         "use_ai_finance",
  operations_brief:     "use_ai_operations",
  supplier_score:       "use_ai_operations",
  command_center:       "use_ai_command_center",
  recommendations:      "view_ai_dashboard",
};

// ─── DB-driven permission check (C2) ─────────────────────────────────────────
async function checkPermission(db: any, role: string, feature: string): Promise<boolean> {
  const permission = FEATURE_PERMISSION[feature];
  if (!permission) {
    // Unknown feature — only super_admin allowed
    return role === "super_admin";
  }
  const { data, error } = await db
    .from("permission_matrix")
    .select("roles")
    .eq("permission", permission)
    .single();
  if (error || !data) return false;
  const roles: string[] = data.roles || [];
  return roles.includes(role);
}

// ─── History validation (C4, I) ───────────────────────────────────────────────
function validateHistory(raw: unknown): { role: string; content: string }[] {
  if (!Array.isArray(raw)) return [];

  // Enforce count limit
  const slice = raw.slice(-MAX_HISTORY_MSGS);

  let totalChars = 0;
  const validated: { role: string; content: string }[] = [];

  for (const msg of slice) {
    if (typeof msg !== "object" || msg === null) continue;
    const role    = (msg as any).role;
    const content = (msg as any).content;

    // Only allow user/assistant roles — reject system/tool/function/etc.
    if (role !== "user" && role !== "assistant") continue;
    if (typeof content !== "string") continue;

    // Per-message size limit
    const trimmed = content.slice(0, MAX_MSG_CHARS);
    totalChars += trimmed.length;

    // Total history size limit — stop accumulating if exceeded
    if (totalChars > MAX_HISTORY_CHARS) break;

    validated.push({ role, content: trimmed });
  }

  return validated;
}

// ─── Main handler ─────────────────────────────────────────────────────────────
serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const startMs = Date.now();
  let userId: string | null = null;
  let feature = "unknown";

  try {
    // ── Body size limit (C5) ────────────────────────────────────────────────
    const contentLength = Number(req.headers.get("content-length") || 0);
    if (contentLength > MAX_BODY_BYTES) {
      return respond(413, { error: "Request too large" }, corsHeaders);
    }

    // ── Auth: JWT validation ─────────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) {
      return respond(401, { error: "Unauthorized" }, corsHeaders);
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } }
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(jwt);
    if (authErr || !user) {
      return respond(401, { error: "Unauthorized" }, corsHeaders);
    }
    userId = user.id;

    // ── Admin membership check ───────────────────────────────────────────────
    const { data: adminRow } = await supabaseAdmin
      .from("admin_users")
      .select("role")
      .eq("id", userId)
      .single();
    if (!adminRow) {
      return respond(403, { error: "Not an admin user" }, corsHeaders);
    }
    const role = adminRow.role as string;

    // ── Parse + validate body ────────────────────────────────────────────────
    let body: any;
    try {
      const raw = await req.text();
      if (raw.length > MAX_BODY_BYTES) {
        return respond(413, { error: "Request body too large" }, corsHeaders);
      }
      body = JSON.parse(raw);
    } catch {
      return respond(400, { error: "Invalid JSON body" }, corsHeaders);
    }

    feature          = (body.feature as string) || "unknown";
    const contextId  = (body.context_id as string) || null;
    const extraData  = (body.data as Record<string, any>) || {};
    const history    = validateHistory(body.history); // C4: validated, not raw

    // ── DB-driven permission check (C2) ──────────────────────────────────────
    const permitted = await checkPermission(supabaseAdmin, role, feature);
    if (!permitted) {
      return respond(403, { error: "Permission denied for this AI feature" }, corsHeaders);
    }

    // ── Rate limiting (H5 — Phase D) ─────────────────────────────────────────
    if (!DISABLE_RATE_LIMIT) {
      try {
        const { data: rateData } = await supabaseAdmin
          .rpc("check_ai_rate_limit", { p_user_id: userId, p_feature: feature });
        if (rateData && !rateData.allowed) {
          return respond(429, {
            error:      "Rate limit exceeded",
            message:    `لقد وصلت للحد اليومي لميزة "${feature}". يرجى المحاولة غداً.`,
            remaining:  rateData.remaining || 0,
            reset_at:   rateData.reset_at,
          }, corsHeaders);
        }
      } catch (rateErr) {
        // Rate limit check failure: FAIL CLOSED in production.
        // If the RPC is unavailable (DB overload, cold start, missing function),
        // we block the request rather than allowing unlimited AI calls.
        // To bypass during local development, set AI_DISABLE_RATE_LIMIT=true.
        console.error("Rate limit check failed (fail-closed):", rateErr);
        return respond(503, {
          error:   "Rate limit service unavailable",
          message: "لا يمكن معالجة الطلب حالياً. يرجى المحاولة بعد لحظات.",
        }, corsHeaders);
      }
    }

    // ── Cache check for cacheable features (M5 / Phase H) ────────────────────
    if (!DISABLE_CACHE && feature in CACHEABLE_FEATURES) {
      try {
        const today    = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
        const cacheKey = feature === "supplier_score" && contextId
          ? `${feature}:${contextId}`
          : feature === "recommendations"
          ? `${feature}:${userId}:${today}`
          : `${feature}:${today}`;

        const { data: cached } = await supabaseAdmin.rpc("get_cached_insight", { p_cache_key: cacheKey });
        if (cached?.data) {
          // Return cached result immediately — no AI call needed
          return respond(200, {
            success:   true,
            feature,
            result:    typeof cached.data === "string" ? cached.data : JSON.stringify(cached.data),
            cached:    true,
            cached_at: cached.created_at,
          }, corsHeaders);
        }
      } catch (cacheErr) {
        console.warn("Cache read failed (non-blocking):", cacheErr);
      }
    }

    // ── Fetch minimized business data (H9) ───────────────────────────────────
    const businessData = await fetchBusinessData(supabaseAdmin, feature, contextId, userId, extraData);

    // ── Build prompt ─────────────────────────────────────────────────────────
    const { system, userMessage } = buildPrompt(feature, businessData, extraData, history);

    // ── Call AI with timeout ─────────────────────────────────────────────────
    // When AI_PROVIDER=demo, use demo-specific model names (e.g. Groq Llama).
    const isFast  = FAST_FEATURES.has(feature);
    const model   = AI_PROVIDER === "demo"
      ? (isFast ? DEMO_MODEL_FAST : DEMO_MODEL_SMART)
      : (isFast ? AI_MODEL_FAST   : AI_MODEL_SMART);
    const aiResult = await callAI(system, userMessage, history, model);

    // ── Cache write for cacheable features (Phase D) ─────────────────────────
    if (!DISABLE_CACHE && feature in CACHEABLE_FEATURES) {
      try {
        const today    = new Date().toISOString().slice(0, 10);
        const cacheKey = feature === "supplier_score" && contextId
          ? `${feature}:${contextId}`
          : feature === "recommendations"
          ? `${feature}:${userId}:${today}`
          : `${feature}:${today}`;
        const ttl = CACHEABLE_FEATURES[feature];
        await supabaseAdmin.rpc("set_cached_insight", {
          p_cache_key:   cacheKey,
          p_data:        JSON.stringify(aiResult.content),
          p_ttl_minutes: ttl,
        });
      } catch (cacheWriteErr) {
        console.warn("Cache write failed (non-blocking):", cacheWriteErr);
      }
    }

    // ── Audit log ────────────────────────────────────────────────────────────
    const latency = Date.now() - startMs;
    await supabaseAdmin.from("ai_requests").insert({
      user_id:           userId,
      feature,
      context_type:      body.context_type || null,
      context_id:        contextId,
      model,
      provider:          AI_PROVIDER,   // 'anthropic' | 'openai' | 'demo'
      prompt_tokens:     aiResult.usage?.input_tokens  || aiResult.usage?.prompt_tokens     || null,
      completion_tokens: aiResult.usage?.output_tokens || aiResult.usage?.completion_tokens  || null,
      latency_ms:        latency,
      status:            "success",
    });

    return respond(200, {
      success: true,
      feature,
      result:     aiResult.content,
      model,
      latency_ms: latency,
    }, corsHeaders);

  } catch (err: any) {
    console.error("AI Assistant error:", err);
    if (userId) {
      try {
        const db = createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
        );
        await db.from("ai_requests").insert({
          user_id:     userId,
          feature,
          latency_ms:  Date.now() - startMs,
          status:      err.message?.includes("timeout") ? "timeout" : "error",
          error_message: String(err.message || err).slice(0, 500),
        });
      } catch (_) { /* ignore log failure */ }
    }
    return respond(500, { error: String(err.message || "AI request failed") }, corsHeaders);
  }
});

// ─── Data fetcher — minimized SELECT, no SELECT * on sensitive tables (H9) ───
async function fetchBusinessData(
  db: any, feature: string, contextId: string | null, userId: string, extra: any
) {
  const data: Record<string, any> = {};

  if (feature === "lead_analysis" && contextId) {
    const { data: lead } = await db.from("leads")
      .select("id,full_name,status,source,priority,destination,budget,travel_type,pax_adults,pax_children,language,nationality,next_follow_up,last_contacted,created_at,notes")
      .eq("id", contextId).single();
    data.lead = lead;

    const { data: activities } = await db.from("lead_activities")
      .select("type,title,outcome,created_at")
      .eq("lead_id", contextId)
      .order("created_at", { ascending: false }).limit(20);
    data.activities = activities || [];

    const { data: tasks } = await db.from("tasks")
      .select("title,due_at,priority,status")
      .eq("lead_id", contextId).eq("status", "pending").order("due_at").limit(10);
    data.tasks = tasks || [];

    const { data: opps } = await db.from("opportunities")
      .select("id,title,stage,value,probability,expected_close")
      .eq("lead_id", contextId);
    data.opportunities = opps || [];
  }

  if ((feature === "opportunity_analysis" || feature === "opp_analysis") && contextId) {
    const { data: opp } = await db.from("opportunities")
      .select("id,title,stage,value,currency,probability,expected_close,destination,updated_at,notes")
      .eq("id", contextId).single();
    data.opportunity = opp;

    const { data: quotes } = await db.from("quotations")
      .select("id,quote_number,status,total_amount,margin_pct,validity_date,created_at")
      .eq("opportunity_id", contextId)
      .order("created_at", { ascending: false }).limit(5);
    data.quotations = quotes || [];

    if (opp?.lead_id) {
      const { data: acts } = await db.from("lead_activities")
        .select("type,title,outcome,created_at")
        .eq("lead_id", opp.lead_id)
        .order("created_at", { ascending: false }).limit(15);
      data.activities = acts || [];
    }
  }

  if (feature === "follow_up_draft" && contextId) {
    const { data: lead } = await db.from("leads")
      .select("full_name,phone,whatsapp,email,status,source,destination,budget,travel_type,next_follow_up,language")
      .eq("id", contextId).single();
    data.lead = lead;

    const { data: acts } = await db.from("lead_activities")
      .select("type,title,body,outcome,created_at")
      .eq("lead_id", contextId)
      .order("created_at", { ascending: false }).limit(10);
    data.recent_activities = acts || [];

    const { data: latestQuote } = await db.from("quotations")
      .select("quote_number,title,status,total_amount,validity_date")
      .eq("lead_id", contextId)
      .order("created_at", { ascending: false }).limit(1).single();
    data.latest_quote = latestQuote || null;
  }

  if (feature === "itinerary_draft" || feature === "itinerary_suggest") {
    const dest = extra.destination || "";
    const { data: catalog } = await db.from("service_catalog")
      .select("name_ar,name_en,category,destination,base_cost,currency")
      .ilike("destination", `%${dest}%`).limit(40);
    data.catalog_items = catalog || [];
  }

  if (feature === "itinerary_improve" && contextId) {
    const { data: itn } = await db.from("itineraries")
      .select("id,title_ar,title_en,total_sell_price,currency,status")
      .eq("id", contextId).single();
    data.itinerary = itn;

    const { data: days } = await db.from("itinerary_days")
      .select("day_number,title_ar,date,city, itinerary_items(id,name_ar,category,time_start,sell_price)")
      .eq("itinerary_id", contextId).order("day_number");
    data.days = days || [];
  }

  if (feature === "quote_review" && contextId) {
    const { data: quote } = await db.from("quotations")
      .select("id,quote_number,title,total_amount,cost_total,margin_pct,currency,status,validity_date,notes")
      .eq("id", contextId).single();
    data.quotation = quote;

    const { data: items } = await db.from("quotation_items")
      .select("category,name_ar,quantity,unit_price,cost_price,sell_price")
      .eq("quotation_id", contextId);
    data.items = items || [];

    const { data: margins } = await db.from("margin_settings")
      .select("scope,min_margin_pct,target_margin_pct,warn_below_pct").limit(10);
    data.margin_settings = margins || [];
  }

  if (feature === "operations_brief") {
    const today = new Date().toISOString().slice(0, 10);
    const in7   = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);

    const { data: bookings } = await db.from("bookings")
      .select("booking_number,customer_name,status,adults_count,visa_status,tickets_status")
      .gte("package_departure", today).lte("package_departure", in7)
      .neq("status", "cancelled").order("package_departure").limit(30);
    data.upcoming_bookings = bookings || [];

    const { data: pendingTasks } = await db.from("tasks")
      .select("title,due_at,priority,status")
      .in("status", ["pending", "in_progress"]).lte("due_at", in7).order("due_at").limit(20);
    data.overdue_tasks = pendingTasks || [];

    const { data: overdueLeads } = await db.from("leads")
      .select("full_name,status,next_follow_up,priority")
      .lt("next_follow_up", new Date().toISOString())
      .not("status", "in", '("won","lost","unqualified")')
      .order("next_follow_up").limit(15);
    data.overdue_follow_ups = overdueLeads || [];
  }

  if (feature === "supplier_score" && contextId) {
    const { data: supplier } = await db.from("suppliers")
      .select("id,name_ar,type,currency,is_active,payment_terms")
      .eq("id", contextId).single();
    data.supplier = supplier;

    const { data: bills } = await db.from("supplier_bills")
      .select("total_amount,paid_amount,status,created_at")
      .eq("supplier_id", contextId)
      .order("created_at", { ascending: false }).limit(50);
    data.bills = bills || [];

    const { data: costs } = await db.from("booking_costs")
      .select("amount,type,created_at")
      .eq("supplier_id", contextId)
      .order("created_at", { ascending: false }).limit(50);
    data.booking_costs = costs || [];

    const { data: rates } = await db.from("supplier_rates")
      .select("service_category,rate_type,cost_amount,currency,valid_from,valid_to,is_active")
      .eq("supplier_id", contextId).limit(20);
    data.rates = rates || [];
  }

  if (feature === "command_center") {
    const { data: summary } = await db.rpc("get_crm_summary").single();
    data.crm_summary = summary;
    const { data: qSummary } = await db.rpc("get_quotation_summary").single();
    data.quotation_summary = qSummary;
  }

  if (feature === "recommendations") {
    const { data: newLeads } = await db.from("leads")
      .select("id,full_name,status,priority,next_follow_up,created_at,source")
      .in("status", ["new", "contacted"])
      .order("created_at", { ascending: false }).limit(20);
    data.new_leads = newLeads || [];

    const { data: atRiskOpps } = await db.from("opportunities")
      .select("id,title,stage,value,probability,expected_close,updated_at")
      .not("stage", "in", '("won","lost")')
      .lte("expected_close", new Date(Date.now() + 14 * 86400000).toISOString().slice(0, 10))
      .order("expected_close").limit(15);
    data.at_risk_opportunities = atRiskOpps || [];

    const { data: stalledQuotes } = await db.from("quotations")
      .select("id,quote_number,title,status,total_amount,margin_pct,updated_at")
      .in("status", ["sent", "viewed", "negotiation"])
      .lt("updated_at", new Date(Date.now() - 5 * 86400000).toISOString())
      .order("updated_at").limit(10);
    data.stalled_quotes = stalledQuotes || [];
  }

  return data;
}

// ─── Prompt builder (from root/index.ts — complete Arabic prompts) ────────────
function buildPrompt(feature: string, data: any, extra: any, history: any[]) {
  const SYSTEM_BASE = `أنت مساعد ذكاء اصطناعي متخصص في شركة سياحة ودي إم سي (DMC).
تحليلاتك مبنية على بيانات النظام الفعلية فقط.
لا تخترع بيانات أو أسعاراً أو تواريخ أو أحداثاً.
إذا كانت البيانات غير كافية، وضّح ذلك صراحةً.
أجب باللغة العربية دائماً.
استخدم تنسيق Markdown للوضوح.
كن موجزاً وعملياً.`;

  let userMessage = "";

  switch (feature) {
    case "lead_analysis": {
      const l = data.lead || {};
      userMessage = `## تحليل العميل المحتمل\n\n**البيانات:**\n${JSON.stringify({
        الاسم: l.full_name, الحالة: l.status, المصدر: l.source,
        الأولوية: l.priority, الوجهة: l.destination, الميزانية: l.budget,
        نوع_السفر: l.travel_type, عدد_الأشخاص: (l.pax_adults||0)+(l.pax_children||0),
        تاريخ_الإنشاء: l.created_at, آخر_تواصل: l.last_contacted, المتابعة_القادمة: l.next_follow_up,
      }, null, 2)}\n\n**نشاطات أخيرة:** ${(data.activities||[]).slice(0,5).map((a:any)=>`[${a.type}] ${a.title}: ${a.outcome||'—'}`).join(' | ') || 'لا يوجد'}\n**مهام معلقة:** ${data.tasks?.length||0} | **فرص:** ${data.opportunities?.length||0}\n\nأجب: 1-ملخص العميل 2-إشارات الاهتمام 3-عوامل الخطر 4-الإجراء التالي 5-توقيت المتابعة 6-مستوى الثقة`;
      break;
    }
    case "opportunity_analysis":
    case "opp_analysis": {
      const o = data.opportunity || {};
      userMessage = `## تحليل الفرصة البيعية\n\n${JSON.stringify({ العنوان:o.title, المرحلة:o.stage, القيمة:o.value, الاحتمالية:o.probability+'%', تاريخ_الإغلاق:o.expected_close, الوجهة:o.destination },null,2)}\n\n**عروض أسعار:** ${(data.quotations||[]).map((q:any)=>`${q.quote_number}: ${q.status} | ${q.total_amount} | هامش ${q.margin_pct}%`).join(' | ')||'لا يوجد'}\n**نشاطات:** ${data.activities?.length||0}\n\nأجب: 1-صحة الصفقة 2-عوامل الخطر 3-ما ينقص 4-الإجراء التالي 5-فرص البيع الإضافي`;
      break;
    }
    case "follow_up_draft": {
      const l = data.lead || {};
      const channel = extra.channel || "whatsapp";
      userMessage = `## صياغة رسالة متابعة\n\nالعميل: ${l.full_name} | الوجهة: ${l.destination||'—'} | الميزانية: ${l.budget||'—'}\nآخر نشاط: ${data.recent_activities?.[0] ? `[${data.recent_activities[0].type}] ${data.recent_activities[0].title}` : 'لا يوجد'}\nآخر عرض: ${data.latest_quote ? `${data.latest_quote.quote_number} (${data.latest_quote.status})` : 'لا يوجد'}\n\nالقناة: ${channel === 'whatsapp' ? 'واتساب (مختصر، غير رسمي)' : 'بريد إلكتروني (رسمي)'}\nاكتب رسالة جاهزة للإرسال. لا تخترع تفاصيل. ضع [الاسم] للاسم.`;
      break;
    }
    case "itinerary_draft":
    case "itinerary_suggest": {
      const { destination, days, pax_adults, budget, travel_style, notes, nights, travelers } = extra;
      userMessage = `## توليد مسودة جدول سياحي\n\nالوجهة: ${destination||'—'} | الأيام: ${days||nights||'—'} | الأشخاص: ${pax_adults||travelers||1}\nالميزانية: ${budget||'غير محددة'} | النمط: ${travel_style||'عام'}\nملاحظات: ${notes||'—'}\n\nالكتالوج (${data.catalog_items?.length||0} عنصر): ${(data.catalog_items||[]).slice(0,15).map((c:any)=>`[${c.category}] ${c.name_ar}`).join(' | ')||'—'}\n\nأنشئ جدولاً يوم بيوم (صباح/ظهر/مساء) + فندق + تنقل. هذه مسودة للمراجعة.`;
      break;
    }
    case "itinerary_improve": {
      const itn = data.itinerary || {};
      userMessage = `## مراجعة الجدول السياحي\n\n${itn.title_ar||'—'} | ${data.days?.length||0} أيام\n${(data.days||[]).map((d:any)=>`اليوم ${d.day_number}: ${d.title_ar||'—'} — ${(d.itinerary_items||[]).map((i:any)=>i.name_ar).join('، ')}`).join('\n')}\n\nأجب: 1-تقييم 2-تعارضات 3-جوانب مفقودة 4-اقتراحات تحسين 5-فرص بيع إضافي`;
      break;
    }
    case "quote_review": {
      const q = data.quotation || {};
      const margins = data.margin_settings || [];
      const minM = margins.find((m:any)=>m.scope==='general')?.min_margin_pct || 15;
      const tgtM = margins.find((m:any)=>m.scope==='general')?.target_margin_pct || 25;
      userMessage = `## مراجعة عرض السعر\n\n${q.quote_number||'—'}: ${q.total_amount} ${q.currency} | تكلفة: ${q.cost_total} | هامش: ${q.margin_pct}% (هدف: ${tgtM}%, حد أدنى: ${minM}%)\nالحالة: ${q.status} | الصلاحية: ${q.validity_date} | البنود: ${data.items?.length||0}\n\nبنود: ${(data.items||[]).slice(0,10).map((i:any)=>`[${i.category}] ${i.name_ar}: ${i.sell_price||0}`).join(' | ')||'—'}\n\nأجب: 1-حالة الهامش 2-بنود مفقودة 3-مخاطر التسعير 4-فرص بيع إضافي 5-الخطوة التالية`;
      break;
    }
    case "operations_brief": {
      const bookings = data.upcoming_bookings || [];
      const tasks    = data.overdue_tasks     || [];
      const leads    = data.overdue_follow_ups || [];
      userMessage = `## موجز العمليات — ${new Date().toLocaleDateString("ar-EG")}\n\nحجوزات قادمة (${bookings.length}): ${bookings.slice(0,8).map((b:any)=>`${b.booking_number}/${b.customer_name} تأشيرة:${b.visa_status||'—'}`).join(' | ')||'لا يوجد'}\nمهام متأخرة (${tasks.length}): ${tasks.slice(0,6).map((t:any)=>`[${t.priority}] ${t.title}`).join(' | ')||'لا يوجد'}\nمتابعات متأخرة (${leads.length}): ${leads.slice(0,6).map((l:any)=>l.full_name).join('، ')||'لا يوجد'}\n\nأجب: 1-ملخص تنفيذي 2-المخاطر العالية 3-أهم 3 إجراءات`;
      break;
    }
    case "supplier_score": {
      const s = data.supplier || {};
      const bills = data.bills || [];
      const totalBilled = bills.reduce((sum:number,b:any)=>sum+(b.total_amount||0),0);
      userMessage = `## تقييم المورد\n\n${s.name_ar||'—'} | النوع: ${s.type} | العملة: ${s.currency}\nفواتير: ${bills.length} | إجمالي: ${totalBilled} | تكاليف حجوزات: ${data.booking_costs?.length||0}\nأسعار متعاقد عليها: ${data.rates?.length||0}\n${bills.length < 5 ? '⚠️ بيانات قليلة' : ''}\n\nأجب: 1-درجة الموثوقية 2-نقاط القوة 3-نقاط الضعف 4-توصية الاستخدام`;
      break;
    }
    case "command_center": {
      const question = extra.question || "";
      userMessage = `## سؤال المستخدم\n\nبيانات CRM: ${JSON.stringify(data.crm_summary||{})}\nعروض أسعار: ${JSON.stringify(data.quotation_summary||{})}\n\nالسؤال: ${question}\n\nأجب من البيانات فقط. إذا غير كافية، وضّح.`;
      break;
    }
    case "recommendations": {
      const newLeads = data.new_leads || [];
      const opps     = data.at_risk_opportunities || [];
      const quotes   = data.stalled_quotes || [];
      userMessage = `## توليد توصيات ذكية\n\nلدز جدد (${newLeads.length}): ${newLeads.slice(0,5).map((l:any)=>`${l.full_name}[${l.priority}]`).join('، ')||'—'}\nفرص معرضة للخطر (${opps.length}): ${opps.slice(0,5).map((o:any)=>`${o.title}:${o.stage}`).join('، ')||'—'}\nعروض متوقفة (${quotes.length}): ${quotes.slice(0,4).map((q:any)=>`${q.quote_number}:${q.status}`).join('، ')||'—'}\n\nأجب JSON فقط بدون markdown:\n{"recommendations":[{"type":"lead_priority|opp_risk|quote_followup","priority":"high|medium|low","title":"...","body":"...","confidence":"high|medium|low|insufficient_data","action":{"type":"open_lead|open_opp|open_quote","id":"...","label":"..."}}]}\nأقصى 6 توصيات. فقط ما تدعمه البيانات.`;
      break;
    }
    default:
      userMessage = extra.question || "مساعدة عامة";
  }

  return { system: SYSTEM_BASE, userMessage };
}

// ─── AI provider call ─────────────────────────────────────────────────────────
async function callAI(
  system: string, userMessage: string,
  history: { role: string; content: string }[], model: string
): Promise<{ content: string; usage?: any }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    if (AI_PROVIDER === "anthropic") {
      return await callAnthropic(system, userMessage, history, model, controller);
    } else if (AI_PROVIDER === "openai") {
      return await callOpenAI(system, userMessage, history, model, controller);
    } else if (AI_PROVIDER === "demo") {
      return await callDemo(system, userMessage, history, model, controller);
    } else {
      // Explicit rejection prevents unknown AI_PROVIDER from silently
      // consuming Anthropic credits or producing unexpected behavior.
      throw new Error(`Unsupported AI_PROVIDER: "${AI_PROVIDER}" — must be anthropic | openai | demo`);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function callAnthropic(system: string, userMsg: string, history: any[], model: string, ctrl: AbortController) {
  if (!ANTHROPIC_KEY) throw new Error("ANTHROPIC_API_KEY not configured");
  const messages = [
    ...history.map((m: any) => ({ role: m.role, content: m.content })),
    { role: "user", content: userMsg },
  ];
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({ model, max_tokens: MAX_TOKENS, system, messages }),
    signal: ctrl.signal,
  });
  if (!res.ok) throw new Error(`Anthropic ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const d = await res.json();
  return { content: d.content?.[0]?.text || "", usage: d.usage };
}

async function callOpenAI(system: string, userMsg: string, history: any[], model: string, ctrl: AbortController) {
  if (!OPENAI_KEY) throw new Error("OPENAI_API_KEY not configured");
  const oaiModel = model.startsWith("claude") ? "gpt-4o-mini" : model;
  const messages = [
    { role: "system", content: system },
    ...history.map((m: any) => ({ role: m.role, content: m.content })),
    { role: "user", content: userMsg },
  ];
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${OPENAI_KEY}` },
    body: JSON.stringify({ model: oaiModel, messages, max_tokens: MAX_TOKENS }),
    signal: ctrl.signal,
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const d = await res.json();
  return { content: d.choices?.[0]?.message?.content || "", usage: d.usage };
}

// ─── Demo provider — OpenAI-compatible free-tier API (Phase 16.3) ────────────
// Default target: Groq (https://console.groq.com) — free tier, fast inference.
// Any OpenAI-compatible endpoint can be substituted via DEMO_API_BASE_URL.
// DEMO_API_KEY is required (set in Supabase secrets — never in frontend).
// Responses are normalized to the same { content, usage } shape as other providers.
async function callDemo(system: string, userMsg: string, history: any[], model: string, ctrl: AbortController) {
  if (!DEMO_KEY) throw new Error("DEMO_API_KEY not configured — set it in Supabase secrets to use the demo provider");
  const messages = [
    { role: "system", content: system },
    ...history.map((m: any) => ({ role: m.role, content: m.content })),
    { role: "user", content: userMsg },
  ];
  const res = await fetch(`${DEMO_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${DEMO_KEY}`,
    },
    body: JSON.stringify({ model, messages, max_tokens: MAX_TOKENS }),
    signal: ctrl.signal,
  });
  if (!res.ok) {
    const errText = (await res.text()).slice(0, 200);
    throw new Error(`Demo provider (${DEMO_BASE_URL}) ${res.status}: ${errText}`);
  }
  const d = await res.json();
  return {
    content: d.choices?.[0]?.message?.content || "",
    usage: d.usage,  // OpenAI-compatible usage: { prompt_tokens, completion_tokens }
  };
}

function respond(status: number, body: any, corsHeaders: Record<string, string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
