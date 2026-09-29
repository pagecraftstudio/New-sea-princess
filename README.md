# Flow Travel & Tourism — DMC Operating System

**Travel Management & DMC Operating System** — Phase 16.1 Release Hardening Complete

---

## Quick Start

```bash
# Link to Supabase project
supabase link --project-ref <your-project-ref>

# Apply all migrations
supabase db push

# Deploy edge functions
supabase functions deploy verify-recaptcha
supabase functions deploy send-booking-email
supabase functions deploy send-communication
supabase functions deploy ai-assistant

# Set required secrets
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase secrets set RESEND_API_KEY=re_...
supabase secrets set RECAPTCHA_SECRET_KEY=...
supabase secrets set SITE_URL=https://your-domain.com
supabase secrets set ALLOWED_ORIGINS=https://your-domain.com
```

---

## Architecture

| Layer | Technology |
|---|---|
| Frontend | Static HTML + Vanilla JS + Tailwind CSS (CDN) |
| Backend | Supabase (PostgreSQL 15, RLS, Auth, Storage) |
| Edge Functions | Deno/TypeScript on Supabase |
| Deployment | Vercel static hosting |
| Design | RTL Arabic-first, Cairo font, erp-ui.css |
| Charts | Chart.js 4.4.0 |
| Auth | Supabase Auth + admin_users table |

**Admin panel:** `/nsp-control-8x4k/` (62 pages)  
**Partner portal:** `/partner-portal/`  
**Public site:** `/`

---

## Edge Functions

| Function | Purpose | Required Secret |
|---|---|---|
| `verify-recaptcha` | Google reCAPTCHA v2 verification | `RECAPTCHA_SECRET_KEY` |
| `send-booking-email` | Booking confirmation via Resend | `RESEND_API_KEY` |
| `send-communication` | Trip/traveler communications | `RESEND_API_KEY` |
| `ai-assistant` | All AI features (analysis, drafts, command center) | `ANTHROPIC_API_KEY` |

### AI features (ai-assistant)

| Feature | Model tier |
|---|---|
| `lead_analysis` | Smart |
| `opportunity_analysis` | Smart |
| `follow_up_draft` | Fast |
| `itinerary_draft` | Smart |
| `itinerary_improve` | Smart |
| `quote_review` | Smart |
| `operations_brief` | Fast |
| `supplier_score` | Smart |
| `command_center` | Smart |
| `recommendations` | Fast |

Models configured via Supabase secrets:
```
AI_PROVIDER=anthropic          # or 'openai' or 'demo'
AI_MODEL_FAST=claude-haiku-4-5-20251001
AI_MODEL_SMART=claude-sonnet-4-6
```

### Demo / Free-Tier Provider (Phase 16.3)

For development and demo environments without a paid Anthropic/OpenAI account:

```
AI_PROVIDER=demo
DEMO_API_KEY=gsk_...           # Get a free key at https://console.groq.com
DEMO_API_BASE_URL=https://api.groq.com/openai/v1   # default; any OpenAI-compatible endpoint
DEMO_MODEL_FAST=llama-3.1-8b-instant               # default
DEMO_MODEL_SMART=llama-3.3-70b-versatile           # default
```

**Demo provider notes:**
- Default target: [Groq](https://console.groq.com) — offers a free-tier API key
- Free tier has rate limits; not suitable for production traffic
- `DEMO_API_KEY` must be set as a Supabase secret — **never in frontend code**
- Provider is logged in `ai_requests.provider` for full audit trail
- Switching providers does not affect permissions, rate limiting, caching, or CORS
- Missing `DEMO_API_KEY` returns a clear error — does not silently fall back to Anthropic/OpenAI

---

## Database

58 migrations under `supabase/migrations/`. See `PRODUCTION_READINESS.md` for full sequence.

**Tables:** 40+ tables covering CRM, Quotations, Itineraries, Operations, Finance, AI, Groups/MICE  
**Triggers:** 30+ auto-accounting, auto-numbering, immutability guards  
**RLS:** Enabled on every table  
**Views:** general_ledger, trial_balance, booking_profitability, ar_aging, ap_aging, customer_ledger, supplier_ledger  

---

## Environment Variables

### Supabase Edge Function Secrets

| Variable | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | AI features | sk-ant-... |
| `RESEND_API_KEY` | Email sending | re_... |
| `RECAPTCHA_SECRET_KEY` | Public booking form | From Google reCAPTCHA console |
| `SITE_URL` | Email links | No trailing slash |
| `ALLOWED_ORIGINS` | CORS | **Not wildcard in production** |

Auto-injected by Supabase (no action needed):
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

---

## Security

- RLS on all tables
- All sensitive RPCs use internal `is_any_admin()` / `has_permission()` guards
- EXECUTE grants: `REVOKE FROM PUBLIC`, explicit `GRANT TO authenticated`
- `accounting_audit_logs` — write-only via triggers (tamper-resistant)
- Immutability triggers on posted expenses, approved credit notes, approved refunds
- Service role key never in frontend
- Security headers: `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` (via vercel.json)
- `.sql` and `.md` routes blocked in production (vercel.json)

---

## Roles

9 roles in `admin_users.role`:

| Role | Arabic | Financial Write | Booking Write |
|---|---|---|---|
| `super_admin` | مدير عام | ✅ | ✅ |
| `financial_manager` | مدير مالي | ✅ | Read |
| `accountant` | محاسب | ✅ | Read |
| `cashier` | أمين صندوق | Payments | Read |
| `sales_agent` | موظف مبيعات | ❌ | ✅ |
| `booking_agent` | موظف حجوزات | ❌ | ✅ |
| `auditor` | مراجع حسابات | Read | Read |
| `admin` | مشرف | ✅ | ✅ |
| `viewer` | مشاهد | ❌ | ❌ |

---

## Production Status

See `PRODUCTION_READINESS.md` for full Phase 16.1 hardening report.

**Verdict:** 🟡 PRODUCTION READY — CONDITIONAL (pending deployment environment setup)
