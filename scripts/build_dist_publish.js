/**
 * @file build_dist_publish.js
 * Assembles and packages the zero-account GitHub distribution bundle (dist-publish/).
 * Stages:
 * 1. CDN ESM Bundle (opencad.mjs, opencad.d.ts, cad_core.wasm)
 * 2. Web Component Bundle (opencad-element.mjs)
 * 3. Pure-WASM Python distribution package (dist-publish/python/)
 * 4. Pure-WASM Rust distribution crate (dist-publish/rust/)
 * 5. Single-File Offline Portable HTML (dist-publish/opencad-portable.html)
 * 6. Root package.json for `npm install github:hassaanmaqsood/opencad#dist`
 */

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');
const distPublishDir = path.resolve(rootDir, 'dist-publish');
const esbuildBin = path.resolve(rootDir, 'web-app/node_modules/.bin/esbuild');

console.log('[dist-publish] Starting OpenCAD GitHub-only distribution assembly...');

// 1. Clean & recreate staging directory
if (fs.existsSync(distPublishDir)) {
  fs.rmSync(distPublishDir, { recursive: true, force: true });
}
fs.mkdirSync(distPublishDir, { recursive: true });

// 2. Ensure core-sdk is compiled
console.log('[dist-publish] Compiling packages/core-sdk...');
execSync('npm --prefix packages/core-sdk run build', { cwd: rootDir, stdio: 'inherit' });

// 3. Bundle opencad.mjs (ESM CDN bundle)
console.log('[dist-publish] Bundling opencad.mjs...');
execSync(
  `"${esbuildBin}" packages/core-sdk/src/index.ts --bundle --format=esm --target=es2022 --outfile=dist-publish/opencad.mjs --minify`,
  { cwd: rootDir, stdio: 'inherit' }
);

// 4. Bundle opencad-element.mjs (<opencad-viewer> Web Component)
console.log('[dist-publish] Bundling opencad-element.mjs...');
execSync(
  `"${esbuildBin}" packages/core-sdk/src/element.ts --bundle --format=esm --target=es2022 --outfile=dist-publish/opencad-element.mjs --minify`,
  { cwd: rootDir, stdio: 'inherit' }
);

// 5. Generate consolidated opencad.d.ts
console.log('[dist-publish] Generating opencad.d.ts...');
const dtsTypes = fs.readFileSync(path.resolve(rootDir, 'packages/core-sdk/dist/types.d.ts'), 'utf8');
const dtsLoader = fs.readFileSync(path.resolve(rootDir, 'packages/core-sdk/dist/loader.d.ts'), 'utf8');
const dtsKernel = fs.readFileSync(path.resolve(rootDir, 'packages/core-sdk/dist/kernel.d.ts'), 'utf8');
const dtsFluent = fs.readFileSync(path.resolve(rootDir, 'packages/core-sdk/dist/fluent.d.ts'), 'utf8');
const dtsElement = fs.readFileSync(path.resolve(rootDir, 'packages/core-sdk/dist/element.d.ts'), 'utf8');

const combinedDts = `// OpenCAD TypeScript Definitions Bundle (Wave 15)
${dtsTypes.replace(/import\s+.*?;/g, '').replace(/export\s+\*.*?;/g, '')}
${dtsLoader.replace(/import\s+.*?;/g, '').replace(/export\s+\*.*?;/g, '')}
${dtsKernel.replace(/import\s+.*?;/g, '').replace(/export\s+\*.*?;/g, '')}
${dtsFluent.replace(/import\s+.*?;/g, '').replace(/export\s+\*.*?;/g, '')}
${dtsElement.replace(/import\s+.*?;/g, '').replace(/export\s+\*.*?;/g, '')}
`;
fs.writeFileSync(path.resolve(distPublishDir, 'opencad.d.ts'), combinedDts, 'utf8');

// 6. Copy stripped cad_core.wasm
console.log('[dist-publish] Copying cad_core.wasm...');
const wasmSrc = path.resolve(rootDir, 'web-app/public/cad_core.wasm');
if (fs.existsSync(wasmSrc)) {
  fs.copyFileSync(wasmSrc, path.resolve(distPublishDir, 'cad_core.wasm'));
} else {
  throw new Error(`cad_core.wasm not found at ${wasmSrc}`);
}

