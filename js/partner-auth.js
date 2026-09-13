/**
 * partner-auth.js
 * Shared auth guard for all B2B Partner Portal pages.
 * Usage: include this script, then call requirePartnerAuth() in DOMContentLoaded.
 */

window.PartnerAuth = (() => {
  let _session = null;
  let _partnerUser = null;
  let _partner = null;

  async function requirePartnerAuth() {
    const { data: { session } } = await db.auth.getSession();
    if (!session) { window.location.href = '/partners/login.html'; return null; }
    _session = session;

    // Check partner_portal_users
    const { data: ppu } = await db
      .from('partner_portal_users')
      .select('*, b2b_partners(id,legal_name,trading_name,tier,currency,credit_limit,payment_terms_days,contract_expiry,contract_status,email,phone,whatsapp,country,city)')
      .eq('user_id', session.user.id)
      .eq('is_active', true)
      .maybeSingle();

    if (!ppu) { await db.auth.signOut(); window.location.href = '/partners/login.html'; return null; }

    _partnerUser = ppu;
    _partner     = ppu.b2b_partners;

    // Render nav partner name
    const nameEl = document.getElementById('partnerName');
    const compEl = document.getElementById('companyName');
    if (nameEl) nameEl.textContent = session.user.user_metadata?.full_name || session.user.email;
    if (compEl) compEl.textContent = _partner?.trading_name || _partner?.legal_name || 'شريك';

    return ppu;
  }

  async function signOut() {
    await db.auth.signOut();
    window.location.href = '/partners/login.html';
  }

  function getPartner()     { return _partner; }
  function getPartnerUser() { return _partnerUser; }
  function getPartnerId()   { return _partnerUser?.partner_id; }
  function isAdmin()        { return _partnerUser?.role === 'admin'; }

  return { requirePartnerAuth, signOut, getPartner, getPartnerUser, getPartnerId, isAdmin };
})();
