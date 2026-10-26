/* Service worker de "Hoy en Pamplona".
   - Con conexión: siempre intenta cargar la edición más reciente.
   - Sin conexión: muestra la última edición guardada. */
const CACHE = "hoy-pamplona-v1";
const PRECARGA = [
  "./", "index.html", "manifest.webmanifest", "fonts.css", "styles.css",
  "icon-192.png", "icon-512.png", "apple-touch-icon.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      // Cada archivo por separado: si alguno no existe, no se rompe la instalación.
      Promise.all(PRECARGA.map((url) => cache.add(url).catch(() => {})))
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET" || !req.url.startsWith("http")) return;

  const mismoOrigen = new URL(req.url).origin === self.location.origin;
  const esPagina = req.mode === "navigate";

  // Páginas y archivos propios: red primero (noticias frescas), caché si no hay conexión.
  if (mismoOrigen || esPagina) {
    event.respondWith(
      fetch(req, { cache: "no-cache" })
        .then((resp) => {
          if (resp && resp.ok) {
            const copia = resp.clone();
            caches.open(CACHE).then((c) => c.put(req, copia));
          }
          return resp;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match("index.html")))
    );
    return;
  }

  // Recursos externos (logos del colegio): caché primero, se refrescan en segundo plano.
  event.respondWith(
    caches.match(req).then((guardado) => {
      const red = fetch(req)
        .then((resp) => {
          if (resp && (resp.ok || resp.type === "opaque")) {
            const copia = resp.clone();
            caches.open(CACHE).then((c) => c.put(req, copia));
          }
          return resp;
        })
        .catch(() => guardado);
      return guardado || red;
    })
  );
});
