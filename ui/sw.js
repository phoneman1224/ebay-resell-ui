// Service Worker: simple runtime cache + offline fallback
const CACHE = 'resell-v1';
const API_ORIGIN = 'https://resell-api.phoneman1224.workers.dev';


self.addEventListener('install', (event) => {
// why: activate new SW immediately
self.skipWaiting();
});


self.addEventListener('activate', (event) => {
// why: claim control for open pages without reload
event.waitUntil(self.clients.claim());
});


self.addEventListener('fetch', (event) => {
const req = event.request;
if (req.method !== 'GET') return; // only cache GETs
const url = new URL(req.url);
const isDoc = req.destination === 'document';
const isStatic = ['style','script','image','font'].includes(req.destination);
const isAPI = url.origin === API_ORIGIN && url.pathname.startsWith('/inventory');


if (!(isDoc || isStatic || isAPI)) return; // let the rest pass through


event.respondWith((async () => {
try {
const res = await fetch(req);
const copy = res.clone();
caches.open(CACHE).then(c => c.put(req, copy).catch(()=>{}));
return res;
} catch (err) {
const cached = await caches.match(req, { ignoreVary: true });
if (cached) return cached;
if (isDoc) {
return new Response('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Offline</title></head><body style="font-family:system-ui;padding:1rem"><h1>Offline</h1><p>This app is offline. Reconnect to sync inventory.</p></body></html>', { headers: { 'Content-Type': 'text/html' }});
}
return new Response('Offline', { status: 503, headers: { 'Content-Type': 'text/plain' }});
}
})());
});
