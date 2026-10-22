# v2.0 Multi-Workbench Modular Architecture Bootstrap Status

**Status:** Bootstrap Complete & Hardened  
**Date:** 2026-10-22  
**Architect:** `cad-architect`  

---

## 1. Executive Summary

The OpenCAD architecture has been upgraded to **v2.0 Multi-Workbench Modular Architecture**. This upgrade extends the core B-Rep modeling and constraint-solving kernel with five specialized industrial and computational engineering workbenches, standalone zero-dependency SDK packaging, modular WebAssembly compilation targets, and dedicated specialist agent roles.

---

## 2. Directory Structure & Modular Workbenches

### A. Core Kernel & Modular Workbenches (`kernel-zig/src/`)
1. **`ast/` (Deterministic Code-CAD AST & Git-for-CAD)**
   - `types.zig`: AST node definitions (`FeatureNode`, `SketchNode`, `ParamNode`), token types, and syntax tree data structures.
   - `parser.zig`: Recursive-descent declarative Code-CAD syntax parser.
   - `formatter.zig`: Canonical, deterministic pretty-printer for AST nodes.
   - `merge.zig`: Semantic 3-way Git merge conflict resolver for CAD feature DAGs (detects deleted face references, parameter divergence, and topology collisions).
   - `mod.zig`: Public module interface with self-contained unit test suite.

2. **`sheetmetal/` (Sheet Metal Fabrication & Unfolding)**
   - `kfactor.zig`: Material model, neutral axis shift, K-factor, Y-factor, bend allowance ($BA$), and bend deduction ($BD$).
   - `flange.zig`: Base flange, edge flange, and corner relief geometries (tear, rectangular, obround).
   - `unfold.zig`: Flat-pattern un-folder projecting 3D folded sheet bodies into 2D drawing profiles with bend centerlines, angles, and up/down tags.
   - `wasm.zig`: Zero-copy WASM export functions for browser calculation and unfolding.
   - `mod.zig`: Module interface and unit test suite.

3. **`fea_flexure/` (FEA & FACT Compliant Flexure Synthesis)**
   - `mesh.zig`: Delaunay and octree tetrahedral mesher generating linear Tet4 and quadratic isoparametric Tet10 elements with volume and aspect ratio metrics.
   - `solver.zig`: Matrix-free Jacobi-Preconditioned Conjugate Gradient (PCG) linear elasticity solver with Von Mises stress extraction.
   - `compliance.zig`: $6 \times 6$ spatial compliance matrix $\mathbf{C} \in \mathbb{R}^{6 \times 6}$ extractor relating tip twist $\mathbf{t} = [\mathbf{\theta}, \mathbf{\delta}]^T$ to applied wrench $\mathbf{w}$.
   - `flexure.zig`: Freedom and Constraint Topologies (FACT) synthesis based on Screw Theory; Pseudo-Rigid-Body Models (PRBM) for leaf flexures and circular notch hinges (Paros & Weisbord compliance equations).
   - `wasm.zig`: Zero-copy WASM export functions for browser meshing and compliance analysis.
   - `mod.zig`: Module interface and unit test suite.

4. **`implicit/` (nTop-style Implicit Modeling & TPMS)**
   - `sdf.zig`: SIMD signed distance field primitives (Sphere, Box, Cylinder, Torus, Cone, Plane, Capsule) and smooth CSG blending operations (`smin`, `smax`).
   - `tpms.zig`: Triply Periodic Minimal Surfaces (Gyroid, Schwarz P, Schwarz D, Neovius, Lidinoid, Fischer-Koch) for skeletal and sheet lattices.
   - `fields.zig`: Spatially varying field modulators driven by FEA stress tensors, thermal fields, and geometric gradients.
   - `dual_contouring.zig`: Octree-based Dual Contouring mesher with Hermite data extraction (analytical normals and zero-crossings) and QEF solver for sharp edge preservation.
   - `wasm.zig`: Zero-copy WASM export functions for browser evaluation and meshing.
   - `mod.zig`: Module interface and unit test suite.

5. **`cam_hlr/` (2D HLR, GD&T, 3MF & CNC Toolpaths)**
   - `hlr.zig`: Exact B-Rep Hidden Line Removal projection classifying curves into Visible Outline, Hidden Line (dashed), Apparent Contour (silhouette), and Tangent Crease.
   - `section.zig`: Planar section slicing with automated cross-hatch pattern generation and GD&T dimension tagging.
   - `threemf.zig`: Production 3MF XML archive serializer with 3D build-plate nesting and packing.
   - `gcode.zig`: 2.5D profile, pocketing, adaptive clearing, and 3D surface finish toolpath generator with standard ISO 6983 / Fanuc / LinuxCNC G-code emission.
   - `wasm.zig`: Zero-copy WASM export functions for browser HLR, slicing, and CAM emission.
   - `mod.zig`: Module interface and unit test suite.

---

## 3. Web UI Workbenches (`web-app/src/workbenches/`)

