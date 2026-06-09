// Service Worker – TRINITRIX PWA
const CACHE_NAME = 'trinitrix-v1';

// File yang di-cache untuk offline basic shell
const PRECACHE = [
  '/',
  '/index.html',
  '/manifest.json',
  '/trinitrix.png'
];

// Install: pre-cache shell
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(PRECACHE))
  );
  self.skipWaiting();
});

// Activate: hapus cache lama
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Fetch: network-first untuk API Supabase, cache-first untuk aset statis
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Supabase API → selalu network, jangan cache
  if (url.hostname.includes('supabase.co')) {
    return; // biarkan browser handle langsung
  }

  // Aset statis → cache-first
  event.respondWith(
    caches.match(event.request).then(cached => {
      if (cached) return cached;
      return fetch(event.request).then(response => {
        // Cache response baru untuk aset GET
        if (event.request.method === 'GET' && response.status === 200) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
        }
        return response;
      }).catch(() => {
        // Offline fallback ke index.html
        if (event.request.mode === 'navigate') {
          return caches.match('/index.html');
        }
      });
    })
  );
});
