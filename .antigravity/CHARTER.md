# OpenCAD Architectural Charter: Code-First Computational Engineering Platform

## 1. Vision & Core Philosophy

OpenCAD is not merely a browser CAD tool—it is a **Code-First Computational Engineering Platform** that seamlessly unifies:
1. **Computer-Aided Design (CAD):** Exact B-Rep solid modeling, 2D/3D sketch constraint solving, and parametric feature trees.
2. **Computer-Aided Engineering (CAE):** High-performance isoparametric Tet10 PCG finite-element analysis, $6\times 6$ spatial compliance matrix extraction, and FACT flexure synthesis.
3. **Computer-Aided Manufacturing (CAM):** Analytical Hidden-Line Removal 2D blueprints, 3MF production packing, 2.5D CNC toolpaths, and native watertight binary/ASCII STL generation.

---

## 2. Fundamental Tenets

### Tenet I: Code-First, Visual-Centric UX
- **Zero Authoring Clutter:** All GUI authoring chrome (top ribbons, feature card lists, toolbars, parametric generator sidebars) is eliminated in favor of a 100% view-centric 3D canvas.
- **Code-Configured `lil-gui` Controller:** Every part's interactive controls, telemetry monitors, lenses, and export actions are driven declaratively from code via a standardized `ui` configuration schema:
  - **Parameters:** Slider ranges, step sizes, and numeric inputs bound to the computational recipe.
  - **Telemetry / CAE / CAM:** Read-only monitors for physical metrics (volume, mass, peak von Mises stress, bounding box, toolpath lengths).
  - **View & Lenses:** Real-time visualization overlays (Section planes, FEA stress heatmaps, Sheet metal flat patterns, 2D Blueprints, 3MF nest packing, Zebra striping).
  - **Actions & Exports:** Deterministic output generators (`Export STL (Binary)`, `Export STL (ASCII)`, `Export STEP`, `Export 3MF`, `Export DXF`, `Export G-Code`).
- **Collapsible Code Drawer:** A subtle top-left `{ } Code` toggle (<kbd>Ctrl+`</kbd>) slides out an in-browser TypeScript Monaco editor, providing immediate bidirectional synchronization without obstructing the 3D viewport.

### Tenet II: Watertight, Zero-Copy Manufacturing Exports
- **Universal Multi-Format Output:** Native binary and ASCII STL generation directly in the Zig WebAssembly kernel (`cad_export_stl`, `cad_stl_free`) ensuring watertight 2-manifold topological guarantees.
- **Zero-Copy Flat Memory Slices:** All geometric evaluations export directly from WASM linear memory into Three.js `BufferGeometry` and downloadable typed arrays without serialization overhead.
- **Deterministic CI/CD Headless Pipelines:** Any computational recipe (`.ocad.ts`) can be executed headlessly via `@open-cad/core` or `opencad build` to generate production STL, STEP, 3MF, and G-code in automated pipelines.

### Tenet III: Zero-Account Distribution & Embeddability
- **Direct GitHub CDN Availability:** Every artifact—WebAssembly binaries, ESM modules, and TypeScript declarations—is hosted and served directly from GitHub (`cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/`).
- **Single-File Offline Portability:** Self-contained offline distribution (`opencad-portable.html`) embedding the compiled WebAssembly engine and 3D viewer directly with zero network dependencies.
- **Declarative Web Component:** `<opencad-viewer>` allows any developer or non-dev to embed full 3D models, parameter sliders, and 1-click STL downloads in any website with standard HTML attributes (`template`, `config`, `sliders`, `actions`).

---

## 3. Polyglot Architecture & Subsystems

| Subsystem | Primary Technologies | Primary Responsibility |
| :--- | :--- | :--- |
| **Kernel Core** | Zig (wasm32-freestanding), C ABI | Half-edge B-Rep store, PlaneGCS 2D solver, Boolean CSG engine, STL/STEP export. |
| **Physics & Flexures** | Zig, SIMD PCG Solver | Tet10 meshing, corotational FEA, compliance matrices, FACT synthesis. |
| **Implicit & Lattices** | Zig, SIMD Bytecode VM | Vectorized TPMS minimal surfaces, field-driven lattice modulation, Dual Contouring. |
| **Manufacturing & CAM** | Zig, BVH Raycaster | Analytical HLR 2D projections, 2.5D pocketing/profiling G-code, binary/ASCII STL. |
| **Web Runtime** | Three.js, Web Worker, `lil-gui` | Offscreen rendering, sub-shape raycast picking, floating controller, code drawer. |
| **Core SDK** | TypeScript, ESM | Fluent code-first modeling API, Web Component custom element, headless loaders. |
| **Polyglot Bindings** | Python (`wasmtime`), Rust (`wasmtime`) | Native scripts, data science notebooks, and embedded systems integration. |
