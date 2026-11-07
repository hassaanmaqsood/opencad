---
name: opencad-esm-kernel
description: Authoritative developer skill and instruction manual for Large Language Models (LLMs) and autonomous agents to construct parametric 3D CAD models, evaluate CDML v1.0, tessellate geometries, and export AP214 STEP/STL files using the OpenCAD pure-math WebAssembly kernel via modern ESM JavaScript and TypeScript.
---

# Skill: OpenCAD Pure-Math Kernel via ESM JavaScript

## 1. Overview & Capabilities
OpenCAD (`open-parametric-cad`) is a zero-primitive computational CAD kernel compiled from native Zig to freestanding WebAssembly (`wasm32-freestanding`). It operates with double-precision floating-point arithmetic ($10^{-7}\text{ mm}$ linear tolerance, $10^{-11}\text{ rad}$ angular tolerance).

This skill guides LLMs to generate valid, bug-free, high-performance ESM JavaScript / TypeScript code that interfaces with OpenCAD via:
1. **High-Level Fluent API (`Part` / `FluentPart`):** Ergonomic parametric chaining, 2D sketcher, extrusion/revolve, 3D fillets, hole wizards, threads, and auto-disposing handles (`using` / `.dispose()`).
2. **Declarative CDML 4-Step Builder (`cdml()` / `CdmlDocument`):** Zero-primitive normative Computational Design Markup Language generator with live in-process evaluation, physical probes, and export pipeline.
3. **Low-Level Kernel Client (`OpenCadKernel`):** Direct interface to the 18 C-ABI functions, managing flat WebAssembly memory slices, tessellation buffers, and topological naming IDs (`TopoId`).

---

## 2. Quickstart Cheatsheet for LLMs

### Recipe A: High-Level Fluent Parametric Part (ESM JS)
```javascript
import { Part } from '@open-cad/core';
// In browser/Deno/Bun without package manager:
// import { Part } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';

// 1. Create a part with parametric chaining
const bracket = new Part('MotorBracket')
  .sketch('XY')
  .rect(120, 80)
  .circle(20, 40, 6.5, { cut: true })
  .circle(100, 40, 6.5, { cut: true })
  .fillet2D(5.0)
  .extrude(15.0)
  .fillet({ select: '>Z', radius: 2.0 })
  .holeWizard({
    type: 'cbore',
    diameter: 8.5,
    depth: 15.0,
    cboreDiameter: 14.0,
    cboreDepth: 6.0,
    position: [60, 40, 15],
  });

// 2. Export production deliverables
const stepText = bracket.exportStep();         // ISO-10303-21 AP214 string
const stlBytes = bracket.exportStl({ binary: true }); // Uint8Array
const mesh = bracket.tessellate(0.01, 0.05);   // { positions, normals, indices }

// 3. Always dispose to avoid WASM memory leaks
bracket.dispose();
```

### Recipe B: CDML 4-Step Engineering Surface API
```javascript
import { cdml } from '@open-cad/core';

// 1. Author parametric document
const doc = cdml('mm')
  .var('flange_dia', 140.0, { min: 80, max: 200, unit: 'mm' })
  .var('bolt_pcd', 'flange_dia * 0.75')
  .var('thickness', 18.0)
  .chartXY('c_base')
  .sketch('sk_flange', { chart: 'c_base' })
    .circleWire('w_outer', { radius: 'ref(flange_dia) / 2.0', role: 'outer' })
    .circleWire('w_bore', { radius: '25.0', role: 'hole' })
  .brep('flange_solid')
    .sweepExtrude('sw_base', { sketch: 'sk_flange', zExpr: 'ref(thickness) * v' })
    .fillet('f_rim', { edgePredicate: 'z > 17.9', radiusExpr: '2.0' })
  .probe('mass_volume', { type: 'volume', target: 'flange_solid' })
  .exportTessellate('flange_solid', { chordTol: 0.02, angleTol: 0.05 })
  .exportStep('flange_solid', { schema: 'AP214' })
  .exportStl('flange_solid', { binary: true });

// 2. Evaluate in-process via WASM
const res = await doc.evaluate();
console.log(`Status: ${res.status}, Volume: ${res.probe('mass_volume')} mm³`);
const stepString = res.toStep();
const stlBinary = res.toStl();
```

