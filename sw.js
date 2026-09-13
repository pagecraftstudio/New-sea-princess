/**
 * sw.js — نيو سي برنسيس Service Worker
 * Strategy:
 *   - Static assets (JS/CSS/fonts/images): Cache-First
 *   - HTML pages: Network-First with offline fallback
 *   - Supabase API calls: Network-only (never cache auth/data)
 *   - Offline fallback: /offline.html
 *
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team.
 */

const CACHE_NAME   = 'nsp-v1';
const OFFLINE_URL  = '/offline.html';

// Static assets to pre-cache on install
const PRECACHE = [
  '/',
  '/index.html',
  '/packages.html',
  '/booking.html',
  '/tracking.html',
  '/about.html',
  '/contact.html',
  '/guide.html',
  '/hajj-guide.html',
  '/login.html',
  '/offline.html',
  '/manifest.json',
  '/css/custom.css',
  '/css/erp-ui.css',
  '/js/supabase-config.js',
  '/js/auth.js',
  '/js/nav-component.js',
  '/js/a11y-bar.js',
  '/js/booking.js',
  '/js/packages.js',
  '/js/tracking.js',
];

// Never cache these — always go to network
const BYPASS_PATTERNS = [
  /supabase\.co/,           // all Supabase API calls
  /googleapis\.com/,        // Google Fonts API
  /google\.com\/recaptcha/, // reCAPTCHA
  /wa\.me/,                 // WhatsApp
  /cdn\.jsdelivr\.net/,     // CDN scripts (versioned, don't need caching)
  /cdn\.tailwindcss\.com/,
  /cdnjs\.cloudflare\.com/,
  /fonts\.googleapis\.com/,
];

// ── INSTALL ────────────────────────────────────────────────────────────────
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(PRECACHE.map(url => new Request(url, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
      .catch(err => console.warn('[SW] Pre-cache partial failure:', err))
  );
});

// ── ACTIVATE ───────────────────────────────────────────────────────────────
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// ── FETCH ──────────────────────────────────────────────────────────────────
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // Only handle GET requests from our own origin + font CDNs
  if (request.method !== 'GET') return;

  // Bypass patterns — straight to network
  if (BYPASS_PATTERNS.some(p => p.test(request.url))) return;

  // fonts.gstatic.com (actual font files) — Cache-First
  if (url.hostname === 'fonts.gstatic.com') {
    event.respondWith(cacheFirst(request));
    return;
  }

  // Static file extensions — Cache-First
  if (/\.(js|css|woff2?|ttf|eot|png|jpg|jpeg|webp|svg|ico|gif)(\?.*)?$/.test(url.pathname)) {
    event.respondWith(cacheFirst(request));
    return;
  }

  // HTML navigation — Network-First with offline fallback
  if (request.mode === 'navigate' || request.headers.get('accept')?.includes('text/html')) {
    event.respondWith(networkFirstWithOfflineFallback(request));
    return;
  }

  // Everything else — Network-First
  event.respondWith(networkFirst(request));
});

// ── STRATEGIES ─────────────────────────────────────────────────────────────

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      cache.put(request, response.clone());
    }
    return response;
  } catch {
    return caches.match(OFFLINE_URL);
  }
}

async function networkFirst(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      cache.put(request, response.clone());
    }
    return response;
  } catch {
    const cached = await caches.match(request);
    return cached || caches.match(OFFLINE_URL);
  }
}

async function networkFirstWithOfflineFallback(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      cache.put(request, response.clone());
    }
    return response;
  } catch {
    const cached = await caches.match(request);
    if (cached) return cached;
    return caches.match(OFFLINE_URL);
  }
}

// ── BACKGROUND SYNC (future: queue failed booking submissions) ──────────────
self.addEventListener('sync', event => {
  if (event.tag === 'nsp-booking-retry') {
    event.waitUntil(retryPendingBookings());
  }
});

async function retryPendingBookings() {
  // Placeholder — implement with IndexedDB queue in booking.js if needed
  console.log('[SW] Background sync: nsp-booking-retry');
}

// ── PUSH NOTIFICATIONS (booking status updates) ───────────────────────────
self.addEventListener('push', event => {
  if (!event.data) return;
  let payload;
  try { payload = event.data.json(); } catch { payload = { title: 'نيو سي برنسيس', body: event.data.text() }; }

  event.waitUntil(
    self.registration.showNotification(payload.title || 'نيو سي برنسيس', {
      body:    payload.body || '',
      icon:    '/assets/icon-192.png',
      badge:   '/assets/icon-192.png',
      dir:     'rtl',
      lang:    'ar',
      tag:     payload.tag || 'nsp-notification',
      data:    payload.data || {},
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = event.notification.data?.url || '/my-account.html';
  event.waitUntil(clients.openWindow(url));
});
