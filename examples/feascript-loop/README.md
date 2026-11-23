# OpenCAD ↔ FEAScript Closed-Loop CAD-to-FEA Demo

This example couples **OpenCAD** (freestanding Zig WebAssembly B-Rep/CDML kernel) and **FEAScript 0.4.1** (pure-JavaScript Finite Element solver) directly inside the browser with zero backend servers.

## Live Demo URLs

- **OpenCAD GitHub Pages:** `https://hassaanmaqsood.github.io/opencad/feascript-demo.html`
- **Frameless Embed Mode (for `feascript.com` / docs):** `https://hassaanmaqsood.github.io/opencad/feascript-demo.html?embed=true`

## How the Closed Loop Works

1. **OpenCAD Parametric Geometry (`cad_kernel.wasm` / `cad_core.wasm`):** Evaluates a CDML v1.0 cooling flange plate (`<chart>`, `<sketch>`, `<sweep>`) in shared linear memory (`SharedArrayBuffer`) and emits the 3D B-Rep mesh, AP214 STEP / Binary STL exports, and the exact 2D planar cross-section with named boundaries (`bottom`, `right`, `top`, `left`, `bore`).
2. **FEAScript 2D Thermal Solve (`FEAScriptModel` v0.4.1):** Meshes the 2D plate with triangular elements (`elements: "triangles"`, `elementOrder: "linear"`) and solves steady-state 2D heat conduction (`heatConduction`, `solver: { method: "lusolve" }`) with a constant-temperature bottom boundary and convection inside the cooling bore.
3. **Field Injection into OpenCAD (`0x1F0000`):** Samples FEAScript's exact finite-element solution via `evaluateSolution(model, result, points)` onto a `32 × 24 × 4` `Float32Array` at shared memory offset `0x1F0000`.
4. **OpenCAD Probe & Closed-Loop Optimization:** Re-evaluates CDML so OpenCAD's native `<probe type="face-mean" face-predicate="from_id('bore')" quantity="field_scalar(0, x, y, z, 25.0)"/>` reads FEAScript's live temperature field directly in Zig, projects temperatures onto the 3D B-Rep mesh, and iteratively adjusts `bore_r` until the target temperature is met within the CDML `<assert>` wall-thickness margin.

## Embedding on `feascript.com` (Cross-Origin Isolation via COOP/COEP or `coi-serviceworker.js`)

OpenCAD uses a single shared `WebAssembly.Memory` (`SharedArrayBuffer`), which requires Cross-Origin Isolation:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`)

On static hosts where custom HTTP response headers cannot be configured (such as GitHub Pages), include [`coi-serviceworker.js`](../../web-app/public/coi-serviceworker.js) on the same origin to enable Cross-Origin Isolation automatically.

### Option 1: Drop-in `<iframe>` on `feascript.com`

Serve the host page with COOP/COEP headers (or `coi-serviceworker.js`), then embed:

```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/feascript-demo.html?embed=true"
  width="100%"
  height="680"
  style="border: 1px solid #C8C0B4; border-radius: 6px;"
  loading="lazy"
  title="OpenCAD to FEAScript Closed-Loop Demo">
</iframe>
```

### Option 2: Self-Host on `feascript.com`

Copy [`web-app/public/feascript-demo.html`](../../web-app/public/feascript-demo.html) and [`web-app/public/coi-serviceworker.js`](../../web-app/public/coi-serviceworker.js) together into the same folder on `feascript.com` (for example `/tutorials/opencad-feascript-loop.html`). It loads FEAScript from `https://core.feascript.com/dist/feascript.esm.js` and OpenCAD's shared-memory WASM kernel from `https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/cad_core.wasm`.
