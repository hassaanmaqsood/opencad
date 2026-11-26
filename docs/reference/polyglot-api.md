# OpenCAD Polyglot API Reference

OpenCAD provides geometric modeling APIs for TypeScript, JavaScript, Python, Rust, and C.

---

## 1. Distribution and Release Artifacts

OpenCAD distributes prebuilt artifacts through GitHub Releases and the `dist` branch:

- **GitHub Releases:** Download `opencad-wasm-sdk.zip`, `opencad-portable.html`, `cad_kernel.wasm`, and `opencad-examples.zip` from [GitHub Releases](https://github.com/hassaanmaqsood/opencad/releases).
- **GitHub Distribution Branch (`dist`):** Import prebuilt ES modules and Web Components from `https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/`.
- **GitHub Pages CDN (`/opencad/cdn/`):** Access `opencad.mjs`, `opencad-element.mjs`, `opencad.d.ts`, and `cad_core.wasm` from `https://hassaanmaqsood.github.io/opencad/cdn/`.

---

## 2. TypeScript and JavaScript SDK (`@open-cad/core`)

### 2.1 Installation and Imports

#### Option A: Import from CDN
```javascript
import { cdml, Part, OpenCadKernel } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';
```

#### Option B: Install from GitHub via npm
```bash
npm install github:hassaanmaqsood/opencad#dist
```

### 2.2 Declarative 4-Step `cdml()` Builder

```typescript
import { cdml } from '@open-cad/core';

const doc = cdml('mm', '1e-7', '1e-11')
  .var('L', 100.0, { min: 50, max: 200, unit: 'mm' })
  .var('W', 60.0, { min: 30, max: 120, unit: 'mm' })
  .var('T', 12.0, { min: 4, max: 40, unit: 'mm' })
  .chartXY('c_base')
  .sketch('sk_plate', { chart: 'c_base', maxIter: 100 })
    .rectWire('w_outer', { width: 'ref(L)', height: 'ref(W)', role: 'outer' })
    .circleWire('w_bore', { radius: 10.0, role: 'hole' })
  .brep('solid_plate', { material: 'al6061' })
    .sweepExtrude('sw_base', { sketch: 'sk_plate', zExpr: 'ref(T) * v', capEnds: true })
  .probe('plate_vol', { type: 'volume', target: 'solid_plate' })
  .exportTessellate('solid_plate', { chordTol: 0.02, angleTol: 0.05 })
  .exportStep('solid_plate', { schema: 'AP214' })
  .exportStl('solid_plate', { binary: true });

const res = await doc.evaluate();
if (res.status === 0) {
  console.log('Volume (mm^3):', res.probe('plate_vol'));
  const stepText = res.toStep();
  const stlBytes = res.toStl();
}
```

### 2.3 Fluent `Part` (`FluentPart`) API

```typescript
import { OpenCadKernel } from '@open-cad/core';

const kernel = await OpenCadKernel.create();
try {
  const bracket = kernel.part('MountBracket')
    .sketch('XY')
      .rect(120, 80)
      .circle(20, 40, 6.5, { cut: true })
      .circle(100, 40, 6.5, { cut: true })
      .fillet2D(5.0)
    .extrude(20.0);

  const stepString = bracket.exportStep();
  const meshData = bracket.tessellate(0.01, 0.05);
  bracket.dispose();
} finally {
  kernel.deinit();
}
```

---

## 3. Python SDK (`wasmtime`)

### 3.1 Installation

```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git#subdirectory=bindings/python"
```

### 3.2 Python 4-Step CDML Builder

```python
import opencad as cad

doc = (cad.cdml(units="mm")
    .var("width", 80.0, min=40.0, max=120.0)
    .var("height", 20.0)
    .var("radius", 10.0)
    .chart_xy("c_xy")
    .sketch("sk1", chart="c_xy")
        .rect_wire("w_out", width="ref(width)", height="50.0", role="outer")
        .circle_wire("w_hole", radius="ref(radius)", role="hole")
    .brep("b1")
        .sweep_extrude("sw1", sketch="sk1", z_expr="ref(height) * v")
    .probe("vol", type="volume", target="b1")
    .export_step("b1")
    .export_stl("b1", binary=True))

res = doc.evaluate()
assert res.status == 0
print("Volume (mm3):", res.probe("vol"))
step_string = res.to_step()
stl_bytes = res.to_stl()
```

---

## 4. Rust Crate (`bindings/rust`)

Install from the `dist` branch:

```bash
cargo add opencad --git https://github.com/hassaanmaqsood/opencad --branch dist
```

```rust
use opencad::{CAD_CORE_WASM, Solid};

fn main() {
    println!("Embedded WASM size: {} bytes", CAD_CORE_WASM.len());
    let bracket = Solid::new("bracket", 6, 12, 8);
    let step_ap214 = bracket.export_step();
    let stl_binary = bracket.export_stl(true);
    println!("STEP bytes: {}, STL bytes: {}", step_ap214.len(), stl_binary.len());
}
```

---

## 5. Web Component (`<opencad-viewer>`) and Iframe Embed

### 5.1 Iframe Studio Embed
```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/studio/?embed=true&src=/opencad/examples/flange_normative.cdml&gui=true"
  width="100%"
  height="500"
  style="border: 0;"
  loading="lazy"
  title="OpenCAD 3D Viewer">
</iframe>
```

### 5.2 Custom Web Component
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/examples/flange_normative.cdml"
  data-gui="true"
  data-gui-vars="flange_w,bore_r"
  data-gui-exports="step,stl"
  style="width: 100%; height: 500px; display: block;">
</opencad-viewer>
```

---

## 6. C-ABI Header (`abi/cad_kernel.h`)

Include `abi/cad_kernel.h` when linking `cad_kernel.wasm` in C, C++, or Zig:

```c
#include "cad_kernel.h"

int main(void) {
    cad_status_t status = cad_kernel_init();
    if (status != CAD_SUCCESS) {
        return 1;
    }

    cad_solid_handle_t box = 0;
    cad_primitive_box(80.0, 40.0, 20.0, &box);
    cad_solid_release(box);

    cad_kernel_deinit();
    return 0;
}
```
