// Service worker: permite instalar la app en el celular y recibe las notificaciones de seguimiento.
// No guarda datos sin conexión. La notificación nunca trae datos de pacientes, solo un conteo.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Registro Bariátrico México', {
    body: d.body || 'Tienes controles de seguimiento pendientes este mes.',
    icon: '/icon-192.png', badge: '/icon-192.png', tag: 'seguimiento', renotify: false, data: { url: d.url || '/app/#seguimiento' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/app/';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.includes('/app/')); if (c) { c.navigate(url); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
