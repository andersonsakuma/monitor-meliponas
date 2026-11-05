/* Funciona sem internet: guarda as telas e usa a cópia guardada quando a rede falha. */
var CACHE = 'monitor-meliponas-v5';
var ARQUIVOS = ['./', 'index.html', 'web-ponte.js', 'config.js', 'manifest.webmanifest', 'qr-web.png', 'qr-app.png',
  'logos/ipe-fis.png', 'logos/amazonia-bee.png', 'icone-192.png', 'icone-512.png'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(ARQUIVOS).catch(function () {}); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); }).then(function () { return self.clients.claim(); }));
});
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;   // servidor de dados: sempre pela rede
  e.respondWith(fetch(e.request).then(function (r) {
    if (r && r.ok) { var copia = r.clone(); caches.open(CACHE).then(function (c) { c.put(e.request, copia); }); }
    return r;
  }).catch(function () { return caches.match(e.request, { ignoreSearch: true }).then(function (r) { return r || caches.match('index.html'); }); }));
});
