/**
 * auth.js — نيو سي برنسيس للسياحة
 * User authentication helpers (login, register, logout, session guard)
 * Requires: supabase-config.js loaded first (window.db)
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

/* ─── wait for db ─── */
function getDB() {
  if (window.db) return window.db;
  throw new Error('Supabase not initialised — include supabase-config.js first');
}

/* ─── current session ─── */
async function getCurrentUser() {
  const { data: { session } } = await getDB().auth.getSession();
  return session ? session.user : null;
}

/* ─── sign up ─── */
async function signUp({ email, password, fullName, phone }) {
  const { data, error } = await getDB().auth.signUp({
    email,
    password,
    options: {
      data: { full_name: fullName, phone }
    }
  });
  if (error) throw error;
  return data;
}

/* ─── sign in ─── */
async function signIn({ email, password }) {
  const { data, error } = await getDB().auth.signInWithPassword({ email, password });
  if (error) throw error;

  // تحقق هل الحساب موقوف من الإدارة
  const { data: profile } = await getDB().from('profiles').select('is_blocked').eq('id', data.user.id).single();
  if (profile?.is_blocked) {
    await getDB().auth.signOut();
    throw new Error('تم إيقاف هذا الحساب من الإدارة، يرجى التواصل مع الدعم');
  }

  // سجّل وقت/عدد مرات الدخول (لا يوقف تسجيل الدخول لو فشل)
  getDB().rpc('track_user_login').then(({ error: rpcErr }) => {
    if (rpcErr) console.error('track_user_login error:', rpcErr);
  });

  return data;
}

/* ─── sign out ─── */
async function signOut() {
  await getDB().auth.signOut();
  window.location.href = '/login.html';
}

/* ─── password reset ─── */
async function sendPasswordReset(email) {
  const { error } = await getDB().auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin + '/reset-password.html'
  });
  if (error) throw error;
}

/* ─── guard: redirect to login if not signed in ─── */
async function requireAuth(redirectTo) {
  const user = await getCurrentUser();
  if (!user) {
    const dest = redirectTo || '/login.html?next=' + encodeURIComponent(window.location.pathname);
    window.location.href = dest;
    return null;
  }
  return user;
}

/* ─── guard: redirect away if already signed in ─── */
async function redirectIfAuth(dest) {
  const user = await getCurrentUser();
  if (user) window.location.href = dest || '/my-account.html';
}

/* ─── update header nav to reflect auth state ─── */
async function updateNavAuth() {
  const user = await getCurrentUser();
  const loginLinks  = document.querySelectorAll('[data-auth="guest"]');
  const logoutLinks = document.querySelectorAll('[data-auth="user"]');
  const userNameEls = document.querySelectorAll('[data-user-name]');

  loginLinks.forEach(el  => el.style.display = user ? 'none' : (el.dataset.authDisplay || ''));
  logoutLinks.forEach(el => el.style.display = user ? (el.dataset.authDisplay || '') : 'none');

  if (user) {
    const name = user.user_metadata?.full_name || user.email.split('@')[0];
    userNameEls.forEach(el => el.textContent = name);
  }
}

/* ─── shared account dropdown toggle (header widget) ─── */
function toggleAccountMenu(e) {
  e.stopPropagation();
  const d = document.getElementById('accountDropdown');
  if (d) d.classList.toggle('hidden');
}
document.addEventListener('click', () => {
  const d = document.getElementById('accountDropdown');
  if (d) d.classList.add('hidden');
});
document.addEventListener('DOMContentLoaded', () => {
  if (window.NSPAuth) NSPAuth.updateNavAuth();
});

/* ─── exports ─── */
window.NSPAuth = { getCurrentUser, signUp, signIn, signOut, sendPasswordReset, requireAuth, redirectIfAuth, updateNavAuth };
