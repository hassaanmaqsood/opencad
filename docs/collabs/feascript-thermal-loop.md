# FEAScript × OpenCAD — Closed-Loop Multi-Physics Thermal Coupling

This collaboration integrates **[OpenCAD](https://github.com/hassaanmaqsood/opencad)** (parametric B-Rep & implicit CAD kernel in Zig/WebAssembly) with **[FEAScript v0.4.1](https://feascript.com/)** (pure JavaScript finite-element PDE solver by Nikos Chamakos) in a single browser loop.

- **Live Interactive Demo:** [`https://hassaanmaqsood.github.io/opencad/feascript-demo.html`](https://hassaanmaqsood.github.io/opencad/feascript-demo.html)
- **Modular Source Code:** [`examples/feascript-loop/`](https://github.com/hassaanmaqsood/opencad/tree/main/examples/feascript-loop)

---

## 1. Closed-Loop Architecture

Rather than describing geometry twice (once in CAD and once by hand for the FEM mesh generator), FEAScript extracts its 2D planar domain and boundary names directly from OpenCAD's `<sketch>` via `cdmlToFEAScriptGeometry()`:

$$\nabla \cdot (k \nabla T) = 0 \;\;\text{in }\Omega, \qquad -k\frac{\partial T}{\partial n} = h(T - T_\infty) \;\;\text{on }\Gamma_{\text{bore}}$$

![FEAScript × OpenCAD Closed-Loop Thermal Coupling](/assets/math/collab-feascript-loop.svg)

1. **Pass 1 — OpenCAD B-Rep & CDML Sketch Extraction (`cdml-to-feascript.js`):**
   - Evaluates the CDML v1.0 document in `cad_kernel.wasm` to generate the 3D B-Rep solid and bounding box.
   - Parses `<sketch>` wires using a **zero-eval recursive-descent CDML expression parser** (no `Function()` or `eval()`) and **exact Cox–de Boor rational NURBS evaluation** (`evalNurbsPoint2D`).
   - Degree-1 `<curve>` segments remain single straight lines; degree $\ge 2$ NURBS curves (arcs, fillets, splines) and `<param-curve>` elements are discretized into polygonal segments that preserve their CDML `id` as FEAScript boundary names.
2. **Pass 2 — FEAScript 2D Unstructured Triangular Thermal Solve (`feascript-solver.js`):**
   - Runs `FEAScriptModel` (`heatConductionScript`, 2D unstructured triangular mesh via Gmsh WASM) with Dirichlet (`constantTemp`) and Robin (`convection`) boundary conditions mapped directly to the CDML curve IDs.
3. **Pass 3 — Nearest-Wall Voxel Extrapolation & `0x1F0000` Shared-Memory Injection:**
   - Projects the 2D FEM temperature field onto a $32 \times 32 \times 8$ 3D voxel grid at WASM offset `0x1F0000`.
   - Voxel grid nodes inside the cooling bore (where the 2D FEM mesh has no elements) receive the exact temperature of the **nearest point on the bore boundary wall**, eliminating trilinear interpolation bias when OpenCAD evaluates `<probe id="mean_bore_temp">`.

---

## 2. Drop-In Reusable ES Modules (`examples/feascript-loop/js/`)

Every script in `examples/feascript-loop/js/` is written as a standalone, zero-build ES module that you can drop into your own engineering web application:

| Module | Exported API | Purpose |
| :--- | :--- | :--- |
| **`opencad-bridge.js`** | `OpenCadBridge.create(options)` | Instantiates `cad_kernel.wasm` using `SharedArrayBuffer` (or falls back automatically to plain `WebAssembly.Memory` when `COOP/COEP` headers are absent), evaluates CDML, injects `0x1F0000` voxel grids, reads `<probe>` values, and exports STEP / STL. |
| **`cdml-to-feascript.js`** | `cdmlToFEAScriptGeometry(xmlStr, opts)`<br>`evalCdmlScalar(expr, env)`<br>`evalNurbsPoint2D(ctrl, w, knots, p, t)` | Converts any CDML `<sketch>` (`outer` and `hole` wires, `<curve degree="1..p">`, `<param-curve>`, `<line>`) into FEAScript `{ shape, holes }` in SI meters while keeping curve IDs as boundary names. |
| **`feascript-solver.js`** | `solveThermal2D(cdmlGeom, params)`<br>`buildNearestWallFieldGrid(fem, bbox, params)` | Configures and runs FEAScript `0.4.1`, extracts boundary temperature statistics, and builds the nearest-wall extrapolated 3D voxel field buffer. |
| **`viewports.js`** | `Thermal3DViewport`<br>`Fem2DViewport`<br>`thermalRGB(tNorm)` | Synchronized 3D Three.js B-Rep viewport (with adaptive triangle subdivision and sRGB-to-linear calibrated Matplotlib `plasma` vertex colors) and 2D HTML5 Canvas FEM mesh contour viewer. |

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

---

## 3. Analytical Benchmark Verification (Annular Disk)

The demo includes an exact analytical benchmark preset (**Annular Disk**):
- Outer radius $b = 30\text{ mm}$ (`id="rim"`), Dirichlet $T(b) = 180\text{ °C}$
- Inner bore radius $a = 9\text{ mm}$ (`id="bore"`), Robin convection $h = 540\text{ W/m}^2\text{K}$ to $T_\infty = 25\text{ °C}$
- Thermal conductivity $k = 15\text{ W/mK}$

The exact closed-form radial temperature distribution is:

$$T(r) = T_b - \frac{q'}{2\pi k}\ln\!\left(\frac{b}{r}\right), \qquad q' = \frac{2\pi(T_b - T_\infty)}{\frac{1}{h a} + \frac{\ln(b/a)}{k}} = 3404.9\text{ W/m}$$

This yields $T(a) = 136.50\text{ °C}$ on the bore wall and $T(15\text{ mm}) = 154.96\text{ °C}$ at mid-radius, which both FEAScript and OpenCAD's 3D `<probe>` match within $0.05\text{ K}$.
