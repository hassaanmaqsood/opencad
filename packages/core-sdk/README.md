# @open-cad/core

**Standalone zero-dependency open-source parametric B-Rep CAD core & geometric solver for Web, Node.js, Bun, and CLI.**

## Features
- **Deterministic Half-Edge B-Rep Engine:** Exact analytical solid modeling with manifold validation and Euler-Poincaré invariants.
- **2D/3D Constraint Solver:** Rank-revealing QR decomposition and Levenberg-Marquardt solver with Degrees of Freedom tracking.
- **Parametric Feature Tree DAG:** State snapshotting and instant rollback bar evaluation.
- **Persistent Topological Naming:** Persistent 64-bit `CadTopoId` tracking faces, edges, and vertices across upstream model edits.
- **Universal Plugin Extension ABI:** Extend core DAG operations dynamically across companion workbenches via `CadPluginOpVTable`.
- **Sandbox Security:** Enforce deterministic resource limits (`max_wasm_memory_bytes`, `max_solver_iterations`, `eval_timeout_ms`).
- **STEP ISO 10303-21 AP214:** Bi-directional import and export.
- **High-Performance WebAssembly:** Under 450 KiB binary footprint (well below 1.8 MiB threshold) with zero JS runtime dependencies.

## Installation
```bash
npm install @open-cad/core
```

## Quick Start
```typescript
import { OpenCadKernel } from '@open-cad/core';

// In browser / Web Worker
const cad = await OpenCadKernel.create('/cad_core.wasm');

// In Node.js or Bun
// const cad = await OpenCadKernel.create('./path/to/cad_core.wasm');

// Create a parametric solid
const box = cad.createBox(10.0, 20.0, 30.0);

// Tessellate into flat zero-copy buffers for Three.js
const mesh = cad.tessellate(box, 0.1, 0.2);
console.log(`Vertices: ${mesh.vertexCount}, Triangles: ${mesh.triangleCount}`);

// Export to STEP
const stepData = cad.exportStep(box);

// Clean up
cad.releaseSolid(box);
```

## License
Apache-2.0
