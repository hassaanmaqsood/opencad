# FEAScript × OpenCAD — Modular Drop-In Multi-Physics Example

This example couples **[OpenCAD](https://github.com/hassaanmaqsood/opencad)** (parametric B-Rep and implicit CAD kernel in WebAssembly) with **[FEAScript v0.4.1](https://feascript.com/)** (browser and Node.js finite-element PDE library). It renders both the 3D solid and the 2D unstructured FEM mesh in the browser.

- **Live Demo:** [`https://hassaanmaqsood.github.io/opencad/feascript-demo.html`](https://hassaanmaqsood.github.io/opencad/feascript-demo.html)

---

## 1. Directory Structure

The HTML shell, stylesheet, and reusable ES modules live in separate folders:

```text
examples/feascript-loop/
├── index.html                  # HTML5 shell + CDN importmap (Three.js, lil-gui, FEAScript 0.4.1)
├── coi-serviceworker.js        # Same-origin COOP/COEP service worker
├── styles/
│   └── demo.css                # OpenCAD Design System stylesheet (Cobalt Azure + Plasma)
└── js/
    ├── cdml-to-feascript.js    # Zero-eval CDML <sketch> & NURBS to FEAScript 2D converter
    ├── opencad-bridge.js       # WebAssembly bridge for cad_kernel.wasm & 0x1F0000 field grid
    ├── feascript-solver.js     # FEAScript 0.4.1 2D thermal solver & nearest-wall extrapolator
    ├── viewports.js            # 3D Three.js B-Rep + 2D HTML5 Canvas viewports (Plasma colormap)
    ├── cdml-presets.js         # Parametric CDML generators (Cooling Plate & Annular Disk)
    ├── custom-loop.js          # Drop-in custom CDML + FEAScript closed-loop runner
    └── main.js                 # UI controller wiring lil-gui, dock actions, and closed loop
```

---

## 2. Drop-In Reusable Modules (`./js/`)

### 2.1 `cdmlToFEAScriptGeometry(xmlStr, options)` (`./js/cdml-to-feascript.js`)
Reads the outer and hole `<wire>` outlines from an OpenCAD CDML `<sketch>`. It evaluates math expressions with a zero-eval parser. It splits degree $\ge 2$ NURBS `<curve>` and `<param-curve>` elements into segments that keep their curve IDs as boundary names.

```js
import { cdmlToFEAScriptGeometry } from './js/cdml-to-feascript.js';

const { geometry, boundaryNames, vars } = cdmlToFEAScriptGeometry(cdmlXml, {
  holeSamples: 48,
  outerCurveSamples: 72,
  nurbsSamples: 16,
  unitScale: 0.001, // Converts CDML millimeters to SI meters
});
```

### 2.2 `OpenCadBridge` (`./js/opencad-bridge.js`)
Wraps `cad_kernel.wasm` linear memory (`SharedArrayBuffer` or plain `WebAssembly.Memory` fallback), CDML evaluation, `0x0F0000` tessellation slices, `0x1F0000` voxel field injection, `<probe>` queries, and STEP / STL exports.

```js
import { OpenCadBridge } from './js/opencad-bridge.js';

const cad = await OpenCadBridge.create();
const pass1 = cad.evalCdml(cdmlXml, ['plate_volume', 'mean_bore_temp']);
```

### 2.3 `solveThermal2D` & `buildNearestWallFieldGrid` (`./js/feascript-solver.js`)
Runs FEAScript `0.4.1` on the converted CDML domain and builds a $32 \times 32 \times 8$ 3D voxel temperature field for OpenCAD. Grid points inside the bore hole copy the temperature of the nearest bore wall point. This keeps trilinear interpolation on the bore surface exact.

```js
import { solveThermal2D, buildNearestWallFieldGrid } from './js/feascript-solver.js';

const fem = solveThermal2D(cdmlGeom, params);
const fieldGrid = buildNearestWallFieldGrid(fem, pass1.bbox, params);
cad.writeFieldBuffer(fieldGrid);
const pass2 = cad.evalCdml(cdmlXml);
```

### 2.4 `runCustomFEAScriptLoop` & `runCustomCoupledStep` (`./js/custom-loop.js`)
Allows FEAScript users to couple a custom CDML model with custom FEAScript solver settings, boundary conditions, `0x1F0000` 3D field injection, and a custom iteration callback:

```js
import { runCustomFEAScriptLoop } from './js/custom-loop.js';

const loopResult = await runCustomFEAScriptLoop({
  cdml: (p) => myCustomCdmlBuilder(p),
  params: { r: 6.0, k: 22.0, targetT: 98.0 },
  gridSize: [36, 28, 4],
  boundaryConditions: () => ({
    hot_wall:     { type: 'constantTemperature', temperature: 165.0 },
    top_wall:     { type: 'convection', h: 30.0, ambientTemperature: 25.0 },
    cool_channel: { type: 'convection', h: 320.0, ambientTemperature: 25.0 },
  }),
  maxIterations: 6,
  step: (state) => {
    if (state.probes.channel_wall_temp <= state.params.targetT) {
      return { done: true };
    }
    return { done: false, nextParams: { r: state.params.r + 2.0 } };
  },
});
```

---

## 3. Analytical Benchmark: Annular Disk with Centered Bore

Switch **CDML Model** in the parameter panel to **`Annular Disk (Benchmark)`**:
- **Outer radius:** $b = 30\text{ mm}$, boundary `id="rim"` at $T_b = 180\text{ °C}$
- **Bore radius:** $a = 9\text{ mm}$, boundary `id="bore"` with convection $h = 540\text{ W/m}^2\text{K}$ to $T_\infty = 25\text{ °C}$
- **Thermal conductivity:** $k = 15\text{ W/mK}$

Exact radial solution:
$$T(r) = 180 - \frac{q' \ln(b/r)}{2\pi k}, \quad q' = 3404.9\text{ W/m}$$
- Exact temperature on bore wall ($r = 9.00\text{ mm}$): **$136.50\text{ °C}$**
- Exact temperature at probe sampling radius ($r = 9.15\text{ mm}$): **$137.10\text{ °C}$**
- Exact temperature at mid-radius ($r = 15.00\text{ mm}$): **$154.96\text{ °C}$**

---

## 4. Running Locally

Start the local web server from the repository root:

```bash
npm --prefix web-app run dev
```

Open `http://localhost:5173/feascript-demo.html` in your browser.
