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
  if (typeof window === 'undefined') {
    return clean;
  }

  let pathname = window.location.pathname;
  if (!pathname.endsWith('/')) {
    if (pathname.includes('.')) {
      pathname = pathname.substring(0, pathname.lastIndexOf('/') + 1);
    } else {
      pathname += '/';
    }
  }

  return new URL(clean, `${window.location.origin}${pathname}`).href;
}
