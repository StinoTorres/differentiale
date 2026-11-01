// Differentiale: eenvoudige service worker. Altijd eerst het netwerk (zodat updates direct binnenkomen),
// zonder verbinding de laatst opgeslagen versie. Alleen bestanden van deze site, nooit Supabase.
const CACHE = "avdd-v12";
const SHELL = ["./", "index.html", "config.js", "favicon.svg", "manifest.webmanifest", "icon-192.png", "data/players.json", "data/league.json"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(()=>{})); self.skipWaiting(); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  const key = url.origin + url.pathname;
  e.respondWith(fetch(e.request).then(res => {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(key, copy)); }
    return res;
  }).catch(() => caches.match(key).then(r => r || caches.match("index.html"))));
});