---

## 3. Package Installation & ESM Resolution

### 3.1 Node.js / Bun / TypeScript
Install package:
```bash
npm install @open-cad/core
# Or directly from the GitHub repository distribution branch:
npm install github:hassaanmaqsood/opencad#dist
```
Module Import:
```typescript
import {
  Part,
  OpenCadKernel,
  cdml,
  evalCDML,
  CdmlDocument,
  loadCoreWasm
} from '@open-cad/core';
```

### 3.2 Modern Browser / CDN / ES Modules
OpenCAD provides a zero-dependency standalone ESM bundle:
```html
<script type="module">
  import { Part, cdml, OpenCadKernel } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';

  const part = new Part('Enclosure').box(100, 60, 40).shell(2.5);
  console.log(part.exportStep());
  part.dispose();
</script>
```

---

## 4. High-Level Fluent API Specification (`Part`)

The `Part` class (exported as both `Part` and `FluentPart`) provides a unified CAD modeling interface with automatic disposal mechanisms.

### 4.1 Lifecycle & Memory Management
In WebAssembly, native solid handles (`CadSolidHandle`) reside in the kernel heap.
- **Explicit Disposal:** Call `part.dispose()` when finished.
- **TC39 Explicit Resource Management (`using`):**
  ```typescript
  {
    using part = new Part('Bracket').box(50, 50, 50);
    // Automatically disposed when exiting block scope
  }
  ```
- **Garbage Collection Fallback:** An internal `FinalizationRegistry` acts as a safety net if `dispose()` is omitted.

### 4.2 2D Sketching (`part.sketch(plane)`)
Plane options: `'XY'`, `'XZ'`, `'YZ'`, or a custom datum plane identifier.

```typescript
const sketch = part.sketch('XY');

// Geometric Entities:
sketch.rect(width, height);                             // Centered rectangular wire
sketch.circle(cx, cy, radius, { cut?: boolean });       // Circle (cut: true marks it as inner hole)
sketch.slot([x1, y1], [x2, y2], radius);                // Obround slot between 2 centers
sketch.polygon(cx, cy, radius, sideCount, rotationRad); // Regular inscribed polygon
sketch.spline([[0, 0], [10, 15], [30, 5]], degree);    // Rational B-Spline curve
sketch.ellipse(cx, cy, rX, rY, rotationRad);            // Elliptical boundary
sketch.text('OPENCAD', 12, [0, 0]);                     // TrueType vectorized geometry

// Modifications:
sketch.fillet2D(radius, cornerIndex?);                  // 2D vertex rounding
sketch.chamfer2D(distance, cornerIndex?);               // 2D vertex beveling
sketch.offset(distance);                                // Normal curve offset

// Construction Mode:
sketch.construction(true).circle(0, 0, 50).construction(false);

// Extrude or Revolve sketch into 3D:
const extrudedPart = sketch.extrude(depthInMm);
const revolvedPart = sketch.revolve(angleInDegrees, 'Y');
```

### 4.3 3D Primitives & Operations
```typescript
// Primitives
part.box(dx, dy, dz);               // Box aligned with origin corner
part.cylinder(radius, height);       // Cylinder along Z axis

// Edge & Face Dress-up
part.fillet({ select: '>Z', radius: 3.0 }); // Directional face/edge selector
part.fillet(2.5, [1, 4, 7]);                // Specific edge indices
part.chamfer(1.5, [2, 3]);                  // Chamfer edge bevel
part.shell(thickness);                      // Hollow out solid with uniform wall thickness

// Hole Wizard
part.holeWizard({
  type: 'cbore' | 'csink' | 'threaded' | 'through',
  diameter: 6.5,
  depth: 25.0,
  cboreDiameter: 11.0,
  cboreDepth: 6.5,
  csinkAngle: 90,
  position: [x, y, z],
});

// Fasteners & Threads
part.thread({
  standard: 'metric_coarse', // 'metric_coarse' | 'metric_fine' | 'unc' | 'unf'
  nominalDiameter: 8.0,
  pitch: 1.25,
  length: 20.0,
});

// Datums & Splitting
part.datumPlane({ type: 'offset', offset: 12.0, normal: [0, 0, 1] });
const { positive, negative } = part.splitBody({ origin: [0, 0, 10], normal: [0, 0, 1] });

// Constructive Solid Geometry (CSG Booleans)
part.add(toolPart);   // Boolean Union
part.cut(toolPart);   // Boolean Difference
```

