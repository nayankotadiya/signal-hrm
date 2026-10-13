// Signal HRM Web Push Service Worker (24/7 background notifications)
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
