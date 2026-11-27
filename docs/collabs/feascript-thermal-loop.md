# FEAScript × OpenCAD — Closed-Loop Multi-Physics Thermal Coupling

This collaboration links **[OpenCAD](https://github.com/hassaanmaqsood/opencad)** (Zig and WebAssembly CAD kernel) with **[FEAScript v0.4.1](https://feascript.com/)** (JavaScript finite-element PDE solver by Nikos Chamakos) in a single browser loop.

- **Live Interactive Demo:** [`https://hassaanmaqsood.github.io/opencad/feascript-demo.html`](https://hassaanmaqsood.github.io/opencad/feascript-demo.html)
- **Modular Source Code:** [`examples/feascript-loop/`](https://github.com/hassaanmaqsood/opencad/tree/main/examples/feascript-loop)

## 1. Closed-Loop Architecture

You do not describe the part geometry twice. FEAScript reads its 2D planar domain and boundary names directly from OpenCAD's `<sketch>` through `cdmlToFEAScriptGeometry()`:

$$\nabla \cdot (k \nabla T) = 0 \text{ in }\Omega, \qquad -k\frac{\partial T}{\partial n} = h(T - T_\infty) \text{ on }\Gamma_{\text{bore}}$$

![FEAScript × OpenCAD Closed-Loop Thermal Coupling](/assets/math/collab-feascript-loop.svg)

1. **Pass 1 — OpenCAD B-Rep & CDML Sketch Extraction (`cdml-to-feascript.js`):**
   - Evaluates the CDML v1.0 document in `cad_kernel.wasm` to build the 3D B-Rep solid and bounding box.
   - Parses `<sketch>` wires with a zero-eval recursive-descent expression parser and Cox–de Boor rational NURBS evaluation (`evalNurbsPoint2D`).
   - Degree-1 `<curve>` segments stay single straight lines.
   - The converter splits degree $\ge 2$ NURBS curves and `<param-curve>` elements into short straight pieces that keep their CDML `id` as FEAScript boundary names.
2. **Pass 2 — FEAScript 2D Unstructured Triangular Thermal Solve (`feascript-solver.js`):**
   - Runs `FEAScriptModel` (`heatConduction`) with FEAScript's built-in 2D triangle mesher (`generateTriangleMesh`), which applies Delaunay refinement on top of Delaunator and Constrainautor with `robust-predicates` for geometric tests.
   - Maps Dirichlet (`constantTemperature`) and Robin (`convection`) boundary conditions directly to the CDML curve IDs.
3. **Pass 3 — Nearest-Wall Voxel Extrapolation & `0x1F0000` Memory Injection:**
   - Projects the 2D FEM temperature field onto a $32 \times 32 \times 8$ 3D voxel grid at WASM offset `0x1F0000`.
   - Grid points inside the bore hole copy the temperature of the nearest point on the bore wall. This removes trilinear blending error when OpenCAD evaluates `<probe id="mean_bore_temp">`.

## 2. Drop-In Reusable ES Modules (`examples/feascript-loop/js/`)

You can import the ES modules in `examples/feascript-loop/js/` directly into any browser application without a bundler:

| Module | Exported API | Purpose |
| :--- | :--- | :--- |
| **`opencad-bridge.js`** | `OpenCadBridge.create(options)` | Instantiates `cad_kernel.wasm` with `SharedArrayBuffer` or plain `WebAssembly.Memory`, evaluates CDML, writes `0x1F0000` voxel grids, reads `<probe>` values, and exports STEP and STL. |
| **`cdml-to-feascript.js`** | `cdmlToFEAScriptGeometry(xmlStr, opts)`<br>`evalCdmlScalar(expr, env)`<br>`evalNurbsPoint2D(ctrl, w, knots, p, t)` | Converts a CDML `<sketch>` (`outer` and `hole` wires, `<curve>`, `<param-curve>`, `<line>`) into FEAScript `{ shape, holes }` in SI meters. |
| **`feascript-solver.js`** | `solveThermal2D(cdmlGeom, params)`<br>`buildNearestWallFieldGrid(fem, bbox, params)` | Runs FEAScript `0.4.1`, computes boundary temperature statistics, and builds the nearest-wall 3D voxel field buffer. |
| **`custom-loop.js`** | `runCustomFEAScriptLoop(config)`<br>`runCustomCoupledStep(config)` | Browser ES module that replaces the legacy `run-closed-loop.mjs` script. Couples custom CDML generators, FEAScript boundary conditions, `0x1F0000` field injection, and `step(state, iter)` loops. |
| **`viewports.js`** | `Thermal3DViewport`<br>`Fem2DViewport`<br>`thermalRGB(tNorm)` | Renders the 3D Three.js B-Rep mesh and 2D HTML5 Canvas FEM mesh using a calibrated Matplotlib `plasma` colormap. |

### Minimal Usage Snippet

```js
import { OpenCadBridge } from './js/opencad-bridge.js';
import { cdmlToFEAScriptGeometry } from './js/cdml-to-feascript.js';
import { solveThermal2D, buildNearestWallFieldGrid } from './js/feascript-solver.js';

// 1. Boot OpenCAD WASM kernel & evaluate CDML v1.0 document
const cad = await OpenCadBridge.create();
const pass1 = cad.evalCdml(cdmlXml);

// 2. Extract 2D FEAScript domain & boundary names directly from CDML <sketch>
const cdmlGeom = cdmlToFEAScriptGeometry(cdmlXml, { holeSamples: 48, nurbsSamples: 16 });

// 3. Solve 2D steady-state heat conduction in FEAScript v0.4.1
const fem = solveThermal2D(cdmlGeom, params);

// 4. Write nearest-wall extrapolated 3D temperature field to 0x1F0000 & re-probe
const fieldGrid = buildNearestWallFieldGrid(fem, pass1.bbox, params);
cad.writeFieldBuffer(fieldGrid);
const pass2 = cad.evalCdml(cdmlXml);

console.log('FEM Bore Wall Mean T:', fem.boreMeanT.toFixed(2), '°C');
console.log('OpenCAD 3D Bore Probe T:', pass2.boreTempProbe.toFixed(2), '°C');
```

### Custom Closed-Loop Runner (`./js/custom-loop.js`)

In earlier drafts, a standalone script (`run-closed-loop.mjs`) ran the coupled loop. In the repository, `./examples/feascript-loop/js/custom-loop.js` replaces that script as a reusable ES module. FEAScript users can import `runCustomFEAScriptLoop` to run a custom multi-iteration loop with their own CDML XML, boundary conditions, and convergence logic:

```js
import { runCustomFEAScriptLoop } from './js/custom-loop.js';

const result = await runCustomFEAScriptLoop({
  cdml: (p) => buildCustomPartCdml(p),
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

## 3. Analytical Benchmark Verification (Annular Disk)

The demo includes an analytical benchmark preset (**Annular Disk**):
- Outer radius $b = 30\text{ mm}$ (`id="rim"`), Dirichlet $T(b) = 180\text{ °C}$
- Inner bore radius $a = 9\text{ mm}$ (`id="bore"`), Robin convection $h = 540\text{ W/m}^2\text{K}$ to $T_\infty = 25\text{ °C}$
- Thermal conductivity $k = 15\text{ W/mK}$

The exact radial temperature distribution is:

$$T(r) = T_b - \frac{q'}{2\pi k}\ln\!\left(\frac{b}{r}\right), \qquad q' = \frac{2\pi(T_b - T_\infty)}{\frac{1}{h a} + \frac{\ln(b/a)}{k}} = 3404.9\text{ W/m}$$

This equation gives $T(a) = 136.50\text{ °C}$ on the bore wall ($r = 9.00\text{ mm}$) and $T(15.00\text{ mm}) = 154.96\text{ °C}$ at mid-radius. At the probe sampling radius ($r = 9.15\text{ mm}$), the exact temperature is $137.10\text{ °C}$. Both FEAScript and OpenCAD's 3D `<probe>` read at $r = 9.15\text{ mm}$ and match $137.10\text{ °C}$ within $0.05\text{ K}$.
