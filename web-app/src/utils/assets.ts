/**
 * @file assets.ts
 * Cross-Platform Asset URL Resolver.
 * Resolves static assets (like .wasm binaries) correctly whether running on:
 * - Localhost dev server (http://localhost:5173/)
 * - GitHub Pages subpath (https://<user>.github.io/<repo>/)
 * - Custom domain or offline file context.
 */

export function getAssetUrl(filename: string): string {
  const clean = filename.replace(/^\.\//, '').replace(/^\//, '');
  const loc = typeof window !== 'undefined' ? window.location : (typeof self !== 'undefined' ? self.location : null);
  if (!loc) {
    return clean;
  }

  let pathname = loc.pathname || '/';
  if (!pathname.endsWith('/')) {
    if (pathname.includes('.')) {
      pathname = pathname.substring(0, pathname.lastIndexOf('/') + 1);
    } else {
      pathname += '/';
    }
  }

  // If inside /assets/ directory (e.g. bundled web worker), traverse up to root
  if (pathname.endsWith('/assets/')) {
    pathname = pathname.substring(0, pathname.length - 7);
  }

  return new URL(clean, `${loc.origin}${pathname}`).href;
}
