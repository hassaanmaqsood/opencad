# OpenCAD (`open-parametric-cad` v2.0)

> **Pure-Math Computational CAD Kernel, CDML v1.0 Compiler, Responsive Flex Studio & Minimal Embed Viewer.**  
> Powered by Zig (`wasm32-freestanding`), SharedArrayBuffer Zero-Copy Memory, TypeScript, Python (`wasmtime`), and Three.js.

[![Live Studio](https://img.shields.io/badge/Live_Studio-hassaanmaqsood.github.io%2Fopencad-blue?style=for-the-badge&logo=googlechrome)](https://hassaanmaqsood.github.io/opencad/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig Tests](https://img.shields.io/badge/Zig_Unit_Tests-198%2F198_Passed-brightgreen.svg)](./kernel-zig)
[![Anti-Cheat Gates](https://img.shields.io/badge/Verification_Gates-All_9_Passed-success.svg)](./scripts/verify_gates.sh)
[![Zero-Primitive Law](https://img.shields.io/badge/Architecture-Zero--Primitive_Pure--Math-blueviolet.svg)](./kernel-zig/src/main.zig)

---

## ⚠️ Stability & Transparency Notice (Experimental State)

OpenCAD is under active development. While core mathematical engines (Automatic Differentiation, exact kinematic sweeps, TPMS implicit fields, and SharedArrayBuffer tessellation) pass strict verification suites, several advanced CAD modules remain **experimental and unstable**:

- **Variational Nonlinear Constraint Solver:** The Householder QR / Newton-Raphson solver converges reliably for well-posed orthogonal frames and convex profiles. Over-constrained sketches, near-collinear tangent constraints, and degenerate loop topologies can experience non-convergence or cycle limits.
- **Multi-Body CSG Booleans:** Straddling-triangle mesh boolean operations are stable for regular volumetric intersections. Coplanar face intersections, zero-clearance tangent contacts (e.g. hole bores tangent to outer boundary walls), and non-manifold edge contacts may exhibit localized topological artifacts.
- **Rolling-Ball Filleting:** Analytic edge-predicate fillets operate cleanly on uniform convex/concave lateral edges. Complex multi-edge apex corner transitions and variable-radius sweeps with high curvature ratios are actively being hardened.
- **API & CDML Schema Evolution:** Interfaces are evolving as we advance toward Turing-complete scripting. Semantic versioning guarantees will stabilize upon v2.1.

---

## 🏛️ Architectural Highlights

OpenCAD is built on a **Zero-Primitive Pure-Math Architecture**: no hardcoded `box`, `cylinder`, or `sphere` primitives exist in the engine. All geometry is synthesized from first mathematical principles across four core pillars:

1. **Pure-Math Kernel (`cad_kernel.wasm`):**
   - Synthesizes geometry via **18 canonical C-ABI functions**: forward-mode Automatic Differentiation ([`autodiff.zig`](./kernel-zig/src/math/autodiff.zig)), Householder QR nonlinear constraint solving ([`constraint_sys.zig`](./kernel-zig/src/math/constraint_sys.zig)), rational NURBS curves & wires ([`curve_wire.zig`](./kernel-zig/src/geom/curve_wire.zig)), $SE(3)$ kinematic sweeps and watertight revolutions ([`surface_brep.zig`](./kernel-zig/src/surface_brep.zig)), bivariate tensor-product NURBS lofts, rolling-ball fillets, non-destructive offset shells, analytic inequality regions, and interval-pruned octree QEF Dual Contouring ([`implicit_field.zig`](./kernel-zig/src/implicit/implicit_field.zig)).
2. **CDML v1.0 (Computational Design Markup Language):**
   - Declarative engineering markup combining `<imports>`, parametric `<defs>` (`<var>`, `<expr>`, `<field-slot>`, `<assert>`), orthonormal `<chart>` frames, constrained `<sketch>` profiles, `<region>` half-spaces, `<brep>` sweeps, revolves, and fillets, `<implicit>` TPMS lattices, straddling-triangle `<csg>` booleans, physical `<probe>` queries, and production `<exports>` (`<tessellate>`, `<step>`, `<stl>`).
3. **Single `SharedArrayBuffer` Zero-Copy Memory (`0x000000`–`0x5F0000`):**
   - Unified linear memory connecting `cad_kernel.wasm`, external field WASM extensions (`ext_field_canary.wasm` writing 3D stress voxels at `0x1F0000`), and the Three.js WebGL viewport (`0x0F0000` tessellation buffer with 192-bit SHA-256 `TopoId`s).
4. **Responsive Flex Studio & Minimal Zero-GUI Embed Viewer:**
   - Desktop horizontal (`flex-direction: row`) and mobile vertical (`flex-direction: column`) split studio with fault-tolerant live CDML editing (retaining the last valid 3D mesh when assertions or syntax fail).
   - Embeddable via URL parameters (`?embed=true&cdml=...&gui=true&vars=...&probes=...&exports=...`) or the `<opencad-viewer>` Custom Element.
   - Clean, minimal slate theme calibrated for **WCAG AA/AAA compliance** (contrast ratio $\ge 13:1$ without glare) with an isometric cube identity mark.

---

## 📦 Module Portability & Installation

OpenCAD is engineered for maximum portability across web, server, native, and embedded workflows:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OpenCAD Distribution Tiers                         │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│ Tier 1: Standalone  │ Tier 2: ESM JS/TS   │ Tier 3: Python / Headless       │
│ cad_kernel.wasm     │ @open-cad/core-sdk  │ bindings/python/opencad         │
│ Freestanding C-ABI  │ Browser & Node.js   │ wasmtime / pure CLI             │
└─────────────────────┴─────────────────────┴─────────────────────────────────┘
```

### 1. Standalone WASM (`cad_kernel.wasm`)
The core mathematical kernel is compiled to freestanding WebAssembly with no host system dependencies.
- **Exports:** 18 canonical C functions conforming to [`abi/cad_kernel.h`](./abi/cad_kernel.h).
- **Memory Requirements:** 8MB initial shared memory, expandable up to 128MB.
- **Direct WebAssembly Instantiation:**
  ```javascript
  const sharedMem = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
  const { instance } = await WebAssembly.instantiateStreaming(fetch('cad_kernel.wasm'), {
    env: { memory: sharedMem },
    opencad: {
      field_alloc: () => 0,
      field_eval_scalar: () => 0.0,
      field_eval_vec3: () => {},
      cmd_write: () => {}
    }
  });
  instance.exports.kernel_init();
  ```

### 2. JavaScript / TypeScript ESM SDK (`packages/kernel-sdk`)
For Node.js, Vite, Next.js, and web application pipelines:
```bash
npm install @open-cad/core-sdk
```
```typescript
import { OpenCadKernel } from '@open-cad/core-sdk';

const kernel = await OpenCadKernel.create();
const result = kernel.evaluateCdml(cdmlXmlString);

if (result.status === 0) {
  const mesh = kernel.getTessellationMesh();
  console.log(`Vertices: ${mesh.vertexCount}, Triangles: ${mesh.triangleCount}`);
  const stepText = kernel.exportStep();
  const stlBuffer = kernel.exportStl({ binary: true });
}
```

### 3. Declarative `<opencad-viewer>` Web Component
Embed 3D CAD models directly into documentation, blogs, or dashboards:
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<!-- Minimal Zero-GUI 3D Embed -->
<opencad-viewer
  src="/examples/flange_normative.cdml"
  data-gui="false">
</opencad-viewer>

<!-- Filtered Interactive Parameters, Probes & Exports -->
<opencad-viewer
  src="/examples/flange_normative.cdml"
  data-gui="true"
  data-gui-vars="flange_w,bore_r,fillet_r"
  data-gui-probes="housing_volume,max_fillet_stress"
  data-gui-exports="step,stl">
</opencad-viewer>
```

### 4. Python SDK (`bindings/python/opencad` via `wasmtime`)
Ideal for data science, algorithmic geometry exploration, and automated manufacturing pipelines:
```bash
pip install opencad
```
```python
import opencad as cad

doc = (cad.cdml(units="mm")
    .var("W", 80.0, min=40.0, max=120.0)
    .var("H", 20.0)
    .var("R", 10.0)
    .chart_xy("c_xy")
    .sketch("sk1", chart="c_xy")
        .rect_wire("w_out", width="ref(W)", height="50.0", role="outer")
        .circle_wire("w_hole", radius="ref(R)", role="hole")
    .brep("b1")
        .sweep_extrude("sw1", sketch="sk1", z_expr="ref(H) * v")
    .probe("vol", type="volume", target="b1")
    .export_tessellate("b1")
    .export_step("b1")
    .export_stl("b1", binary=True))

res = doc.evaluate()
assert res.status == 0
print("Enclosed Volume (mm³):", res.probe("vol"))
step_str = res.to_step()
stl_bytes = res.to_stl()
```

---

## 🗺️ Extended Product & Engineering Roadmap

The OpenCAD roadmap focuses on empowering engineers, designers, and autonomous coding agents with deterministic, scriptable, and highly portable CAD tooling.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             OpenCAD Roadmap                                 │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│ Track 1: Scripting  │ Track 2: 2D Vector  │ Track 3: Section Views          │
│ • Turing-Complete   │ • Fast Rasterizer   │ • Declarative CDML Sections     │
│ • Loops & Condition │ • SVG & DXF Exports │ • Viewport Interactive Slice    │
├─────────────────────┴─────────────────────┼─────────────────────────────────┤
│ Track 4: Interactive MDN-Style Docs       │ Track 5: 3D Ecosystem Plugins   │
│ • Live Sandboxes & Runnable Code Blocks   │ • Blender, FreeCAD, Rhino       │
│ • Interactive Geometric Visualizers       │ • KiCad Enclosure Exchange      │
└───────────────────────────────────────────┴─────────────────────────────────┘
```

### ⚙️ Track 1: Turing-Complete CDML Scripting Engine
- **Procedural Constructs:**
  - Introduce procedural syntax (`<for each="..." in="...">`, `<while expr="...">`, `<if condition="..."> / <else>`) directly within CDML definitions.
  - User-defined functions, parameterized macros (`<def-macro id="...">` and `<call macro="...">`), and scoped variables.
- **Algorithmic Geometry Synthesis:**
  - Programmatic generation of gear profiles (involute teeth arrays), heat sinks with variable fin profiles, and lattice metamaterials with gradient density fields without external preprocessors.

### 📐 Track 2: Built-in 2D Fast Renderer & Vector Formats (SVG / DXF)
- **Headless 2D Preview Renderer:**
  - Lightweight in-kernel rasterizer for rapid snapshot generation during unit testing and automated CI regression verification without WebGL/GPU overhead.
- **Precision Vector Export:**
  - Automated Hidden Line Removal (HLR) projection emitting standards-compliant **SVG** with semantic stroke classes (visible, hidden, centerlines).
  - Production **DXF (AutoCAD R12/2000)** generation with separate CAD layers for profile geometry, dimensions, and annotations.

### ✂️ Track 3: Dynamic Section Views (CDML & Web Studio)
- **Declarative CDML Section Tag:**
  - Define section planes directly in markup (`<section-view plane="xy" offset="15.0" hatch="ansi31" />`) for automated slice callouts in downstream technical sheets.
- **Studio Interactive Sectioning Plane:**
  - Real-time Three.js viewport clipping tool with draggable plane normal gizmos, hollow-cap cross-hatching, and sub-shape inspection.

### 📖 Track 4: MDN-Style Interactive Documentation & Guides
- **Live Interactive Reference Portal:**
  - A documentation platform modeled after the MDN Web Docs standard.
  - Side-by-side runnable CDML and SDK code blocks connected to live WebGL render viewports for every single tag, constraint, and method.
- **Comprehensive Mechanical Engineering Curriculum:**
  - Tutorials spanning sketch constraint optimization, kinematic sweep theory, TPMS lattice design, rolling-ball filleting limits, and export compliance.

### 🔌 Track 5: Portability & Integration in External 3D Software
- **Blender Addon:**
  - Geometry Nodes integration and Python-driven parametric operator allowing OpenCAD models to be imported as native modifier graphs.
- **FreeCAD Workbench:**
  - Native workbench module importing CDML feature trees into FreeCAD's App::Part framework.
- **Rhino & Grasshopper Component:**
  - Grasshopper custom node invoking `cad_kernel.wasm` via RhinoCommon for generative architectural workflows.
- **KiCad Mechanical Exchange:**
  - Automated 3D enclosure generation matching KiCad PCB edge cuts and component clearance bounds.

---

## 🔬 Build & Verification Pipeline

OpenCAD enforces strict mathematical correctness, memory safety, and anti-cheat policies via a 9-gate automated verification suite.

### 1. Build Native Zig Kernel, Run 198 Unit Tests & Compile WASM
```bash
cd kernel-zig
zig build test                        # Runs 39 test steps (198 tests) with zero-leak checks
zig build -Doptimize=ReleaseSmall     # Compiles stripped cad_kernel.wasm
```

### 2. Run All 9 Anti-Cheat & E2E Verification Gates
```bash
./scripts/verify_gates.sh all
```

| Gate | Target | Scope & Assertions |
| :--- | :--- | :--- |
| **Gate 0** | Zero-Primitive Law | Enforces zero hardcoded `box`/`cylinder`/`sphere` primitives in kernel. |
| **Gate 0B**| Anti-Cheat Scan | AST and symbol scanning against hardcoded test models or values. |
| **Gate 1** | Pure WASM Geometry | Asserts zero Three.js/JS geometry generation fallbacks. |
| **Gate 2** | Native Zig Tests | Runs all 198 native tests with `std.testing.allocator` zero-leak checks. |
| **Gate 3** | Pure-Math WASM ABI | Validates the 18-function C-ABI in headless Node.js without browser DOM. |
| **Gate 3B**| CDML Compiler | Tests CDML §14 normative housing, assertions, and randomized Acid Tests. |
| **Gate 4** | Zero-Copy Extension | Verifies 3D stress field modulation across `SharedArrayBuffer` (`0x1F0000`). |
| **Gate 5** | Python / Wasmtime | Verifies 4-step Python CDML builder and `wasmtime` headless execution. |
| **Gate 6** | Playwright E2E | 8 browser tests verifying flex responsiveness, embed mode, and 60-FPS WebGL. |

---

## 📚 Documentation Index

- [**ARCHITECTURE.md**](./ARCHITECTURE.md) — Comprehensive technical specification: `SharedArrayBuffer` memory layout (`0x000000`–`0x5F0000`), 18-function C-ABI, AD/Interval VM, Householder QR solver, straddling-triangle CSG, and Dual Contouring internals.
- [**CDML v1.0 Specification**](./docs/CDML%20v1.0%20%E2%80%94%20Computational%20Design%20Markup%20Language%20Format%20Specification.md) — Complete normative specification of the Computational Design Markup Language.
- [**LLM Kernel Integration Skill (`docs/SKILL.md`)**](./docs/SKILL.md) — Reference handbook for AI coding agents integrating with OpenCAD via ESM JS and shared memory.
- [**API Reference (ABI)**](./abi/cad_kernel.h) — Canonical C-ABI header definition for external language bindings.