- `workbenches/ast/`: Code-CAD editor panel, AST visualizer, and 3-way merge diff viewer.
- `workbenches/sheetmetal/`: Sheet metal parameter controls, flange tools, and flat-pattern 2D preview.
- `workbenches/fea_flexure/`: FEA meshing config, displacement & stress heatmaps, compliance matrix table, and flexure synthesis presets.
- `workbenches/implicit/`: TPMS lattice builder, SDF boolean graph, stress field modulation controls, and dual-contouring mesher viewer.
- `workbenches/cam_hlr/`: 2D drawing projection panel, GD&T section view, 3MF packing optimizer, and G-code previewer.
- `workbenches/index.ts`: Unified workbench registry and tab switcher.

---

## 4. Standalone Kernel SDK (`packages/kernel-sdk/`)

- **Package Name:** `@open-cad/kernel-wasm`
- **Version:** `0.2.0`
- **Architecture:** Zero-dependency, ESM + TypeScript declarations, supporting modular or unified WASM loading.
- **Entry Points:**
  - `@open-cad/kernel-wasm`: Root barrel with unified client and types.
  - `@open-cad/kernel-wasm/core`: B-Rep modeling, Sketch Solver, and Tessellation client.
  - `@open-cad/kernel-wasm/sheetmetal`: K-factor, flange, and unfolding client.
  - `@open-cad/kernel-wasm/fea-flexure`: Tet mesher, PCG solver, and compliance matrix client.
  - `@open-cad/kernel-wasm/implicit`: SDF, TPMS, and Dual Contouring client.
  - `@open-cad/kernel-wasm/cam-hlr`: HLR, Sectioning, 3MF, and G-code client.
- **Compilation:** Builds cleanly via `npm --prefix packages/kernel-sdk run build` into `dist/`.

---

## 5. Modular WASM Targets & Build Hardening

`kernel-zig/build.zig` produces 6 WebAssembly binaries installed to `web-app/public/`:
1. `cad_kernel.wasm` (Unified B-Rep + Solver + Tessellation library for backwards compatibility)
2. `cad_core.wasm` (Core CAD kernel)
3. `cad_sheetmetal.wasm` (Sheet metal engine)
4. `cad_fea_flexure.wasm` (FEA & Flexure synthesis engine)
5. `cad_implicit_ntop.wasm` (Implicit SDF & TPMS engine)
6. `cad_mfg_cam.wasm` (Manufacturing CAM, HLR & 3MF engine)

### Hardened Build Mode:
- Added `zig build harden` step running all unit tests in `.optimize = .ReleaseSafe` mode, guaranteeing that bounds checks, integer overflow assertions, and memory safety checks pass under optimized execution.

---

## 6. Multi-Agent Concurrency Matrix (`.agents/AGENTS.md`)

| Agent ID | Thinking Level | Exclusive Write Scope | Primary Domain |
| :--- | :--- | :--- | :--- |
| **`cad-architect`** | `high` | `abi/cad_kernel.h`<br>`.antigravity/`<br>`package.json`<br>`README.md`<br>`packages/kernel-sdk/` | ABI architecture, monorepo coordination, SDK releases. |
| **`zig-solver-math`** | `high` | `kernel-zig/src/solver/`<br>`kernel-zig/src/geom/`<br>`kernel-zig/src/math/` | 2D/3D constraint solver, Shewchuk predicates, SIMD NURBS evaluators. |
| **`zig-brep-topo`** | `high` | `kernel-zig/src/topo/`<br>`kernel-zig/src/ops/`<br>`kernel-zig/src/brep/`<br>`kernel-zig/src/primitives/`<br>`kernel-zig/src/router.zig` | SoA Half-Edge B-Rep, Feature Tree DAG, Persistent Topological Naming. |
| **`zig-tess-wasm`** | `medium` | `kernel-zig/src/tessellation/`<br>`kernel-zig/src/tess/`<br>`kernel-zig/src/main.zig`<br>`kernel-zig/build.zig`<br>`web-app/public/cad_kernel.wasm`<br>`web-app/public/cad_core.wasm` | Adaptive triangulation, zero-copy WASM exports, binary footprint. |
| **`zig-fea-flexure`** | `high` | `kernel-zig/src/fea_flexure/`<br>`kernel-zig/src/sheetmetal/`<br>`web-app/public/cad_fea_flexure.wasm`<br>`web-app/public/cad_sheetmetal.wasm` | Tet4/Tet10 meshing, PCG FEA, 6x6 compliance, FACT flexure synthesis, K-factor sheet metal. |
| **`zig-implicit-sdf`** | `high` | `kernel-zig/src/implicit/`<br>`web-app/public/cad_implicit_ntop.wasm` | nTop SIMD SDF bytecode, TPMS lattices, FEA field modulation, Dual Contouring. |
| **`zig-cam-hlr`** | `medium` | `kernel-zig/src/cam_hlr/`<br>`kernel-zig/src/ast/`<br>`web-app/public/cad_mfg_cam.wasm` | Exact 2D HLR, GD&T section slicing, 3MF packing, CNC G-code, Code-CAD AST. |
| **`oracle-fuzzer-qa`** | `medium` | `oracle-harness/`<br>`kernel-zig/tests/`<br>`scripts/mcp/oracle_fuzzer.sh` | Continuous differential fuzzing against OpenCASCADE, Euler invariants. |
| **`threejs-ui-worker`** | `medium` | `web-app/` *(excluding public wasm binaries)* | Three.js WebGL/WebGPU CAD viewport, sub-shape picking, Feature Tree UI. |
