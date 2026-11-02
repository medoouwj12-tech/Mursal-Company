const CACHE = 'mersal-shell-v3';
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png'];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => null));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;
  // Never serve HTML/API from cache-first: the shell fallback is only for offline navigation.
  event.respondWith(
    fetch(event.request)
      .then(response => {
        const copy = response.clone();
        caches.open(CACHE).then(c => c.put(event.request, copy)).catch(() => null);
        return response;
      })
      .catch(() => caches.match(event.request).then(r => r || caches.match('/')))
  );
});

self.addEventListener('push', event => {
  let data = { title: 'طلب جديد على مرسال', body: 'افتح التطبيق لمشاهدة الطلب', url: '/' };
  try {
    data = { ...data, ...event.data.json() };
  } catch {}
  const tag = data.orderId ? `mersal-order-${data.orderId}` : 'mersal-order';
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: '/icons/icon-192.png',
      badge: '/icons/favicon-32.png',
      tag,
      renotify: true,
      requireInteraction: true,
      vibrate: [220, 120, 220, 120, 320],
      dir: 'rtl',
      lang: 'ar',
      data: { url: data.url || '/', orderId: data.orderId || null },
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      const client = list.find(c => c.url.includes(self.location.origin)) || list[0];
      if (client) {
        client.navigate(target).catch(() => null);
        return client.focus();
      }
      return self.clients.openWindow(target);
    })
  );
});
