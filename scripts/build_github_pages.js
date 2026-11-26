/**
 * @file build_github_pages.js
 * Assembles the unified Zero-Duplication GitHub Pages bundle (`dist-pages/`)
 * merging:
 * 1. VitePress Unified Portal (`docs/.vitepress/dist` -> `dist-pages/`)
 *    - `/guide/`, `/reference/`, `/papers/`, `/collabs/`, `/examples/`, `/brand/`
 *    - `/assets/math/`, `/brand/*`, `/examples/*.cdml`
 * 2. Interactive 3D CAD Studio (`web-app/dist` -> `dist-pages/studio/`)
 *    - Plus shared `cad_kernel.wasm`, `cad_core.wasm`, `coi-serviceworker.js` at root & `/studio/`
 * 3. FEAScript x OpenCAD Thermal Loop & Drop-In ES Modules (`examples/feascript-loop`)
 *    - Served at `/demos/feascript/` AND backward-compatible `/feascript-demo.html` + `/feascript-demo/`
 * 4. CDN & Web Component Distribution (`dist-publish/` -> `dist-pages/cdn/` + `/opencad-portable.html` + `/skill.md`)
 */

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');
const pagesDir = path.resolve(rootDir, 'dist-pages');

console.log('[build:pages] Starting Unified OpenCAD GitHub Pages assembly...');

// 1. Build Web App Studio (if not already built) and VitePress Portal
console.log('[build:pages] Building Web App Studio (web-app/dist)...');
execSync('npm --prefix web-app run build', { cwd: rootDir, stdio: 'inherit' });

console.log('[build:pages] Building VitePress Documentation Portal (docs/.vitepress/dist)...');
execSync('npm run docs:build', { cwd: rootDir, stdio: 'inherit' });

// 2. Clean and create dist-pages/
if (fs.existsSync(pagesDir)) {
  fs.rmSync(pagesDir, { recursive: true, force: true });
}
fs.mkdirSync(pagesDir, { recursive: true });

// 3. Copy VitePress Portal to root of dist-pages/
const vpDist = path.resolve(rootDir, 'docs/.vitepress/dist');
fs.cpSync(vpDist, pagesDir, { recursive: true });

// 4. Mount 3D CAD Studio at dist-pages/studio/
const studioDist = path.resolve(rootDir, 'web-app/dist');
const studioOut = path.resolve(pagesDir, 'studio');
fs.mkdirSync(studioOut, { recursive: true });
fs.cpSync(studioDist, studioOut, { recursive: true });

// Also copy WASM binaries and coi-serviceworker.js to root of dist-pages/ for demos & drop-in modules
for (const file of ['cad_kernel.wasm', 'cad_core.wasm', 'coi-serviceworker.js']) {
  const src = path.resolve(rootDir, 'web-app/public', file);
  if (fs.existsSync(src)) {
    fs.copyFileSync(src, path.resolve(pagesDir, file));
  }
}

// 5. Mount canonical FEAScript x OpenCAD Demo & Drop-In Modules from examples/feascript-loop/
const feaSrc = path.resolve(rootDir, 'examples/feascript-loop');
if (fs.existsSync(feaSrc)) {
  // Canonical path: /demos/feascript/
  const feaCanonical = path.resolve(pagesDir, 'demos/feascript');
  fs.mkdirSync(feaCanonical, { recursive: true });
  fs.cpSync(feaSrc, feaCanonical, { recursive: true });
  for (const file of ['cad_kernel.wasm', 'cad_core.wasm', 'coi-serviceworker.js']) {
    const src = path.resolve(rootDir, 'web-app/public', file);
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, path.resolve(feaCanonical, file));
    }
  }

  // Backward-compatible path: /feascript-demo.html + /feascript-demo/{js,styles}
  const feaCompatDir = path.resolve(pagesDir, 'feascript-demo');
  fs.mkdirSync(feaCompatDir, { recursive: true });
  fs.cpSync(path.resolve(feaSrc, 'js'), path.resolve(feaCompatDir, 'js'), { recursive: true });
  fs.cpSync(path.resolve(feaSrc, 'styles'), path.resolve(feaCompatDir, 'styles'), { recursive: true });
  const indexHtml = fs.readFileSync(path.resolve(feaSrc, 'index.html'), 'utf8')
    .replace('./styles/demo.css', './feascript-demo/styles/demo.css')
    .replace('./js/main.js', './feascript-demo/js/main.js');
  fs.writeFileSync(path.resolve(pagesDir, 'feascript-demo.html'), indexHtml, 'utf8');
}

// 6. Copy canonical skill.md to /skill.md and canonical examples/*.cdml to /examples/ and /studio/examples/
const skillSrc = path.resolve(rootDir, 'docs/reference/skill.md');
if (fs.existsSync(skillSrc)) {
  fs.copyFileSync(skillSrc, path.resolve(pagesDir, 'skill.md'));
}

const examplesSrc = path.resolve(rootDir, 'examples');
if (fs.existsSync(examplesSrc)) {
  for (const destBase of [path.resolve(pagesDir, 'examples'), path.resolve(studioOut, 'examples')]) {
    fs.mkdirSync(destBase, { recursive: true });
    for (const entry of fs.readdirSync(examplesSrc)) {
      if (entry.endsWith('.cdml') || entry === 'lib') {
        fs.cpSync(path.resolve(examplesSrc, entry), path.resolve(destBase, entry), { recursive: true });
      }
    }
  }
}

// 7. Copy CDN artifacts from dist-publish/ if present
const distPub = path.resolve(rootDir, 'dist-publish');
if (fs.existsSync(distPub)) {
  const cdnOut = path.resolve(pagesDir, 'cdn');
  fs.mkdirSync(cdnOut, { recursive: true });
  for (const f of ['opencad.mjs', 'opencad.d.ts', 'opencad-element.mjs', 'cad_core.wasm']) {
    if (fs.existsSync(path.resolve(distPub, f))) {
      fs.copyFileSync(path.resolve(distPub, f), path.resolve(cdnOut, f));
    }
  }
  if (fs.existsSync(path.resolve(distPub, 'opencad-portable.html'))) {
    fs.copyFileSync(path.resolve(distPub, 'opencad-portable.html'), path.resolve(pagesDir, 'opencad-portable.html'));
  }
}

console.log('[build:pages] Unified GitHub Pages bundle assembled at dist-pages/!');
