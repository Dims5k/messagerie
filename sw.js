// Service worker : reçoit les notifications push même quand l'appli est fermée
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data.json(); } catch { d = { body: e.data ? e.data.text() : 'Nouveau message' }; }
  e.waitUntil((async () => {
    // Pas de notif si la personne a déjà ce salon ouvert sous les yeux
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (d.room && list.some(c => c.visibilityState === 'visible' && c.url.includes('room=' + d.room))) return;
    await self.registration.showNotification(d.title || 'Messagerie', {
      body: d.body || 'Nouveau message',
      tag: d.room || 'msg',
      renotify: true,
      icon: 'icon-192.png',
      badge: 'icon-192.png',
      data: { room: d.room }
    });
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const room = e.notification.data?.room;
  const url = new URL(room ? './?room=' + room : './', self.registration.scope).href;
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope)) {
        await c.focus();
        if (room) c.postMessage({ room });
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
