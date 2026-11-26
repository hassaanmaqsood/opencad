# OpenCAD Polyglot API Reference

OpenCAD provides programmatic geometric modeling APIs across multiple programming languages and runtime environments.

---

## 1. Distribution and Release Artifacts

OpenCAD does not distribute packages through public npm or PyPI registries. Obtain builds from GitHub Actions and GitHub Releases:

- **GitHub Releases:** Download precompiled zip archives, standalone ES modules, and WebAssembly binaries from the repository release page.
- **GitHub Distribution Branch (`dist`):** Pull prebuilt ESM bundles and Web Components directly via Git or CDN URLs.
- **GitHub Actions Workflows:** Download automated build artifacts from recent workflow runs on the GitHub Actions tab.

---

## 2. TypeScript and JavaScript SDK

### 2.1 Installation and Imports

#### Option A: Import from CDN
Import the ES module directly from the GitHub distribution branch:

```javascript
import { Part, OpenCadKernel } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';
```

#### Option B: Install from GitHub
Install the package directly from the distribution branch:

```bash
npm install github:hassaanmaqsood/opencad#dist
```

### 2.2 Fluent Modeling Example

```typescript
import { Part } from '@open-cad/core';

// Create a parametric bracket with sketch profile and extrusion
const bracket = new Part('MountBracket')
  .sketch('XY')
  .rect(120, 80)
  .circle(20, 40, 6.5, { cut: true })
  .circle(100, 40, 6.5, { cut: true })
  .fillet2D(5.0)
  .extrude(20.0);

// Export production files
const stepString = bracket.exportStep();
const meshData = bracket.tessellate(0.01, 0.05);

// Release WebAssembly memory
bracket.dispose();
```

---

## 3. Python SDK

### 3.1 Installation

Install the Python bindings directly from the GitHub repository:

```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git#subdirectory=bindings/python"
```

You can also download `cad_kernel.wasm` from the GitHub Release page and run it with `wasmtime`.

### 3.2 Python CDML Builder Example

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

## 4. Rust Crate

Add the GitHub repository to `Cargo.toml`:

```toml
[dependencies]
opencad = { git = "https://github.com/hassaanmaqsood/opencad.git" }
```

### 4.1 Rust Example

```rust
use opencad::{part, Solid};

fn main() {
    let solid = part("FlangeMount")
        .sketch("XY")
        .rect(100.0, 50.0)
        .extrude(20.0);

    let step_text = solid.export_step();
    println!("Exported STEP ({} bytes)", step_text.len());
}
```

---

## 5. Web Component (`<opencad-viewer>`)

Embed an interactive 3D model into any web page without a build step:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer 
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/examples/lib/0001_bracket.cdml"
  data-gui="true"
  style="width: 100%; height: 500px; display: block;">
</opencad-viewer>
```

---

## 6. C-ABI Specification (`abi/cad_kernel.h`)

For low-level integrations in C, C++, or Zig, include the C header and link to the WebAssembly kernel:

```c
#include "cad_kernel.h"

int main(void) {
    cad_status_t status = cad_kernel_init();
    if (status != CAD_SUCCESS) {
        return 1;
    }

    // Allocate document and execute operations
    cad_solid_handle_t solid = 0;
    // Perform operations through the 18 C-ABI functions

    cad_kernel_deinit();
    return 0;
}
```
