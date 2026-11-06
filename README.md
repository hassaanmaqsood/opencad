# OpenCAD (`open-parametric-cad` v2.0)

> **Pure-Math Computational CAD Kernel, CDML v1.0 Compiler, Responsive Flex Studio & Minimal Embed Viewer.**  
> Powered by Zig (`wasm32-freestanding`), SharedArrayBuffer Zero-Copy Memory, TypeScript, Python (`wasmtime`), and Three.js.

[![Live Studio](https://img.shields.io/badge/Live_Studio-hassaanmaqsood.github.io%2Fopencad-blue?style=for-the-badge&logo=googlechrome)](https://hassaanmaqsood.github.io/opencad/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig Tests](https://img.shields.io/badge/Zig_Unit_Tests-198%2F198_Passed-brightgreen.svg)](./kernel-zig)
[![Anti-Cheat Gates](https://img.shields.io/badge/Verification_Gates-All_9_Passed-success.svg)](./scripts/verify_gates.sh)
[![Zero-Primitive Law](https://img.shields.io/badge/Architecture-Zero--Primitive_Pure--Math-blueviolet.svg)](./kernel-zig/src/main.zig)

---

## 🏛️ Architectural Highlights (v2.0)

OpenCAD is built on a **Zero-Primitive Pure-Math Architecture**: no hardcoded `box`, `cylinder`, or `sphere` primitives exist in the engine. All geometry is rigorously synthesized from first mathematical principles across four core pillars:

1. **Pure-Math Kernel (`cad_kernel.wasm`):**
   - Synthesizes geometry via **18 canonical C-ABI functions**: forward-mode Automatic Differentiation ([`autodiff.zig`](./kernel-zig/src/math/autodiff.zig)), Householder QR nonlinear constraint solving ([`constraint_sys.zig`](./kernel-zig/src/math/constraint_sys.zig)), rational NURBS curves & wires ([`curve_wire.zig`](./kernel-zig/src/geom/curve_wire.zig)), $SE(3)$ kinematic sweeps, bivariate tensor-product NURBS lofts, rolling-ball fillets, non-destructive offset shells, analytic inequality regions ([`surface_brep.zig`](./kernel-zig/src/geom/surface_brep.zig)), and interval-pruned octree QEF Dual Contouring ([`implicit_field.zig`](./kernel-zig/src/implicit/implicit_field.zig)).
2. **CDML v1.0 (Computational Design Markup Language):**
   - Declarative XML engineering format combining `<imports>`, parametric `<defs>` (`<var>`, `<expr>`, `<field-slot>`, `<assert>`), orthonormal `<chart>` frames, constrained `<sketch>` profiles, `<region>` half-spaces, `<brep>` sweeps/fillets, `<implicit>` TPMS lattices, straddling-triangle `<csg>` booleans, physical `<probe>` queries, and production `<exports>` (`<tessellate>`, `<step>`, `<stl>`).
3. **Single `SharedArrayBuffer` Zero-Copy Memory (`0x000000`–`0x5F0000`):**
   - Unified linear memory connecting `cad_kernel.wasm`, external field WASM extensions (`ext_field_canary.wasm` writing 3D stress voxels at `0x1F0000`), and the Three.js WebGL viewport (`0x0F0000` tessellation buffer with 192-bit SHA-256 `TopoId`s).
4. **Responsive Flex Studio & Minimal Zero-GUI Embed Viewer:**
   - Desktop horizontal (`flex-direction: row`) and mobile vertical (`flex-direction: column`) split studio with fault-tolerant live CDML editing (retaining the last valid 3D mesh when assertions or syntax fail).
   - Embeddable via URL parameters (`?embed=true&cdml=...&gui=true&vars=...&probes=...&exports=...`) or the `<opencad-viewer>` Custom Element.
   - Clean, minimal slate theme calibrated for **WCAG AA/AAA compliance** (contrast ratio $\ge 13:1$ without glare) with a precision isometric cube identity mark.

---

## ⚡ Quick Usage Examples

### 1. Declarative `<opencad-viewer>` Web Component & URL Embed
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

### 2. 4-Step Fluent CDML Surface SDK (Python & TypeScript)

#### Python (`bindings/python/opencad`)
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

#### TypeScript (`packages/core-sdk`)
```typescript
import { cdml } from '@open-cad/core-sdk';

const doc = cdml({ units: 'mm' })
  .var('W', 80.0, { min: 40.0, max: 120.0 })
  .var('H', 20.0)
  .var('R', 10.0)
  .chartXY('c_xy')
  .sketch('sk1', 'c_xy')
    .rectWire('w_out', 'ref(W)', '50.0', 'outer')
    .circleWire('w_hole', 'ref(R)', 'hole')
  .brep('b1')
    .sweepExtrude('sw1', 'sk1', 'ref(H) * v')
  .probe('vol', 'volume', 'b1')
  .exportTessellate('b1')
  .exportStep('b1')
  .exportStl('b1', true);

const xml = doc.toCDML();
```

---

## 🗺️ Product & Engineering Roadmap

The OpenCAD roadmap is organized into five specialized tracks focusing on production ergonomics, advanced geometric synthesis, multi-manifold modeling, manufacturing toolpaths, and technical drawing generation.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             OpenCAD Roadmap                                 │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│ Track 1: Docs & UX  │ Track 2: Patterns   │ Track 3: Manifolds & Sketching  │
│ • Interactive Guides│ • Linear & Polar    │ • Curved 2-Manifold Substrates  │
│ • Production Models │ • Feature-on-Feature│ • Geodesic Constraints          │
│ • Live Sandboxes    │ • TopoId Tracking   │ • Conformal Normal Embossing    │
├─────────────────────┴─────────────────────┼─────────────────────────────────┤
│ Track 4: Standalone Projection Renderer   │ Track 5: Direct Slicing & Toolpaths
│ • Exact B-Rep Hidden Line Removal (HLR)   │ • Exact Mathematical B-Rep Slicing│
│ • Multi-View Orthographic Projections     │ • TPMS Lattice Direct 2D Slicing│
│ • Production SVG, PDF & DXF Vector Sheets │ • Adaptive Z & CNC/3D Print CAM │
└───────────────────────────────────────────┴─────────────────────────────────┘
```

### 📖 Track 1: Comprehensive Documentation & Engineering Example Library
- **Interactive Documentation Portal:**
  - Full API references across Python SDK, TypeScript/Node SDK, Web Components, and native C-ABI.
  - Interactive browser-based CDML sandboxes with real-time parameter tweaking and 3D preview.
- **Production-Grade Example Catalog:**
  - *Precision Mechanics:* High-pressure flanged housings, planetary gearboxes, bearing mounts, and bolt-circle patterns.
  - *Compliant Mechanisms & Flexures:* FACT-synthesized parallel flexure stages, cross-axis flexural pivots, and leaf-spring suspensions.
  - *Thermal & Fluidics:* Gyroid, Schwarz-D, and Lidinoid TPMS conformal cold-plates and lightweight aerospace heat exchangers.
  - *Consumer & Industrial Design:* Ergonomic shells, snap-fit joints, threaded fasteners, and ribbed enclosures.

### 🔁 Track 2: Advanced Feature Patterning (Linear, Polar & Hierarchical Feature-on-Feature)
- **1D & 2D Linear Patterns:**
  - Directional vector propagation with parametric pitch, count limits, and instance-level suppression masks.
- **Polar & Cylindrical Patterns:**
  - Radial distribution around arbitrary 3D axes with uniform spacing, angular span ($0^\circ$–$360^\circ$), and radial offset compensation.
- **Curve-Driven & Spline Patterns:**
  - Distributing features along continuous 3D NURBS curves using Frenet-Serret frames and Rotation-Minimizing Frames (RMF) to prevent axial twisting.
- **Hierarchical Feature-on-Feature Patterning:**
  - Repeating compound features (e.g., an extruded boss with counterbored hole, chamfer, and cooling ribs) across an existing parent pattern.
  - Conformal distribution over non-planar target faces (e.g., patterning fastener mounts along an aerodynamic curved fuselage).
  - Preserving **192-bit deterministic `TopoId`s** across pattern instances for stable downstream fillets, chamfers, and boolean operations without naming breakdown.

### 🌐 Track 3: Manifolds & Non-Planar Sketching on Curved Surfaces
- **Curved 2-Manifold Substrates:**
  - Elevating sketches beyond flat Cartesian planes ($\mathbb{R}^2$) to arbitrary 2-manifold B-Rep surfaces $\mathbf{S}(u,v)$ (cylinders, cones, spheres, toroids, and general bicubic NURBS patches).
- **Geodesic & Parameter-Space $(u,v)$ Sketch Constraints:**
  - Solving geometric constraints directly in surface parameter space using pullback metric tensors $g_{ij} = \frac{\partial \mathbf{S}}{\partial u^i} \cdot \frac{\partial \mathbf{S}}{\partial u^j}$.
  - Geodesic distance constraints, surface-parallel alignment, and tangent curve continuity across trimmed boundary patches.
- **Conformal Normal Extrusion & Embossing:**
  - Sweeping 2D profiles along the local unit normal field $\mathbf{n}(u,v) = \frac{\mathbf{S}_u \times \mathbf{S}_v}{\|\mathbf{S}_u \times \mathbf{S}_v\|}$.
  - Constant-thickness surface offsetting, conformal ribbing, textured grips, and fluidic micro-channels on organic surfaces.

### 📐 Track 4: Standalone Projection Renderer & Technical 2D Drawings (HLR)
- **Headless Standalone Projection Engine:**
  - Fully decoupled from browser WebGL runtimes — executable via Zig native CLI, Node.js, and serverless workers for batch automated rendering.
- **Exact B-Rep Hidden Line Removal (HLR):**
  - Analytic edge classification into visible sharp, visible smooth silhouette, hidden/occluded (dashed), and seam lines.
  - Accelerated via bounding volume hierarchies (BVH) and exact ray-surface clipping against NURBS geometry (no polyhedral approximation artifacts).
- **Standard Engineering Drawing Generation:**
  - Automated First-Angle and Third-Angle orthographic projection layouts (Front, Top, Right, Isometric, and Arbitrary Auxiliary Views).
  - Cross-section slicing planes with automated hatching patterns and cut-line callouts.
  - Parametric dimensioning, datums, centerlines, and GD&T tolerance frames.
  - Direct export to vector **SVG** (with semantic CSS stroke classes), print-ready **PDF**, and CAD **DXF** (R12/R2000).

### ⚙️ Track 5: Direct B-Rep & Implicit Slicing for Manufacturing (CAM & 3D Printing)
- **Exact Mathematical B-Rep Slicing:**
  - Slicing solids directly against exact analytic and NURBS B-Rep surfaces without intermediate STL polygonization.
  - Eliminates chordal deviation errors and facet staircasing on circular bores, fillets, and cylinders.
- **Direct Implicit & TPMS Lattice Slicing:**
  - Evaluating 2D level sets $F(x, y, z_k) = 0$ on slicing planes $Z = z_k$ via 2D Dual Contouring, avoiding multi-gigabyte triangle meshes for dense porous lattices.
- **Adaptive & Non-Planar Layer Generation:**
  - Slope-adaptive variable layer height based on local surface curvature ($\Delta z \propto \cos\theta$).
  - Multi-axis curved slicing paths for non-planar continuous-fiber 3D printing and surface conformal deposition.
- **Production Toolpath Synthesis:**
  - CNC toolpath generation: 2.5D pocketing, profiling, adaptive clearing, and trochoidal milling.
  - Additive manufacturing exports: G-code, standardized 3MF slice bundles, and CLI layer files.

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
| **Gate 6** | Playwright E2E | 6 browser tests verifying flex responsiveness, embed mode, and 60-FPS WebGL. |

---

## 📚 Documentation Index

- [**ARCHITECTURE.md**](./ARCHITECTURE.md) — Comprehensive technical specification: `SharedArrayBuffer` memory layout (`0x000000`–`0x5F0000`), 18-function C-ABI, AD/Interval VM, Householder QR solver, straddling-triangle CSG, and Dual Contouring internals.
- [**CDML v1.0 Specification**](./docs/CDML%20v1.0%20%E2%80%94%20Computational%20Design%20Markup%20Language%20Format%20Specification.md) — Complete normative specification of the Computational Design Markup Language.
- [**.antigravity/CHARTER.md**](./.antigravity/CHARTER.md) — Architectural charter, mathematical tenets, and multi-agent coordination locks.
- [**API Reference (ABI)**](./abi/cad_kernel.h) — Canonical C-ABI header definition for external language bindings.
