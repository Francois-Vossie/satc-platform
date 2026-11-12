// Service worker: cache the app shell so the storefront opens on slow or dropped 4G connections
const SHELL = "satc-shell-v1";
const FILES = ["/", "/index.html", "/app.js", "/manifest.webmanifest"];
self.addEventListener("install", e => e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES))));
self.addEventListener("activate", e => e.waitUntil(caches.keys().then(keys =>
  Promise.all(keys.filter(k => k !== SHELL).map(k => caches.delete(k))))));
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (url.pathname.startsWith("/api/")) {                       // network first for live data, fall back to cache
    e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(SHELL).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request)));
  } else {                                                       // cache first for the app shell
    e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
  }
});
