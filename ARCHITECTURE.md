# OpenCAD Architecture & Technical Reference

OpenCAD is an open-source, web-first parametric Computer-Aided Design (CAD) platform engineered for sub-millimeter geometric precision, 60-FPS in-browser interactive rendering, and headless CI/CD automated manufacturing pipelines.

---

## 1. System Topology & Layered Architecture

```
+---------------------------------------------------------------------------------------+
|                                    User Interfaces                                    |
|   +-----------------------+   +------------------------+   +----------------------+   |
|   | Fusion 360 / Onshape  |   | Bidirectional Code-CAD |   | Headless CLI / CI/CD |   |
|   | Modern Web Shell UI   |   | Monaco AST Editor      |   | @open-cad/kernel-wasm|   |
|   +-----------------------+   +------------------------+   +----------------------+   |
+-------------------------------------------+-------------------------------------------+
                                            |
                                  OpenCadExtensionHost
                    (Vite Dynamic import() UI & WASM Code-Splitting)
                                            |
+-------------------------------------------v-------------------------------------------+
|                                 Browser Web Worker                                    |
|   +-------------------------------------------------------------------------------+   |
|   |                             WorkerPluginBridge                                |   |
|   +-------------------------------------------------------------------------------+   |
|                                           |                                           |
|                     abi/cad_kernel.h (Zero-Copy C ABI VTable)                         |
|                                           |                                           |
|   +-------------------+  +--------------------+  +------------------+  +----------+   |
|   |   cad_core.wasm   |  | cad_sheetmetal.wasm|  |cad_fea_flexure   |  |cad_ast   |   |
|   |  (B-Rep, Solver,  |  | (DIN 6935 Unfold,  |  |  .wasm           |  |  .wasm   |   |
|   |   DAG, STEP I/O)  |  |  Relief, Flanges)  |  | (Tet10 FEA, FACT)|  | (Parser) |   |
|   +-------------------+  +--------------------+  +------------------+  +----------+   |
|   |     445 KiB       |  |      33 KiB        |  |     49 KiB       |  |  60 KiB  |   |
|   +-------------------+  +--------------------+  +------------------+  +----------+   |
|   +-------------------+  +--------------------+                                       |
|   | cad_implicit_ntop |  |  cad_mfg_cam.wasm  |                                       |
|   |       .wasm       |  | (HLR 2D Drawings,  |                                       |
|   | (SIMD TPMS, QEF)  |  |  3MF Pack, G-Code) |                                       |
|   +-------------------+  +--------------------+                                       |
|   |      44 KiB       |  |      97 KiB        |                                       |
|   +-------------------+  +--------------------+                                       |
+-------------------------------------------+-------------------------------------------+
                                            |
                      Shared Memory & Transferable TypedArrays
                                            |
+-------------------------------------------v-------------------------------------------+
|                                  Three.js Viewport                                    |
|   - Zero-Copy BufferGeometry Binding (Float32Array positions, normals, indices)       |
|   - O(1) Sub-Shape Face/Edge Picking via triangle_to_face_id GPU attribute            |
|   - 500-Instance Assembly Kinematics via THREE.InstancedMesh (steady 60 FPS)          |
|   - Real-Time Scalar Iso-Contour GPU Shader (Raymarched TPMS Cross-Sections)          |
+---------------------------------------------------------------------------------------+
```

---

## 2. Kernel Design & Zero-Copy C ABI

### The C ABI (`abi/cad_kernel.h`)
The ABI is frozen and serves as the single source of truth across native Zig, C++ Oracle test runners, and WebAssembly hosts:

- **Flat Tessellated Solid Representation (`CadTessellatedSolidSlice`):**
  - `positions`: Flat `f32` array $[x, y, z, \dots]$
  - `normals`: Flat `f32` array $[nx, ny, nz, \dots]$
  - `indices`: Flat `u32` triangle index array $[i_0, i_1, i_2, \dots]$
  - `triangle_to_face_id`: Flat `u32` array mapping each triangle to a persistent 64-bit B-Rep face handle
  - `edge_vertices`: Flat `f32` line segments $[x_0, y_0, z_0, x_1, y_1, z_1, \dots]$
  - `segment_to_edge_id`: Flat `u32` array mapping each line segment to an edge identifier

