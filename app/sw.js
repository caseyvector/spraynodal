// Service worker: shows push notifications and opens the app when one is tapped.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  const title = String(data.title || 'Spraynodal').slice(0, 80);
  const options = {
    body: String(data.body || '').slice(0, 240),
    tag: String(data.tag || 'spraynodal'),
    data: { url: typeof data.url === 'string' ? data.url : 'monitor.html' },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  // Only ever open pages on our own site, whatever the payload says
  let target = new URL('monitor.html', self.location.href);
  try {
    const wanted = new URL((event.notification.data && event.notification.data.url) || 'monitor.html', self.location.href);
    if (wanted.origin === self.location.origin) target = wanted;
  } catch (e) { /* keep default */ }

  event.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of open) {
      if (client.url === target.href && 'focus' in client) return client.focus();
    }
    return self.clients.openWindow(target.href);
  })());
});
