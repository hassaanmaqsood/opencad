# OpenCAD (`open-parametric-cad`)

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig: 0.17](https://img.shields.io/badge/Zig-0.17-orange.svg)](https://ziglang.org/)
[![Playwright: 31/31 Passed](https://img.shields.io/badge/Playwright-31%2F31_Passed-brightgreen.svg)](https://playwright.dev/)
[![WASM Core: 445 KiB](https://img.shields.io/badge/WASM_Core-445_KiB-success.svg)](web-app/public/cad_core.wasm)

OpenCAD is an open-source, high-performance parametric Computer-Aided Design (CAD) kernel and web application built from the ground up in **Zig (WebAssembly)**, **TypeScript**, and **Three.js**.

Designed around a frozen **Zero-Copy C ABI** (`abi/cad_kernel.h`) and a differential oracle harness (OpenCASCADE + PlaneGCS), OpenCAD delivers sub-millimeter precision, steady 60-FPS rendering, and a complete closed-loop manufacturing pipeline entirely inside the browser or headless in CI/CD.

---

## Unified Workbenches

OpenCAD features 6 unified workbenches, with **Bidirectional Code-CAD** and **Git-for-CAD Semantic Versioning** dockable in every mode:

| Workbench | Core Engine | Capabilities |
| :--- | :--- | :--- |
| **📐 Design** | Zig B-Rep & PlaneGCS Solver | 2D sketch constraint solver, parametric solid primitives (Box, Cylinder, Sphere), dress-up fillets/chamfers/shells, and STEP AP214 I/O. |
| **📦 Sheet Metal** | DIN 6935 Sheet Engine | Base tabs, edge flanges with automatic miter trimming, hems, rectangular corner reliefs, and exact 2D flat-pattern unfolding ($BA = \text{angle} \cdot (R + K \cdot T)$). |
| **🔗 Assembly** | 3D Kinematic Mate Solver | Distance, coincident, parallel, and angle mates; high-throughput 60 FPS viewport rendering of 500+ parts using `THREE.InstancedMesh`. |
| **⚡ Simulation & Flexures** | Tet10 PCG Solver & FACT Engine | Isoparametric quadratic `Tet10` meshing, corotational nonlinear FEA, $6\times 6$ spatial compliance matrix $\mathbf{C}$ extraction, and FACT screw-axis synthesis. |
| **🌀 Implicit & Lattices** | SIMD SDF VM & Dual Contouring | Vectorized TPMS minimal surfaces (Gyroid, Schwarz-P, Diamond, Lidinoid, Neovius), FEA field-driven lattice modulation, and sharp-feature QEF Dual Contouring. |
| **⚙️ Manufacturing** | BVH HLR, 3MF Packer & CAM | Analytical Hidden-Line Removal for 2D engineering blueprints, DXF/SVG title-block export, 3D SLS/2D FDM nesting, and 2.5D pocket/contour G-code toolpaths. |

---

## 4 Built-In Starter Templates

OpenCAD includes 4 production-grade templates illustrating closed-loop engineering workflows:

1. **Parametric CNC Machined Bracket:** Analytical B-Rep solid + multi-view orthographic 2D drawing + 2.5D G-code toolpath.
2. **Sheet Metal Electronics Enclosure:** Parametric 3D chassis with bent flanges, corner reliefs, and neutral-axis unfolded 2D flat pattern DXF.
3. **Precision Planar XY Compliant Flexure Stage:** Double-parallelogram leaf flexures with FACT eigen-screw compliance analysis and corotational nonlinear FEA deflection.
4. **Stress-Driven Gyroid Aerospace Mount:** Hollowed B-Rep mounting bracket filled with FEA stress-modulated Gyroid minimal surfaces and packaged for production 3MF printing.

---

## Standalone Headless SDK & CLI

Install the headless WebAssembly CAD package:

```bash
npm install @open-cad/kernel-wasm
```

### Headless Pipeline Example (`.ocad.ts -> .step / .3mf / .dxf / .gcode`)

```typescript
import { OpenCadCore } from '@open-cad/kernel-wasm/core';
import { OpenCadSheetMetal } from '@open-cad/kernel-wasm/sheetmetal';
import { OpenCadImplicit } from '@open-cad/kernel-wasm/implicit';
import { OpenCadCamHlr } from '@open-cad/kernel-wasm/cam-hlr';

// 1. Initialize core WASM kernel
const core = await OpenCadCore.create('./web-app/public/cad_core.wasm');
const box = core.generateBox(50, 40, 20);

// 2. Evaluate TPMS infill
const implicit = await OpenCadImplicit.create('./web-app/public/cad_implicit_ntop.wasm');
const sdfVal = implicit.evalTpms('gyroid', 10.0, 1.2, 5.0, 5.0, 5.0);

// 3. Project 2D blueprint isometric coordinates
const cam = await OpenCadCamHlr.create('./web-app/public/cad_mfg_cam.wasm');
const [isoX, isoY] = cam.projectIsometric(10.0, 20.0, 30.0);
```

### CLI Headless Build Tool

```bash
# Build and export all manufacturing outputs in headless CI/CD
npx opencad build bracket.ocad.ts --step --3mf --dxf --gcode --out-dir ./dist
```

---

## Quick Start & Developer Setup

### 1. Build Native Zig Kernel & WebAssembly Targets
```bash
cd kernel-zig
zig build test               # Asserts 0 memory leaks across 15 test suites
zig build                    # Compiles stripped WASM modules into web-app/public/
```

### 2. Run the Web Application
```bash
cd web-app
npm install
npm run dev                  # Launch local development server (http://localhost:5173)
npx playwright test          # Run the 31-test E2E browser verification suite
```

---

## Technical Specifications & Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for deep dives into:
- The zero-copy C ABI memory layout (`CadTessellatedSolidSlice`)
- The plugin extension VTable architecture (`CadPluginOpVTable`)
- SIMD interval arithmetic & Quadratic Error Function (QEF) Dual Contouring
- Freedom and Constraint Topologies (FACT) compliance matrix synthesis

---

## License

OpenCAD is open-source software licensed under the [Apache-2.0 License](LICENSE).
