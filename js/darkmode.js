/**
 * darkmode.js — New Sea Princess
 * Include in every public page after Tailwind CDN
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */

// Apply saved preference immediately to avoid flash
(function() {
  if (localStorage.getItem('darkMode') === '1') {
    document.documentElement.classList.add('dark');
  }
})();

function toggleDark() {
  const isDark = document.documentElement.classList.toggle('dark');
  localStorage.setItem('darkMode', isDark ? '1' : '0');
  updateDarkIcon();
}

function updateDarkIcon() {
  const isDark = document.documentElement.classList.contains('dark');
  // Supports both the legacy #darkIcon/#darkToggle ids (single button pages)
  // and the .dark-icon/.dark-toggle-btn classes (pages with desktop+mobile buttons)
  document.querySelectorAll('#darkIcon, .dark-icon').forEach(icon => {
    icon.className = icon.className.replace(/fa-(sun|moon)/, isDark ? 'fa-sun' : 'fa-moon');
  });
  document.querySelectorAll('#darkToggle, .dark-toggle-btn').forEach(btn => {
    btn.style.color = isDark ? '#DAA520' : '#B8860B';
  });
}

document.addEventListener('DOMContentLoaded', updateDarkIcon);
