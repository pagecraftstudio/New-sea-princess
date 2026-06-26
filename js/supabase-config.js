/**
 * supabase-config.js — نيو سي برنسيس للسياحة
 *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */
// Supabase Configuration
// Note: In a real environment, replace these placeholders with your actual Supabase Project URL and Anon Key.
// For the AI Studio preview to avoid immediate crashes, we expose a mock or require manual setup.

const SUPABASE_URL = 'https://uptaqdldbvmiigsfndtm.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVwdGFxZGxkYnZtaWlnc2ZuZHRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA2OTI1NTcsImV4cCI6MjA5NjI2ODU1N30.3bMA9N6rTEaHcH3yOq8sr1udsE7ahthCME3MpRzVwDg';

if (!window.supabase) {
  console.warn("Supabase library not loaded. Ensure the CDN script is included.");
} else {
  // Initialize Supabase Client
  window.db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  
  if (SUPABASE_URL.includes('YOUR_SUPABASE')) {
      console.error("⚠️ Supabase is not configured! Please provide your API keys in js/supabase-config.js or via localStorage.");
  }
}

// Global UI Helpers
window.formatCurrency = (amount) => {
  return new Intl.NumberFormat('ar-EG', { style: 'currency', currency: 'EGP', maximumFractionDigits: 0 }).format(amount);
};

window.formatDate = (dateString) => {
  if (!dateString) return '';
  const date = new Date(dateString);
  return new Intl.DateTimeFormat('ar-EG', { day: 'numeric', month: 'long', year: 'numeric' }).format(date);
};

// Tailwind config is now injected per-page before the CDN script (in <head>)
// This is kept here only as a fallback for pages that miss it
if (window.tailwind && !window.tailwindConfig) {
    tailwind.config = {
        theme: { extend: {
            colors: {
                primary:'#1B5E20', lightGreen:'#2E7D32', gold:'#B8860B',
                lightGold:'#DAA520', darkBg:'#0D1B0E', offWhite:'#F8F5EC',
                borderGold:'#D4AF6A', success:'#2E7D32', warning:'#F57F17', error:'#C62828'
            },
            fontFamily: { sans: ['Cairo','sans-serif'] }
        }}
    };
}
