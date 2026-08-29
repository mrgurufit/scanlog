// Retired. The scanner moved to /app and brought its own worker; this one
// exists only to unregister itself from phones that installed the old root
// copy, so the front door is never served from a stale app cache.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    await self.registration.unregister();
    const clients = await self.clients.matchAll({ type: "window" });
    clients.forEach(c => c.navigate(c.url));
  })());
});
