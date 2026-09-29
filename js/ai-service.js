/**
 * js/ai-service.js
 * Phase 6 — Client-side AI Service
 *
 * Reusable module for all admin pages.
 * Handles: invoking the edge function, loading states, error states,
 *          conversation history, feedback, and caching.
 *
 * Usage:
 *   await window.AI.analyze('lead_analysis', leadId, { context_type: 'lead' });
 *   await window.AI.chat('command_center', null, { question: 'أي عملاء يحتاجون متابعة؟' });
 */

(function () {
  'use strict';

  // ─── Core invoke ─────────────────────────────────────────────────────────
  async function invoke(feature, contextId, extraData = {}, conversationHistory = []) {
    if (!window.db) throw new Error('Supabase not initialized');

    const { data: { session } } = await window.db.auth.getSession();
    if (!session) throw new Error('Not authenticated');

    const body = {
      feature,
      context_id: contextId || null,
      context_type: extraData.context_type || null,
      data: extraData,
      history: conversationHistory,
    };

    // Call edge function with auth header
    const SUPABASE_URL = window.SUPABASE_URL || (window.db?.supabaseUrl);
    const res = await fetch(`${SUPABASE_URL}/functions/v1/ai-assistant`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
        'apikey': window.SUPABASE_ANON_KEY,
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      const err = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
      throw new Error(err.error || `AI request failed: ${res.status}`);
    }

    const data = await res.json();
    return data.result || '';
  }

  // ─── Public API ──────────────────────────────────────────────────────────
  window.AI = {
    // Single-shot analysis
    analyze: (feature, contextId, extraData) => invoke(feature, contextId, extraData),

    // Multi-turn chat (manages history internally)
    createChat(feature, contextId, extraData) {
      const history = [];
      return {
        async send(userMessage) {
          history.push({ role: 'user', content: userMessage });
          const reply = await invoke(feature, contextId, { ...extraData, question: userMessage }, history);
          history.push({ role: 'assistant', content: reply });
          return reply;
        },
        getHistory: () => [...history],
        reset: () => { history.length = 0; },
      };
    },

    // Save feedback on a recommendation (feedback and status are independent — H6 fix)
    async feedback(recommendationId, fb) {
      // Only update the feedback field. Never auto-set status based on feedback value.
      // 'helpful' means the user found it useful — not that they acted on it.
      await window.db.from('ai_recommendations')
        .update({ feedback: fb, updated_at: new Date().toISOString() })
        .eq('id', recommendationId);
    },

    // Mark recommendation as applied
    async applyRecommendation(recommendationId) {
      await window.db.from('ai_recommendations')
        .update({ status: 'applied' }).eq('id', recommendationId);
    },
  };

  // ─── UI Builder helpers (used by all AI panels) ──────────────────────────
  window.AIPanel = {

    /**
     * Render an AI panel inside a container element.
     * container: DOM element
     * feature: AI feature key
     * contextId: UUID or null
     * extraData: object
     * options: { label, icon, autoRun }
     */
    mount(container, feature, contextId, extraData = {}, options = {}) {
      const label = options.label || 'تحليل ذكي';
      const icon  = options.icon  || 'fa-microchip-ai';
      const panelId = `ai-panel-${Math.random().toString(36).slice(2)}`;

      container.innerHTML = `
        <div id="${panelId}" class="ai-panel border border-purple-200 rounded-xl bg-gradient-to-br from-purple-50 to-white overflow-hidden">
          <div class="flex items-center justify-between px-4 py-3 bg-purple-50 border-b border-purple-100">
            <div class="flex items-center gap-2 text-purple-700 font-semibold text-sm">
              <i class="fa-solid ${icon}"></i>
              ${label}
            </div>
            <button class="ai-run-btn inline-flex items-center gap-1.5 bg-purple-600 text-white text-xs px-3 py-1.5 rounded-lg hover:bg-purple-700 transition-colors font-medium">
              <i class="fa-solid fa-sparkles text-xs"></i>
              تشغيل التحليل
            </button>
          </div>
          <div class="ai-panel-body p-4 text-sm text-gray-700 min-h-16">
            <div class="ai-idle text-gray-400 italic text-center py-4">اضغط لتشغيل التحليل الذكي</div>
            <div class="ai-loading hidden text-center py-6">
              <div class="inline-flex items-center gap-2 text-purple-600">
                <i class="fa-solid fa-spinner fa-spin"></i>
                جاري التحليل…
              </div>
            </div>
            <div class="ai-result hidden prose prose-sm max-w-none"></div>
            <div class="ai-error hidden text-red-500 py-3 text-center"></div>
          </div>
          <div class="ai-feedback hidden flex items-center justify-between px-4 py-2 border-t border-purple-100 bg-purple-50/50">
            <span class="text-xs text-gray-500">هل كان التحليل مفيداً؟</span>
            <div class="flex gap-2">
              <button class="ai-fb-yes text-xs text-green-600 hover:text-green-800 flex items-center gap-1">
                <i class="fa-solid fa-thumbs-up"></i> مفيد
              </button>
              <button class="ai-fb-no text-xs text-red-500 hover:text-red-700 flex items-center gap-1">
                <i class="fa-solid fa-thumbs-down"></i> غير مفيد
              </button>
            </div>
          </div>
        </div>`;

      const panel      = container.querySelector(`#${panelId}`);
      const runBtn     = panel.querySelector('.ai-run-btn');
      const idleEl     = panel.querySelector('.ai-idle');
      const loadingEl  = panel.querySelector('.ai-loading');
      const resultEl   = panel.querySelector('.ai-result');
      const errorEl    = panel.querySelector('.ai-error');
      const feedbackEl = panel.querySelector('.ai-feedback');

      let lastRecId = null;

      async function run() {
        idleEl.classList.add('hidden');
        loadingEl.classList.remove('hidden');
        resultEl.classList.add('hidden');
        errorEl.classList.add('hidden');
        feedbackEl.classList.add('hidden');
        runBtn.disabled = true;

        try {
          const result = await window.AI.analyze(feature, contextId, extraData);
          loadingEl.classList.add('hidden');
          resultEl.innerHTML = window.AIPanel.renderMarkdown(result);
          resultEl.classList.remove('hidden');
          feedbackEl.classList.remove('hidden');

          // Save recommendation to DB
          try {
            const { data: { session } } = await window.db.auth.getSession();
            const { data: rec } = await window.db.from('ai_recommendations').insert({
              user_id: session?.user?.id,
              rec_type: feature,
              context_type: extraData.context_type,
              context_id: contextId,
              title: label,
              body: result,
              confidence: 'medium',
              status: 'active',
            }).select('id').single();
            if (rec) lastRecId = rec.id;
          } catch (_) { /* non-critical */ }

        } catch (err) {
          loadingEl.classList.add('hidden');
          errorEl.textContent = 'خطأ: ' + (err.message || 'فشل الطلب');
          errorEl.classList.remove('hidden');
        }

        runBtn.disabled = false;
      }

      runBtn.addEventListener('click', run);

      // Feedback
      panel.querySelector('.ai-fb-yes')?.addEventListener('click', async () => {
        if (lastRecId) await window.AI.feedback(lastRecId, 'helpful');
        feedbackEl.innerHTML = '<span class="text-xs text-green-600"><i class="fa-solid fa-check mr-1"></i>شكراً!</span>';
      });
      panel.querySelector('.ai-fb-no')?.addEventListener('click', async () => {
        if (lastRecId) await window.AI.feedback(lastRecId, 'not_helpful');
        feedbackEl.innerHTML = '<span class="text-xs text-gray-400">تم حفظ رأيك</span>';
      });

      if (options.autoRun) run();

      return { run };
    },

    // Very simple Markdown → HTML (no external lib needed)
    renderMarkdown(md) {
      if (!md) return '';
      return md
        .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
        .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
        .replace(/\*(.+?)\*/g, '<em>$1</em>')
        .replace(/^### (.+)$/gm, '<h4 class="font-bold text-gray-800 mt-3 mb-1">$1</h4>')
        .replace(/^## (.+)$/gm,  '<h3 class="font-bold text-purple-800 mt-4 mb-2 text-base">$1</h3>')
        .replace(/^# (.+)$/gm,   '<h2 class="font-bold text-purple-900 mt-4 mb-2 text-lg">$1</h2>')
        .replace(/^- (.+)$/gm,   '<li class="mr-4 list-disc">$1</li>')
        .replace(/(<li[\s\S]+?<\/li>)/g, '<ul class="space-y-1 my-2">$1</ul>')
        .replace(/\n\n/g, '<br/><br/>')
        .replace(/\n/g, '<br/>');
    },
  };

})();
