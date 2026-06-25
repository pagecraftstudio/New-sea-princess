/**
 * analytics.js
 * Funnel event tracking for New Sea Princess.
 * Fire-and-forget: errors are silently swallowed so tracking never breaks UX.
 */
(function () {
  const SESSION_KEY = 'nsp_session_id';

  function getSessionId() {
    let id = sessionStorage.getItem(SESSION_KEY);
    if (!id) {
      id = (typeof crypto !== 'undefined' && crypto.randomUUID)
        ? crypto.randomUUID()
        : Date.now().toString(36) + Math.random().toString(36).slice(2);
      sessionStorage.setItem(SESSION_KEY, id);
    }
    return id;
  }

  /**
   * trackEvent(type, extra?)
   * @param {'page_view'|'package_view'|'booking_start'|'booking_step'|'booking_complete'|'booking_abandon'} type
   * @param {object} [extra]  - package_id, package_title, step_number, user_id
   */
  window.trackEvent = async function (type, extra = {}) {
    if (!window.db) return;
    try {
      // Resolve logged-in user non-blocking
      let userId = null;
      try {
        const { data: { session } } = await window.db.auth.getSession();
        userId = session?.user?.id || null;
      } catch (_) {}

      await window.db.from('page_events').insert({
        event_type:    type,
        session_id:    getSessionId(),
        user_id:       userId,
        referrer:      document.referrer || null,
        ...extra
      });
    } catch (_) { /* never break the page */ }
  };
})();