### 4.4 Advanced Workbenches
```typescript
// Implicit TPMS Lattice Infill (nTop-style Minimal Surfaces)
part.implicit.gyroidInfill({
  preserve: ['@cylindrical', '<Z', '>Z'], // Preserve structural skins
  cellSize: 8.0,                          // Unit cell repeat period in mm
  wallThickness: 1.2,                      // Sheet TPMS wall thickness
});

// Structural Flexure Synthesis (FACT Compliance Matrix)
part.flexure.analyze({
  fixed: '<X', // Fixed ground clamp
  stage: '>X', // Mobile motion stage
});
```

---

## 5. Declarative CDML 4-Step Surface API (`cdml()`)

The CDML builder outputs normative XML compliant with the **OpenCAD CDML v1.0 Specification** (§6–§14).

```typescript
import { cdml } from '@open-cad/core';

const doc = cdml('mm', '1e-7', '1e-11')
  // Step 1: Definitions (Variables, Expressions, Assertions, Field Slots)
  .var('L', 100.0, { min: 50, max: 200, unit: 'mm' })
  .var('W', 60.0)
  .var('T', 12.0)
  .expr('aspect_ratio', 'ref(L) / ref(W)')
  .fieldSlot('von_mises_stress', 0, { semantic: 'stress', defaultVal: 45.0 })

  // Step 2: Charts & 2D Variational Sketches
  .chartXY('c_base')
  .sketch('sk_profile', { chart: 'c_base', maxIter: 100 })
    .rectWire('w_outer', { width: 'ref(L)', height: 'ref(W)', role: 'outer' })
    .circleWire('w_bore', { radius: '10.0', role: 'hole' })

  // Step 3: B-Rep Sweeps, Lofts & Fillets
  .brep('solid_body', { material: 'al6061' })
    .sweepExtrude('sw_base', { sketch: 'sk_profile', zExpr: 'ref(T) * v', capEnds: true })
    .fillet('f_edges', { edgePredicate: 'z > 11.9', radiusExpr: '1.5' })

  // Step 4: Physical Probes & Production Exports
  .probe('part_vol', { type: 'volume', target: 'solid_body' })
  .probe('surface_area', { type: 'area', target: 'solid_body' })
  .exportTessellate('solid_body', { chordTol: 0.01, angleTol: 0.05 })
  .exportStep('solid_body', { schema: 'AP214' })
  .exportStl('solid_body', { binary: true });

// Convert to raw XML string
const xml = doc.toCDML();

// Evaluate directly against the WebAssembly pure-math kernel
const res = await doc.evaluate();
const volume = res.probe('part_vol');
const stepFile = res.toStep();
const stlBinary = res.toStl();
```

---

## 6. Low-Level WASM Kernel API (`OpenCadKernel`)

When high performance or zero-copy buffer manipulation is required:

```typescript
import { OpenCadKernel, CadStatus } from '@open-cad/core';

// 1. Instantiate kernel with underlying WebAssembly binary
const kernel = await OpenCadKernel.create();

try {
  // 2. Synthesize geometric solids via C-ABI
  const boxHandle = kernel.createBox(80, 40, 20);
  const cylHandle = kernel.createCylinder(12, 30);

  // 3. Tessellate solid into flat TypedArrays
  // Returns { positions: Float32Array, normals: Float32Array, indices: Uint32Array, vertexCount, triangleCount }
  const mesh = kernel.tessellate(boxHandle, 0.02, 0.05);

  // 4. Export exact B-Rep STEP text
  const stepText = kernel.exportStep(boxHandle);

  // 5. Release handles manually to free C-ABI memory
  kernel.releaseSolid(boxHandle);
  kernel.releaseSolid(cylHandle);
} finally {
  kernel.deinit();
}
```

