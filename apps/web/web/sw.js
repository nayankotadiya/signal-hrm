// Signal HRM Service Worker: Instant PWA Caching + 24/7 Web Push
const CACHE_NAME = 'shrm-static-v2';

// Essential shell files to pre-cache on install
const PRECACHE_ASSETS = [
  './',
  'index.html',
  'splash.js',
  'push-helper.js',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png'
];

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      return cache.addAll(PRECACHE_ASSETS).catch(function () {});
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.map(function (key) {
          if (key !== CACHE_NAME) {
            return caches.delete(key);
          }
        })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', function (event) {
  const req = event.request;
  const url = new URL(req.url);

  // Never cache API calls, mutation methods, or cross-origin telemetry
  if (req.method !== 'GET' || url.pathname.includes('/api/') || url.pathname.includes('/v1/')) {
    return;
  }

  // Navigation requests: Network-first with cache fallback for instant offline/cold load
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).catch(function () {
        return caches.match('index.html') || caches.match('./');
      })
    );
    return;
  }

  // Static assets (main.dart.js, canvaskit.wasm, fonts, icons, etc.):
  // Cache-first for instant (sub-second) load, revalidating in background
  const isStatic =
    url.pathname.endsWith('.js') ||
    url.pathname.endsWith('.wasm') ||
    url.pathname.endsWith('.png') ||
    url.pathname.endsWith('.jpg') ||
    url.pathname.endsWith('.svg') ||
    url.pathname.endsWith('.woff') ||
    url.pathname.endsWith('.woff2') ||
    url.pathname.endsWith('.ttf') ||
    url.pathname.endsWith('.json') ||
    url.pathname.includes('/assets/') ||
    url.pathname.includes('/canvaskit/');

  if (isStatic) {
    event.respondWith(
      caches.match(req).then(function (cached) {
        if (cached) {
          // Serve immediately from device cache!
          return cached;
        }
        return fetch(req).then(function (networkRes) {
          if (networkRes && networkRes.status === 200) {
            const clone = networkRes.clone();
            caches.open(CACHE_NAME).then(function (cache) {
              cache.put(req, clone);
            });
          }
          return networkRes;
        });
      })
    );
    return;
  }
});

// Signal HRM Web Push Notifications (24/7 background alerts)
self.addEventListener('push', function (event) {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (e) {
    payload = { title: 'Signal HRM', body: event.data ? event.data.text() : '' };
  }

  const title = payload.title || 'Signal HRM';
  const options = {
    body: payload.body || 'You have a new notification.',
    icon: payload.icon || 'icons/Icon-192.png',
    badge: payload.badge || 'icons/Icon-192.png',
    vibrate: [200, 100, 200],
    data: {
      link: (payload.data && payload.data.link) || '/',
      dateOfArrival: Date.now(),
    },
    actions: [
      { action: 'open', title: 'Open' }
    ]
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  const rawLink = (event.notification.data && event.notification.data.link) || '/';
  const targetUrl = new URL(rawLink, self.location.origin).href;

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
      for (let i = 0; i < clientList.length; i++) {
        const client = clientList[i];
        if (client.url === targetUrl && 'focus' in client) {
          return client.focus();
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    })
  );
});