- **Plugin Extension VTable (`CadPluginOpVTable`):**
  Allows secondary WASM binaries (Sheet Metal, FEA, Implicit SDF, CAM) to register custom operations dynamically into the Feature DAG without modifying `abi/cad_kernel.h`.

- **Deterministic Sandbox Limits (`CadKernelLimits`):**
  - `max_wasm_memory_bytes`: Caps memory usage to prevent tab crashes
  - `max_solver_iterations`: Prevents solver infinite loops
  - `eval_timeout_ms`: Bounded execution for untrusted script or STEP input

---

## 3. Workbenches & Capabilities

1. **Design Workbench (B-Rep & Sketch):**
   - 2D geometric constraint solver (Newton-Raphson, Shewchuk exact adaptive geometric predicates)
   - B-Rep primitives (Box, Cylinder, Sphere) and dress-up ops (Fillet, Chamfer, Shell)
   - STEP AP214 ISO-10303-21 Part 21 parser and exporter
   - Interactive Rollback Scrubber & Feature Tree DAG

2. **Sheet Metal Workbench:**
   - DIN 6935 K-factor bend deduction and neutral axis calculation ($BA = \text{angle} \cdot (R + K \cdot T)$)
   - Flanges with automatic corner miter trimming, hems, and tear/obround corner reliefs
   - Unfolds 3D folded sheet bodies into 2D flat patterns with bend annotations

3. **Assembly Workbench:**
   - 3D assembly kinematic mate solver (`COINCIDENT`, `DISTANCE`, `PARALLEL`, `ANGLE`)
   - High-throughput instanced rendering of 500+ parts at 60 FPS via `THREE.InstancedMesh`

4. **Simulation & Flexure Workbench (FEA & FACT):**
   - Tetrahedral meshing (`Tet4` linear and `Tet10` quadratic boundary-conforming elements)
   - SIMD-accelerated Preconditioned Conjugate Gradient (PCG) solver with Jacobi preconditioning
   - Corotational geometric nonlinearity for large-deflection compliant mechanisms
   - Freedom and Constraint Topologies (FACT) extraction: $6 \times 6$ spatial compliance matrix $\mathbf{C}$, center of stiffness, and eigen-screw axis visualization

5. **Implicit & Lattice Workbench (nTop Mode):**
   - `@Vector(4, f32)` SIMD bytecode VM evaluating primitive SDFs and smooth Booleans
   - Triply Periodic Minimal Surfaces (TPMS): Gyroid, Schwarz-P, Schwarz-D, Lidinoid, Neovius
   - Stress-field-driven wall thickness modulation interpolating nodal FEA Von Mises scalars
   - Octree-adaptive Manifold Dual Contouring with Quadratic Error Function (QEF) sharp corner apex solving

6. **Manufacturing Workbench (2D Drawings, 3MF Nesting & CNC CAM):**
   - BVH-accelerated Hidden-Line Removal (HLR) orthographic projections and hatched section views
   - Native DXF and SVG drawing export
   - 3D bin packing (SLS sinter box) and 2D nesting (FDM print bed)
   - 2.5D toolpath generation (boundary contour, pocketing, adaptive clearing) to ISO 6983 G-code

---

## 4. Closed-Loop Design Automation

OpenCAD provides a unified fluent pipeline:

```
Script (.ocad.ts) ──> B-Rep Solid ──> FEA Stress ──> TPMS Modulation ──> Dual Contouring ──> Export
                                                                                       ├──> STEP AP214
                                                                                       ├──> Production 3MF
                                                                                       ├──> DXF Blueprint
                                                                                       └──> CNC G-Code
```