---

## 7. Three.js Viewport Integration Pattern

Converting OpenCAD `CadMesh` data into Three.js `BufferGeometry`:

```typescript
import * as THREE from 'three';
import { type CadMesh } from '@open-cad/core';

export function createThreeGeometryFromCadMesh(mesh: CadMesh): THREE.BufferGeometry {
  const geometry = new THREE.BufferGeometry();

  // Set interleaved or direct float vertex buffers
  geometry.setAttribute('position', new THREE.BufferAttribute(mesh.positions, 3));
  geometry.setAttribute('normal', new THREE.BufferAttribute(mesh.normals, 3));
  geometry.setIndex(new THREE.BufferAttribute(mesh.indices, 1));

  // Compute bounding box & sphere for camera framing
  geometry.computeBoundingBox();
  geometry.computeBoundingSphere();

  return geometry;
}

export function createCadMeshObject(mesh: CadMesh): THREE.Group {
  const group = new THREE.Group();
  const geometry = createThreeGeometryFromCadMesh(mesh);

  // 1. Shaded Solid Body
  const material = new THREE.MeshStandardMaterial({
    color: 0x2563eb,
    metalness: 0.25,
    roughness: 0.35,
    polygonOffset: true,
    polygonOffsetFactor: 1,
    polygonOffsetUnits: 1,
  });
  const solidMesh = new THREE.Mesh(geometry, material);
  group.add(solidMesh);

  // 2. Technical Edge Wireframe Overlay
  const wireframeMaterial = new THREE.MeshBasicMaterial({
    color: 0x93c5fd,
    wireframe: true,
    transparent: true,
    opacity: 0.4,
  });
  const wireframeMesh = new THREE.Mesh(geometry, wireframeMaterial);
  group.add(wireframeMesh);

  return group;
}
```

---

## 8. Web Worker Parallelization Pattern

Never block the UI main thread on complex solves. Use the OpenCAD Web Worker bridge:

```typescript
// main.ts
const worker = new Worker(new URL('./cad.worker.ts', import.meta.url), { type: 'module' });

worker.postMessage({
  type: 'EVALUATE_CDML',
  cdmlXml: myCdmlString,
});

worker.onmessage = (event) => {
  const { status, mesh, step, diagnostic } = event.data;
  if (status === 0 && mesh) {
    // mesh.positions and mesh.indices are transferred zero-copy
    renderToViewport(mesh);
  } else {
    console.error('CAD Evaluation Error:', diagnostic);
  }
};
```

---

## 9. Rules, Constraints & Anti-Patterns for LLMs

| Rule | Rationale & Enforcement |
| :--- | :--- |
| **Zero-Primitive Law** | Never attempt to construct raw Three.js boxes/spheres and claim they are CAD solids. OpenCAD models MUST be generated through `Part`, `cdml()`, or `OpenCadKernel` to generate exact B-Rep boundary curves and valid STEP exports. |
| **Explicit Disposal** | WebAssembly linear memory cannot be garbage-collected automatically by JavaScript engines in all environments. Always call `part.dispose()` or `using part = ...` in production code. |
| **Units: Millimeters** | All dimensions in OpenCAD are millimeters (`mm`). Angular arguments in 2D sketching (`revolve`) are degrees ($0^\circ$–$360^\circ$); internal trig functions evaluate in radians. |
| **Tolerance Rules** | Linear default tolerance is $10^{-7}\text{ mm}$. Angular tolerance is $10^{-11}\text{ rad}$. For high-speed screen tessellation, set `chordTol = 0.05` and `angleTol = 0.1`. For high-precision CNC tooling, set `chordTol = 0.005`. |
| **Closed Wires** | All profile wires intended for `extrude` or `revolve` must form a single closed loop without self-intersections. Holes must be flagged with `role="hole"` or `cut: true`. |
| **Handle Verification** | Check that solid handles are non-zero before passing them to boolean or export operations. Catch and log `CadStatus` errors gracefully. |
