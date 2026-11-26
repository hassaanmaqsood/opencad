# OpenCAD × FEAScript Closed-Loop Thermal CAD/FEM Example

This example demonstrates a complete, closed-loop browser integration between **[OpenCAD](https://github.com/hassaanmaqsood/opencad)** (parametric B-Rep & implicit CAD kernel compiled to WebAssembly) and **[FEAScript](https://feascript.com/)** (browser/Node.js finite-element PDE library), rendered with **[Three.js](https://threejs.org/)**.

The codebase is intentionally structured so that **CSS**, **external CDN dependencies**, and **reusable JavaScript modules** are cleanly separated—allowing you to drop the helper classes and functions directly into your own CAD/CAE web applications.

---

## 1. Directory & Dependency Structure

```text
examples/feascript-loop/
├── index.html                  # Clean HTML entry point with <script type="importmap">
├── styles/
│   └── demo.css                # Monograph & Paper Surface UI stylesheet (DESIGN.md)
├── js/
│   ├── opencad-bridge.js       # Drop-in class: OpenCadBridge (WASM memory & zero-copy ABI)
│   ├── cdml-to-feascript.js    # Drop-in converter: cdmlToFEAScriptGeometry(cdmlString)
│   ├── feascript-solver.js     # Drop-in solver: solveThermal2D() & buildNearestWallFieldGrid()
│   ├── viewports.js            # Drop-in renderers: Thermal3DViewport & Fem2DViewport
│   ├── cdml-presets.js         # Parametric CDML XML generators (Cooling Plate & Annular Disk)
│   └── main.js                 # UI controller (lil-gui, telemetry HUD, CSV/STL export)
├── run-closed-loop.mjs         # Headless Node.js / Playwright verification runner
└── README.md                   # Documentation & drop-in module usage guide
```

### External Dependencies vs. Local Modules

All third-party libraries are pinned via an HTML `<script type="importmap">` in [`index.html`](./index.html) and require **zero bundler or build step**:

| Dependency | Version | Source (CDN Import Map) | Purpose |
| :--- | :--- | :--- | :--- |
| **`feascript`** | `0.4.1` | `https://cdn.jsdelivr.net/npm/feascript@0.4.1/dist/feascript.esm.js` | 2D finite-element thermal solver & unstructured Gmsh WASM mesher |
| **`three`** | `0.170.0` | `https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js` | WebGL 3D B-Rep viewport, vertex heatmap coloring & `OrbitControls` |
| **`lil-gui`** | `0.20.0` | `https://cdn.jsdelivr.net/npm/lil-gui@0.20.0/dist/lil-gui.esm.min.js` | Reactive parameter and boundary-condition control panel |
| **`cad_kernel.wasm`** | `0.1.0` | Auto-resolved locally (`./cad_kernel.wasm` or `../../web-app/public/cad_kernel.wasm`) or jsDelivr CDN | OpenCAD Zig B-Rep & implicit field kernel |

---

## 2. Drop-In JavaScript Modules (`./js/`)

Each file in `./js/` is an independent ES module exporting reusable classes or pure functions.

### A. `js/opencad-bridge.js` — `OpenCadBridge` Class
Wraps the OpenCAD WebAssembly kernel, handling memory initialization (`SharedArrayBuffer` with automatic fallback to plain `WebAssembly.Memory`), 3D field injection at `0x1F0000`, CDML evaluation, zero-copy typed-array extraction, and binary STL export.

```js
import { OpenCadBridge } from './js/opencad-bridge.js';

const cad = await OpenCadBridge.create(); // Auto-discovers cad_kernel.wasm
const result = cad.evalCDML(cdmlXmlString, optionalFieldGridFloat32);

console.log(result.triangleCount, result.telemetry.probes);
// Zero-copy Float32Array / Uint32Array views:
// result.vertices, result.normals, result.indices, result.faceIds, result.edges
```

### B. `js/cdml-to-feascript.js` — `cdmlToFEAScriptGeometry()`
Reads a single declarative OpenCAD CDML `<sketch>` (`<line>`, `<arc>`, `<circle>` tags with parametric expressions) and converts the outer profile and internal hole contours directly into FEAScript `geometryPoints`, `holePoints`, and a `boundaryMap` preserving curve `id` attributes as FEAScript boundary names.

```js
import { cdmlToFEAScriptGeometry } from './js/cdml-to-feascript.js';

const femGeo = cdmlToFEAScriptGeometry(cdmlXmlString, { arcSegments: 64 });
// femGeo.geometryPoints -> [[x0, y0], ...] (meters)
// femGeo.holePoints     -> [[[hx0, hy0], ...]] (meters)
// femGeo.boundaryMap    -> { bottom_heated: '1', coolant_hole: ['5', ...], ... }
```

### C. `js/feascript-solver.js` — `solveThermal2D()` & `buildNearestWallFieldGrid()`
1. **`solveThermal2D(femGeo, bcSpec)`**: Builds a `FEAScriptModel` (`heatConductionScript`, `2D`), generates an unstructured 2D Gmsh mesh from `femGeo`, applies named `constantTemp` (Dirichlet) and `convection` (Robin) boundary conditions, and returns the nodal solution, 2D triangle connectivity, and fast barycentric `evaluateSolution(x, y)` interpolator.
2. **`buildNearestWallFieldGrid(fem, femGeo)`**: Samples the 2D FEM temperature solution onto OpenCAD's $32 \times 32 \times 8$ trilinear voxel grid (`Float32Array(8192)`). Any grid point inside an internal bore (`NaN` in the 2D mesh) is assigned the temperature of the **nearest point on the bore wall**, eliminating trilinear boundary interpolation bias on `<probe>` surfaces.

```js
import { solveThermal2D, buildNearestWallFieldGrid } from './js/feascript-solver.js';

const fem = await solveThermal2D(femGeo, {
  boundaryConditions: {
    rim: { type: 'constantTemp', temperature: 180 },
    coolant_hole: { type: 'convection', h: 540, k: 15, extTemp: 25 },
  },
});

const fieldGrid = buildNearestWallFieldGrid(fem, femGeo);
const brep = cad.evalCDML(cdmlXmlString, fieldGrid);
```

### D. `js/viewports.js` — `Thermal3DViewport` & `Fem2DViewport`
- **`Thermal3DViewport`**: Drop-in Three.js WebGL component that renders OpenCAD B-Rep meshes with subdivided thermal vertex coloring, dark feature edges, and architectural grid lines on a `#FFFFFF` Monograph paper surface.
- **`Fem2DViewport`**: Drop-in 2D HTML5 Canvas renderer that draws unstructured FEAScript triangles, temperature fills, and labeled boundary curves (`y = H`, `y = 0`, `r = a`, `r = b`).

---

## 3. Running Locally

### In the Browser
From the repository root, start the development server (or any static HTTP server):

```bash
npm --prefix web-app run dev
```

Open:
- **Bundled Demo in `web-app/public`**: `http://localhost:5173/feascript-demo.html`

Or serve `examples/feascript-loop/` directly from the repository root with any static server (e.g., `npx serve .`) and open `/examples/feascript-loop/index.html`.

### Headless Verification (Analytical Annular Disk Benchmark & Cooling Plate)
included is an automated benchmark verification test comparing the CDML → FEAScript → OpenCAD `<probe>` loop against the exact Lamé / Fourier analytical solution for an annular disk ($b = 30\text{ mm}$ at $180\text{ }^\circ\text{C}$, $a = 9\text{ mm}$ with $h = 540\text{ W/m}^2\text{K}$ to $25\text{ }^\circ\text{C}$, $k = 15\text{ W/mK}$, exact bore temperature $136.50\text{ }^\circ\text{C}$):

```bash
node examples/feascript-loop/run-closed-loop.mjs
```