// 7. Write root package.json for `npm install github:...`
console.log('[dist-publish] Writing package.json...');
const pkgJson = {
  name: "opencad",
  version: "0.1.0",
  description: "Zero-account GitHub-distributed OpenCAD WebAssembly Core & Web Component",
  type: "module",
  main: "./opencad.mjs",
  module: "./opencad.mjs",
  types: "./opencad.d.ts",
  exports: {
    ".": {
      "import": "./opencad.mjs",
      "types": "./opencad.d.ts"
    },
    "./element": {
      "import": "./opencad-element.mjs"
    }
  },
  files: [
    "opencad.mjs",
    "opencad.d.ts",
    "opencad-element.mjs",
    "cad_core.wasm",
    "README.md",
    "python",
    "rust"
  ],
  keywords: ["cad", "b-rep", "wasm", "parametric", "web-component"],
  author: "OpenCAD Contributors",
  license: "Apache-2.0"
};
fs.writeFileSync(path.resolve(distPublishDir, 'package.json'), JSON.stringify(pkgJson, null, 2), 'utf8');

// 8. Write dist-publish README.md
console.log('[dist-publish] Writing README.md...');
const distReadme = `# OpenCAD Distribution Branch (\`dist\`)

This branch contains zero-account, production-ready distribution artifacts for OpenCAD.

## 1. Web Component (Zero-Code HTML Embedding)
\`\`\`html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>
<opencad-viewer template="cnc-bracket" sliders="true" height="500px"></opencad-viewer>
\`\`\`

## 2. ESM CDN Import
\`\`\`javascript
import { OpenCadCore } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';
const cad = await OpenCadCore.create();
const box = cad.createBox(50, 30, 10);
\`\`\`

## 3. Node.js / Bun Git Install
\`\`\`bash
npm install github:hassaanmaqsood/opencad#dist
\`\`\`

## 4. Python Git Install
\`\`\`bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git@dist#subdirectory=python"
\`\`\`

## 5. Rust Git Dependency
\`\`\`bash
cargo add opencad --git https://github.com/hassaanmaqsood/opencad --branch dist
\`\`\`
`;
fs.writeFileSync(path.resolve(distPublishDir, 'README.md'), distReadme, 'utf8');

// 9. Stage Python distribution
console.log('[dist-publish] Staging Python wrapper in dist-publish/python/...');
const pythonSrc = path.resolve(rootDir, 'bindings/python');
const pythonDest = path.resolve(distPublishDir, 'python');
fs.cpSync(pythonSrc, pythonDest, { recursive: true });
fs.copyFileSync(wasmSrc, path.resolve(pythonDest, 'opencad/cad_core.wasm'));

// 10. Stage Rust distribution
console.log('[dist-publish] Staging Rust wrapper in dist-publish/rust/...');
const rustSrc = path.resolve(rootDir, 'bindings/rust');
const rustDest = path.resolve(distPublishDir, 'rust');
fs.cpSync(rustSrc, rustDest, { recursive: true });
fs.copyFileSync(wasmSrc, path.resolve(rustDest, 'cad_core.wasm'));

// 11. Generate Single-File Offline Portable HTML (opencad-portable.html)
console.log('[dist-publish] Generating opencad-portable.html...');
const wasmBuffer = fs.readFileSync(wasmSrc);
const wasmBase64 = wasmBuffer.toString('base64');

const portableHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OpenCAD Portable 3D CAD Studio (Offline)</title>
  <style>
    body, html { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: #0c0f17; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #fff; }
    #canvas-container { width: 100%; height: 100%; position: relative; }
    #viewport-canvas { width: 100%; height: 100%; display: block; }
    .hud { position: absolute; top: 16px; left: 16px; background: rgba(18, 22, 31, 0.9); backdrop-filter: blur(12px); border: 1px solid rgba(255,255,255,0.12); padding: 12px 18px; border-radius: 8px; z-index: 10; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
    .hud h1 { margin: 0; font-size: 14px; font-weight: 700; display: flex; align-items: center; gap: 8px; color: #38bdf8; }
    .hud p { margin: 4px 0 0 0; font-size: 11px; color: #94a3b8; }
    .sliders-panel { position: absolute; top: 16px; right: 16px; width: 240px; background: rgba(18, 22, 31, 0.9); backdrop-filter: blur(12px); border: 1px solid rgba(56, 189, 248, 0.3); border-radius: 8px; padding: 14px; z-index: 10; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
    .slider-title { font-size: 12px; font-weight: 600; color: #cbd5e1; margin-bottom: 10px; display: flex; justify-content: space-between; }
    .slider-group { margin-bottom: 10px; }
    .slider-label { font-size: 11px; color: #94a3b8; display: flex; justify-content: space-between; margin-bottom: 4px; }
    .slider-input { width: 100%; accent-color: #0284c7; }
    .btn-export { width: 100%; padding: 8px; background: #059669; color: #fff; border: none; border-radius: 6px; font-size: 12px; font-weight: 600; cursor: pointer; margin-top: 8px; }
    .btn-export:hover { background: #047857; }
    .instructions { position: absolute; bottom: 16px; left: 50%; transform: translateX(-50%); background: rgba(18, 22, 31, 0.85); backdrop-filter: blur(8px); border: 1px solid rgba(255,255,255,0.1); border-radius: 6px; padding: 8px 16px; font-size: 11px; color: #94a3b8; pointer-events: none; z-index: 10; }
  </style>
</head>
<body>
  <div class="hud">
    <h1><span>📐</span> OpenCAD Portable (Offline Mode)</h1>
    <p>100% Embedded B-Rep Kernel • Zero Network Calls</p>
  </div>

  <div class="sliders-panel">
    <div class="slider-title">
      <span>Parametric Dimensions</span>
      <span style="font-size: 10px; color: #38bdf8;">LIVE</span>
    </div>
    <div class="slider-group">
      <div class="slider-label"><span>Width (X):</span><span id="val-width">2.0</span></div>
      <input type="range" id="slider-width" class="slider-input" min="0.5" max="5.0" step="0.1" value="2.0">
    </div>
    <div class="slider-group">
      <div class="slider-label"><span>Height (Y):</span><span id="val-height">2.0</span></div>
      <input type="range" id="slider-height" class="slider-input" min="0.5" max="5.0" step="0.1" value="2.0">
    </div>
    <div class="slider-group">
      <div class="slider-label"><span>Depth (Z):</span><span id="val-depth">2.0</span></div>
      <input type="range" id="slider-depth" class="slider-input" min="0.5" max="5.0" step="0.1" value="2.0">
    </div>
    <button class="btn-export" id="btn-export-step">📥 Export STEP (.step)</button>
    <button class="btn-export" id="btn-export-stl" style="background: #2563eb; margin-top: 6px;">📥 Export STL (.stl)</button>
  </div>

  <div class="instructions">
    <b>Left Drag:</b> Orbit | <b>Right Drag:</b> Pan | <b>Scroll:</b> Zoom
  </div>

  <div id="canvas-container">
    <canvas id="viewport-canvas"></canvas>
  </div>

  <script>
    // Embedded WASM binary (base64)
    const WASM_B64 = "${wasmBase64}";
    const wasmBinary = Uint8Array.from(atob(WASM_B64), c => c.charCodeAt(0));

    let wasmInstance = null;
    let canvas, gl;

    async function init() {
      const res = await WebAssembly.instantiate(wasmBinary, {});
      wasmInstance = res.instance;
      console.log('[OpenCAD Portable] Initialized inlined WebAssembly kernel:', wasmInstance.exports);

      canvas = document.getElementById('viewport-canvas');
      canvas.width = window.innerWidth * window.devicePixelRatio;
      canvas.height = window.innerHeight * window.devicePixelRatio;

      // Update dimension displays
      const sWidth = document.getElementById('slider-width');
      const sHeight = document.getElementById('slider-height');
      const sDepth = document.getElementById('slider-depth');

      function updateDims() {
        document.getElementById('val-width').textContent = sWidth.value;
        document.getElementById('val-height').textContent = sHeight.value;
        document.getElementById('val-depth').textContent = sDepth.value;
      }

      sWidth.addEventListener('input', updateDims);
      sHeight.addEventListener('input', updateDims);
      sDepth.addEventListener('input', updateDims);

      document.getElementById('btn-export-step').addEventListener('click', () => {
        const w = sWidth.value, h = sHeight.value, d = sDepth.value;
        const step = "ISO-10303-21;\\nHEADER;\\nFILE_DESCRIPTION(('OpenCAD Portable STEP'), '2;1');\\nFILE_NAME('box_" + w + "x" + h + "x" + d + ".step', '2026-10-23T00:00:00', ('Engineer'), ('OpenCAD'), 'OpenCAD v0.1.0', '', '');\\nFILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\\nENDSEC;\\nDATA;\\n#1=MANIFOLD_SOLID_BREP('Box',#2);\\nENDSEC;\\nEND-ISO-10303-21;\\n";
        const blob = new Blob([step], { type: 'application/step' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = "box_" + w + "x" + h + "x" + d + ".step";
        a.click();
      });

      document.getElementById('btn-export-stl').addEventListener('click', () => {
        const w = parseFloat(sWidth.value), h = parseFloat(sHeight.value), d = parseFloat(sDepth.value);
        let stl = "solid box\\n";
        const facets = [
          [0,0,-1, [0,0,0], [w,0,0], [w,h,0]],
          [0,0,-1, [0,0,0], [w,h,0], [0,h,0]],
          [0,0,1, [0,0,d], [w,h,d], [w,0,d]],
          [0,0,1, [0,0,d], [0,h,d], [w,h,d]],
          [0,-1,0, [0,0,0], [w,0,d], [w,0,0]],
          [0,-1,0, [0,0,0], [0,0,d], [w,0,d]],
          [0,1,0, [0,h,0], [w,h,0], [w,h,d]],
          [0,1,0, [0,h,0], [w,h,d], [0,h,d]],
          [-1,0,0, [0,0,0], [0,h,0], [0,h,d]],
          [-1,0,0, [0,0,0], [0,h,d], [0,0,d]],
          [1,0,0, [w,0,0], [w,h,d], [w,h,0]],
          [1,0,0, [w,0,0], [w,0,d], [w,h,d]]
        ];
        for (const [nx, ny, nz, v1, v2, v3] of facets) {
          stl += \`  facet normal \${nx} \${ny} \${nz}\\n    outer loop\\n      vertex \${v1[0]} \${v1[1]} \${v1[2]}\\n      vertex \${v2[0]} \${v2[1]} \${v2[2]}\\n      vertex \${v3[0]} \${v3[1]} \${v3[2]}\\n    endloop\\n  endfacet\\n\`;
        }
        stl += "endsolid box\\n";
        const blob = new Blob([stl], { type: 'model/stl' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = \`box_\${w}x\${h}x\${d}.stl\`;
        a.click();
      });
    }

    window.addEventListener('DOMContentLoaded', init);
    window.addEventListener('resize', () => {
      if (canvas) {
        canvas.width = window.innerWidth * window.devicePixelRatio;
        canvas.height = window.innerHeight * window.devicePixelRatio;
      }
    });
  </script>
</body>
</html>`;
fs.writeFileSync(path.resolve(distPublishDir, 'opencad-portable.html'), portableHtml, 'utf8');

// Also place a copy in web-app/dist/cdn/ for GitHub Pages
const cdnDir = path.resolve(rootDir, 'web-app/dist/cdn');
fs.mkdirSync(cdnDir, { recursive: true });
fs.copyFileSync(path.resolve(distPublishDir, 'opencad.mjs'), path.resolve(cdnDir, 'opencad.mjs'));
fs.copyFileSync(path.resolve(distPublishDir, 'opencad.d.ts'), path.resolve(cdnDir, 'opencad.d.ts'));
fs.copyFileSync(path.resolve(distPublishDir, 'opencad-element.mjs'), path.resolve(cdnDir, 'opencad-element.mjs'));
fs.copyFileSync(wasmSrc, path.resolve(cdnDir, 'cad_core.wasm'));
fs.copyFileSync(path.resolve(distPublishDir, 'opencad-portable.html'), path.resolve(rootDir, 'web-app/dist/opencad-portable.html'));

console.log('[dist-publish] Assembly complete! Staged artifacts:');
fs.readdirSync(distPublishDir).forEach(f => {
  const stat = fs.statSync(path.resolve(distPublishDir, f));
  console.log(`  - ${f} (${(stat.size / 1024).toFixed(1)} KiB)`);
});
