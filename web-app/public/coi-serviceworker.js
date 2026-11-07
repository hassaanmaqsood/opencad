/*! coi-serviceworker v0.1.7 - Guido Zuidhof and contributors - MIT License */
let coepCredentialless = false;
if (typeof window === 'undefined') {
  self.addEventListener("install", () => self.skipWaiting());
  self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

  self.addEventListener("message", (ev) => {
    if (!ev.data) return;
    if (ev.data.type === "deregister") {
      self.registration.unregister().then(() => {
        return self.clients.matchAll();
      }).then((clients) => {
        clients.forEach((client) => client.navigate(client.url));
      });
    }
  });

  self.addEventListener("fetch", function (event) {
    const r = event.request;
    if (r.cache === "only-if-cached" && r.mode !== "same-origin") return;

    const request = (coepCredentialless && r.mode === "no-cors")
      ? new Request(r, { credentials: "omit" })
      : r;

    event.respondWith(
      fetch(request).then((response) => {
        if (response.status === 0) return response;

        const newHeaders = new Headers(response.headers);
        newHeaders.set("Cross-Origin-Embedder-Policy", coepCredentialless ? "credentialless" : "require-corp");
        newHeaders.set("Cross-Origin-Opener-Policy", "same-origin");

        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: newHeaders,
        });
      })
    );
  });
} else {
  (() => {
    // If cross-origin isolation is already enabled, keep the service worker active
    if (window.crossOriginIsolated) {
      return;
    }

    const currentScript = document.currentScript;
    const src = currentScript ? currentScript.src : "coi-serviceworker.js";

    if ("serviceWorker" in navigator) {
      // When the service worker claims the page, reload so COOP/COEP headers apply
      navigator.serviceWorker.addEventListener("controllerchange", () => {
        window.location.reload();
      });

      navigator.serviceWorker.register(src).then((registration) => {
        registration.addEventListener("updatefound", () => {
          const installingWorker = registration.installing;
          if (installingWorker) {
            installingWorker.addEventListener("statechange", () => {
              if (installingWorker.state === "activated") {
                window.location.reload();
              }
            });
          }
        });

        // If registration is active but not controlling the page yet, trigger reload
        if (registration.active && !navigator.serviceWorker.controller) {
          window.location.reload();
        }
      }, (err) => {
        console.warn("COI ServiceWorker registration failed: ", err);
      });
    }
  })();
}
