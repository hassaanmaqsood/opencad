# @open-cad/kernel-wasm

Zero-dependency TypeScript/JavaScript SDK and WebAssembly wrapper for **OpenCAD**: a high-performance parametric B-Rep CAD kernel and multi-workbench engineering suite.

## Features

- **`@open-cad/kernel-wasm/core`**: Core B-Rep solids, 2D/3D geometric constraint solver, DAG feature history, rollback, CSG Booleans, dress-up fillets/chamfers/shells, and STEP AP214 import/export.
- **`@open-cad/kernel-wasm/sheetmetal`**: K-factor bend allowances, bend deduction, flange builders, and flat-pattern unfolding.
- **`@open-cad/kernel-wasm/fea-flexure`**: Tet4/Tet10 tetrahedral mesher, PCG linear elasticity solver, 6x6 spatial compliance matrix extraction, and FACT flexure synthesis.
- **`@open-cad/kernel-wasm/implicit`**: Signed Distance Fields (SDF), TPMS Gyroid/Schwarz/Diamond lattices, field-driven thickness modulation, and Manifold Dual Contouring.
- **`@open-cad/kernel-wasm/cam-hlr`**: Analytical Hidden-Line Removal (HLR) projections, GD&T section slicing, 3MF build-volume nesting, and CNC G-code toolpath generation.

## Installation

```bash
npm install @open-cad/kernel-wasm
```

## Quick Start

```typescript
import { OpenCadCore, OpenCadSheetMetal } from '@open-cad/kernel-wasm';

// Initialize Core B-Rep Kernel
const core = await OpenCadCore.create('/cad_core.wasm');
const boxBuffers = core.generateBox(10.0, 20.0, 30.0);

// Sheet Metal Unfolding
const sm = await OpenCadSheetMetal.create('/cad_sheetmetal.wasm');
const bend = sm.calcBend(2.0, 3.0, 0.44, Math.PI / 2);
console.log(`Bend Allowance: ${bend.bendAllowance} mm`);
```

## License

Apache-2.0
