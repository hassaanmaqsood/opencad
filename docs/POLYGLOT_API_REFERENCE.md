# OpenCAD Polyglot API Reference

OpenCAD exposes identical high-precision parametric modeling APIs across multiple programming languages and environments.

---

## 1. TypeScript & JavaScript SDK (`@open-cad/core`)

Install via standard npm or GitHub package:
```bash
npm install github:hassaanmaqsood/opencad#dist
# Or from CDN:
import { Part, OpenCadKernel } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';
```

### Fluent Parametric Chaining
```typescript
import { Part } from '@open-cad/core';

// Create a parametric bracket with holes, threads, datums, and booleans
const bracket = new Part('MountBracket')
  .sketch('XY')
  .rect(120, 80)
  .fillet2D(5.0)
  .holeWizard({
    type: 'cbore',
    diameter: 6.5,
    depth: 20.0,
    cboreDiameter: 11.0,
    cboreDepth: 6.5,
    position: [30, 40, 20],
  })
  .thread({
    standard: 'metric_coarse',
    nominalDiameter: 8.0,
    pitch: 1.25,
    length: 15.0,
  })
  .datumPlane({ type: 'offset', offset: 10.0, normal: [0, 0, 1] })
  .extrude(20.0);

// Export production artifacts
const stepString = bracket.exportStep();
const meshData = bracket.tessellate(0.01, 0.05);

bracket.dispose(); // Or automatic disposal with `using` syntax
```

---

## 2. Python SDK (`opencad`)

Install via `pip`:
```bash
pip install git+https://github.com/hassaanmaqsood/opencad.git
```

### Pure-WASM Execution
```python
import opencad as cad

with cad.part("DroneArm") as arm:
    # Build 2D sketch with spline and slot
    arm.sketch(cad.XY)\
       .slot(c1=(10, 0), c2=(90, 0), radius=15)\
       .circle(cx=10, cy=0, radius=4, cut=True)\
       .extrude(12.0)
    
    # Apply 3D edge dress-up
    arm.fillet(radius=2.0)
    
    # Add hole wizard counterbore mounts
    arm.hole_wizard(diameter=5.0, depth=12.0, hole_type="cbore")
    
    # Export compliant ISO-10303-21 STEP and 3MF production package
    arm.export_step("drone_arm.step")
    arm.export_3mf("drone_arm.3mf")
```

---

## 3. Rust Crate (`opencad`)

Add to `Cargo.toml`:
```toml
[dependencies]
opencad = { git = "https://github.com/hassaanmaqsood/opencad.git" }
```

### Embedded Kernel Usage
```rust
use opencad::{part, box_solid, Solid};

fn main() {
    let solid = part("FlangeMount")
        .fillet(1.5)
        .chamfer(1.0)
        .hole_wizard(6.5, 15.0)
        .thread(8.0, 1.25, 12.0);

    let step_text = solid.export_step();
    println!("Exported STEP ({} bytes)", step_text.len());
}
```

---

## 4. Web Component (`<opencad-viewer>`)

Embed interactive 3D CAD anywhere with zero JavaScript build tooling:
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer 
  src="https://example.com/models/bracket.step"
  workbench="design"
  view="isometric"
  grid="true"
  style="width: 800px; height: 500px; display: block;">
</opencad-viewer>
```

---

## 5. WebMCP & JSON-RPC Agent API (`window.opencadAgent`)

Autonomous AI agents inspect and operate the CAD kernel via `window.opencadAgent`:

```javascript
// 1. Execute CAD Commands
await window.opencadAgent.executeCommand('createBox', { dimensions: [100, 60, 20] });
await window.opencadAgent.executeCommand('applyFillet', { radius: 3.0 });

// 2. Multi-Angle Viewport Snapshot Capture
const snapshots = await window.opencadAgent.captureViewport(['front', 'top', 'isometric']);
// snapshots.isometric -> "data:image/png;base64,..."

// 3. Topological B-Rep Invariant Check
const val = await window.opencadAgent.validateBRep();
console.log(val.isValid); // true
console.log(val.eulerCharacteristic); // 2 (V - E + F = 2)

// 4. Retrieve Parametric DAG Nodes
const dag = window.opencadAgent.getFeatureDag();
```

---

## 6. C ABI Specification (`abi/cad_kernel.h`)

For low-level bindings (C++, C#, Zig, Go):
```c
#include "cad_kernel.h"

cad_status_t status = cad_kernel_init();
cad_solid_handle_t solid;
cad_op_box(100.0, 50.0, 20.0, &solid);

// Wave 13: Hole Wizard & Modeled Threads
cad_hole_wizard_op_t hole = {
    .hole_type = CAD_HOLE_CBORE,
    .diameter = 6.5,
    .depth = 20.0,
    .cbore_diameter = 11.0,
    .cbore_depth = 6.5
};
cad_op_hole_wizard(solid, &hole, &solid);

cad_kernel_deinit();
```
