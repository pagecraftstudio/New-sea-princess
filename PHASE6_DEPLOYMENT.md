# Phase 6 — AI & Intelligence — Deployment Guide

## Status: COMPLETE

---

## What Was Built (Phase 6)

### Previously Implemented (found in repo)
- `js/ai-service.js` — Client-side AI service (invoke, createChat, feedback, AIPanel UI builder)
- `nsp-control-8x4k/ai-dashboard.html` — AI Dashboard with recommendations + daily brief + command center UI
- `nsp-control-8x4k/supplier-intelligence.html` — Supplier analysis page with AI analysis button
- `supabase/migrations/202601030000000_ai_foundation.sql` — DB tables: ai_conversations, ai_requests, ai_recommendations, ai_insights_cache
- AI panels on `lead-detail.html` (lead_analysis, follow_up_draft buttons)

### Added by Phase 6 Completion
- `supabase/functions/ai-assistant/index.ts` — **The missing edge function** (the brain)
- `nsp-control-8x4k/ai-command-center.html` — Standalone AI Command Center page
- `supabase/migrations/202601031000000_ai_phase6_complete.sql` — Helpers, views, extended constraints
- `js/admin-nav.js` — Updated with Command Center link in AI section

---

## Deployment Steps

### Step 1: Apply database migration

```sql
-- Run in Supabase SQL Editor:
-- File: supabase/migrations/202601031000000_ai_phase6_complete.sql
```

### Step 2: Set Anthropic API Key secret

```bash
# In Supabase Dashboard → Edge Functions → Secrets, add:
ANTHROPIC_API_KEY = sk-ant-...your-key...

# Or via CLI:
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

### Step 3: Deploy the edge function

```bash
supabase functions deploy ai-assistant
```

### Step 4: Copy new files to project

```
supabase/functions/ai-assistant/index.ts  →  project root
nsp-control-8x4k/ai-command-center.html  →  project root
js/admin-nav.js                           →  project root (updated)
supabase/migrations/202601031000000_...   →  project migrations/
```

---

## AI Features Available

| Feature | Trigger | Description |
|---|---|---|
| Lead Analysis | Lead detail page → "تحليل ذكي" | Analyzes lead intent, signals, conversion probability |
| Follow-up Draft | Lead detail → "متابعة واتساب/بريد" | Drafts context-aware follow-up message |
| Opportunity Analysis | Opportunities page (add button) | Deal health, risks, next actions |
| Supplier Scoring | Supplier Intelligence page | Performance assessment from real billing data |
| Operations Brief | AI Dashboard → "توليد" | Daily operational summary |
| Smart Recommendations | AI Dashboard → "تحديث التوصيات" | 3-6 prioritized business recommendations |
| Command Center | ai-command-center.html (new) | Natural language Q&A about the business |

---

## AI Features NOT included (future phases)

- Itinerary auto-generation (Phase 7 candidate) — requires sufficient service catalog data
- Revenue forecasting ML model — requires 6+ months booking history
- WhatsApp integration — requires approved WhatsApp Business API
- Automated email sending from AI suggestions — requires explicit confirmation workflow

---

## Security Model

- JWT validated on every edge function request
- Admin check: only `admin_users` table members can access AI
- Service role used internally to fetch data; anon key never used for data
- AI responses generated from DB data only — no external URLs or fabrication
- `ANTHROPIC_API_KEY` stored as Supabase secret — never sent to frontend
- AI audit logging: every request logged to `ai_requests` table

---

## Environment Variables

| Variable | Where | Required |
|---|---|---|
| `ANTHROPIC_API_KEY` | Supabase Edge Function Secret | YES |
| `SUPABASE_URL` | Auto-injected by Supabase | YES |
| `SUPABASE_SERVICE_ROLE_KEY` | Auto-injected by Supabase | YES |
| `SUPABASE_ANON_KEY` | Auto-injected by Supabase | YES |

---

## Empty/Low Data Handling

The AI edge function and prompts explicitly instruct Claude to:
- Say "بيانات غير كافية" when data is insufficient
- Not fabricate scores when fewer than 3 supplier bills exist
- Not invent customer history not in the database
- Not produce false forecasts when no historical data exists

---

## Phase 1–5 Regression Check

All Phase 6 additions are purely additive:
- No existing tables modified destructively
- No existing JS files modified (only admin-nav.js — additive link)
- Edge function is a new isolated Deno function
- Migration 202601031 only adds constraints, views, and functions — no data changes

✅ Phase 1 CRM: Unaffected
✅ Phase 2 Quotations: Unaffected  
✅ Phase 3 B2B: Unaffected
✅ Phase 4 Operations: Unaffected
✅ Phase 5 Growth: Unaffected

---

## Known Limitations

1. **Model**: Uses `claude-sonnet-4-6` — can be changed in edge function `callClaude()`
2. **Language**: Defaults to Arabic — user can ask in English and it responds accordingly
3. **Rate**: No rate limiting on AI requests beyond Anthropic's own limits (add pg_cron cleanup for `ai_requests` if volume is high)
4. **Caching**: `ai_insights_cache` table exists but cache-write logic not yet used — each request hits Anthropic directly
5. **Itinerary builder integration**: AI panel buttons on itinerary-builder.html not yet wired — add `window.AIPanel.mount()` following the same pattern as lead-detail.html

---

## Testing Checklist

- [ ] Supabase secret `ANTHROPIC_API_KEY` set
- [ ] `supabase functions deploy ai-assistant` succeeded
- [ ] Migration 202601031 applied
- [ ] ai-dashboard.html loads without JS errors
- [ ] "تحديث التوصيات" button returns recommendations (not HTTP error)
- [ ] "توليد الموجز" button returns operations brief
- [ ] ai-command-center.html loads and responds to questions
- [ ] Lead detail "تحليل ذكي" works
- [ ] Supplier intelligence "تحليل ذكي" works
- [ ] Feedback buttons (thumbs up/down) save to ai_recommendations
- [ ] ai_requests table has rows after tests
- [ ] Admin user without admin_users entry gets 403 (not 200)
- [ ] Logout → API call → 401 (not 200)
