/*
 * Service worker for the installed app.
 *
 * Chrome wants a fetch handler before it will treat a site as installable, but
 * Vista is a live client of an API — caching its responses would show stale
 * briefs and, worse, could serve one account's data to another. So:
 *
 *   - /api/ is never touched. Always the network, no cache, no interception.
 *   - Navigations are network-first, falling back to the cached shell, so a
 *     launch without connectivity opens to the UI (and its own error state)
 *     rather than the browser's offline page.
 *   - Build assets are content-hashed by Vite, so a hit is safe to serve from
 *     cache; anything else falls through to the network.
 */

const VERSION = "vista-v1";
const SHELL = ["/", "/index.html", "/icon-192.png", "/icon-512.png", "/manifest.webmanifest"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);

  // Never cache or intercept the API, and leave other origins alone.
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(VERSION).then((cache) => cache.put("/index.html", copy));
          return response;
        })
        .catch(() => caches.match("/index.html").then((hit) => hit ?? Response.error())),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then((hit) => {
      if (hit) return hit;
      return fetch(request).then((response) => {
        // Only keep successful same-origin responses; an opaque or errored one
        // would poison the cache.
        if (response.ok && response.type === "basic") {
          const copy = response.clone();
          caches.open(VERSION).then((cache) => cache.put(request, copy));
        }
        return response;
      });
    }),
  );
});
