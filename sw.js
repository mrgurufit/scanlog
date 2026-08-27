// Scan & Log offline shell.
//
// Two different strategies on purpose:
//   app shell     - network-first, so a deploy lands on the next open; the
//                   cache answers whenever there is no connection.
//   product photos - cache-first. They live on other origins (Wikipedia,
//                   Open Food Facts), they never change once fetched, and
//                   without this every picture in the log was a broken box
//                   the moment the phone went offline.
const CACHE = "scanlog-v2";
const IMG_CACHE = "scanlog-img-v1";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png"];

// the only hosts we hold pictures from
const IMG_HOST = /(^|\.)(wikimedia\.org|wikipedia\.org|openfoodfacts\.org)$/;
const IMG_MAX = 400;   // plenty for his catalogue, still bounded

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

// Only ever delete OUR OWN old caches. Publish Center is a second app on this
// same origin with its own worker; a blanket "delete everything that is not
// mine" meant each app wiped the other's offline store on every deploy, and
// since Publish Center redeploys nightly, Scan & Log woke up with no cache and
// would not open without a connection.
const MINE = /^scanlog-/;
self.addEventListener("activate", e => {
  const keep = [CACHE, IMG_CACHE];
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => MINE.test(k) && !keep.includes(k)).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// keep the picture cache from growing without limit - oldest out first
async function trimImages() {
  const c = await caches.open(IMG_CACHE);
  const keys = await c.keys();
  for (let i = 0; i < keys.length - IMG_MAX; i++) await c.delete(keys[i]);
}

async function photo(req) {
  const c = await caches.open(IMG_CACHE);
  const hit = await c.match(req);
  if (hit) return hit;
  // no-cors gives an opaque response: unreadable to script, perfectly fine
  // in an <img>, and cacheable - which is all we need here
  const res = await fetch(req);
  if (res && (res.ok || res.type === "opaque")) {
    c.put(req, res.clone()).then(trimImages).catch(() => {});
  }
  return res;
}

self.addEventListener("fetch", e => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);

  if (url.origin === location.origin) {
    e.respondWith(
      fetch(e.request).then(r => {
        const copy = r.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => {});
        return r;
      }).catch(() =>
        caches.match(e.request, { ignoreSearch: true })
          .then(m => m || caches.match("./index.html"))));
    return;
  }

  if (IMG_HOST.test(url.hostname) && (e.request.destination === "image" || e.request.mode === "no-cors")) {
    // offline with nothing cached: hand back a transparent pixel rather than
    // let the browser draw its broken-image glyph over the log
    e.respondWith(photo(e.request).catch(() => new Response(
      Uint8Array.from(atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"), c => c.charCodeAt(0)),
      { headers: { "Content-Type": "image/gif" } })));
  }
});
