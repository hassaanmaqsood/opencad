/**
 * @file assets.ts
 * Cross-Platform Asset URL Resolver.
 * Resolves static assets (like .wasm binaries and .cdml files) across:
 * - Localhost dev server (http://localhost:5173/)
 * - GitHub Pages subpath (https://<user>.github.io/opencad/ and /opencad/studio/)
 * - Custom domain or offline file context.
 */

export function getAssetUrl(filename: string): string {
  // Rewrite legacy raw GitHub or relative paths that still reference web-app/public/examples/
  const normalized = filename.replace(/\/web-app\/public\/examples\//g, '/examples/');

  if (/^(https?:|data:|blob:)/i.test(normalized)) {
    return normalized;
  }

  const loc = typeof window !== 'undefined' ? window.location : (typeof self !== 'undefined' ? self.location : null);
  if (!loc) {
    return normalized.replace(/^\.\//, '').replace(/^\//, '');
  }

  // If the path already starts with the GitHub Pages base prefix (/opencad/), resolve from origin
  if (normalized.startsWith('/opencad/')) {
    return new URL(normalized, loc.origin).href;
  }

  const clean = normalized.replace(/^\.\//, '').replace(/^\//, '');

  let pathname = loc.pathname || '/';
  if (!pathname.endsWith('/')) {
    if (pathname.includes('.')) {
      pathname = pathname.substring(0, pathname.lastIndexOf('/') + 1);
    } else {
      pathname += '/';
    }
  }

  // If inside /assets/ directory (e.g. bundled web worker), traverse up to app root
  if (pathname.endsWith('/assets/')) {
    pathname = pathname.substring(0, pathname.length - 7);
  }

  return new URL(clean, `${loc.origin}${pathname}`).href;
}
