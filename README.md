# OpenCAD

> Parametric 3D CAD kernel, CDML v1.0 compiler, and web viewer.
> The kernel compiles from Zig to freestanding WebAssembly. The browser interface uses TypeScript and Three.js.

[![Live Studio](https://img.shields.io/badge/Live_Studio-hassaanmaqsood.github.io%2Fopencad-blue?style=for-the-badge&logo=googlechrome)](https://hassaanmaqsood.github.io/opencad/)
[![FEAScript Loop Demo](https://img.shields.io/badge/FEAScript_FEM_Loop-Live_Demo-0A2351?style=for-the-badge)](https://hassaanmaqsood.github.io/opencad/feascript-demo.html)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig Tests](https://img.shields.io/badge/Zig_Unit_Tests-199%2F199_Passed-brightgreen.svg)](./kernel-zig)
[![Verification Gates](https://img.shields.io/badge/Verification_Gates-All_9_Passed-success.svg)](./scripts/verify_gates.sh)

---

## Stability Notice

OpenCAD is in active development. Core operations pass verification tests, but five areas remain experimental:

1. **Nonlinear Constraint Solver:**
   The solver handles simple orthogonal profiles and convex shapes. Sketches with over-constrained dimensions or near-collinear tangent lines may fail to converge.

2. **CSG Mesh Booleans:**
   Boolean operations succeed on standard volumetric intersections. Coplanar faces and tangent boundary contacts can produce mesh errors.

3. **Edge Fillets:**
   Rolling-ball fillets operate on uniform convex and concave edges. Apex corners and variable-radius sweeps with high curvature may fail.

4. **Helical Threads and `cad_op_thread`:**
   CDML models build threads through revolved ridge profiles or helical `SE(3)` sweeps. Those sweeps scale station density up to `1025` steps and spill large meshes onto the WASM heap above `0x600000`. However, the standalone C-ABI function `cad_op_thread` remains an unimplemented stub until full B-Rep helical boolean cutting is ready.

5. **CDML Schema:**
   The XML schema and language bindings will evolve before version 2.1. Do not expect long-term API stability yet.

---

## System Architecture

OpenCAD generates solids from mathematical equations and sweeps. The engine contains no hardcoded box or cylinder meshes. The system consists of four parts:

1. **Kernel (`cad_kernel.wasm`):**
   A freestanding WebAssembly module. It exposes 18 C-ABI functions for automatic differentiation, sketch solving, curves, sweeps, and dual contouring.

2. **CDML v1.0 (Computational Design Markup Language):**
   An XML format that defines parametric variables, 2D sketches, 3D sweeps, physical probes, and file exports.

3. **Shared Memory (`SharedArrayBuffer`):**
   A single linear memory buffer (`0x000000..0x5F0000` fixed regions plus dynamic heap above `0x600000`). The 128-byte header stays pinned at `0x0F0000`. Meshes up to 1 MiB stay inline at `0x0F0080`, while larger meshes spill onto the heap above `0x600000` without copying data to WebGL.

4. **Web Studio and Embed Viewer:**
   A browser application with a split code editor and a Three.js 3D viewport. The viewer embeds into web pages through a custom HTML element.

---

## Installation and Distribution

OpenCAD does not publish packages to public npm or PyPI registries. You obtain releases from GitHub Actions and GitHub Releases.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OpenCAD Distribution Files                         │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│ GitHub Releases     │ GitHub dist Branch  │ GitHub Actions Artifacts        │
│ Standalone bundles  │ CDN & Git installs  │ Automated build outputs         │
└─────────────────────┴─────────────────────┴─────────────────────────────────┘
```

### 1. Download Release Artifacts (GitHub Releases)

Download precompiled archives from the [OpenCAD Releases](https://github.com/hassaanmaqsood/opencad/releases) page:

| File | Format | Description |
| :--- | :--- | :--- |
| `opencad-wasm-sdk.zip` | ZIP archive | Contains TypeScript declarations, JavaScript modules, C headers, and WASM binaries. |
| `opencad-portable.html` | HTML file | A single offline CAD studio. Runs in any modern web browser without an internet connection. |
| `cad_kernel.wasm` | WebAssembly | The freestanding mathematical kernel conforming to `abi/cad_kernel.h`. |
| `feascript-demo.html` | HTML demo | Closed-loop parametric CAD and FEAScript 2D thermal FEM demo ([live page](https://hassaanmaqsood.github.io/opencad/feascript-demo.html), [guide](./examples/feascript-loop/README.md)). |
| `opencad.mjs` | ES module | Standalone JavaScript module for browser and Node.js environments. |
| `opencad-element.mjs` | ES module | Web Component defining the `<opencad-viewer>` custom element. |
| `opencad-examples.zip` | ZIP archive | A collection of more than 1,000 verified CDML model files. |

### 2. JavaScript and TypeScript Usage

#### Option A: Import from CDN (Recommended for Browsers)
Import the ES module directly from the GitHub distribution branch:

```html
<script type="module">
  import { OpenCadKernel } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';

  const kernel = await OpenCadKernel.create();
  const result = kernel.evaluateCdml(xmlString);

  if (result.status === 0) {
    const mesh = kernel.getTessellationMesh();
    console.log(`Vertices: ${mesh.vertexCount}, Triangles: ${mesh.triangleCount}`);
    const stepText = kernel.exportStep();
    const stlData = kernel.exportStl({ binary: true });
  }
</script>
```

#### Option B: Install from GitHub via npm
Add the distribution branch directly to your `package.json`:

```bash
npm install github:hassaanmaqsood/opencad#dist
```

Import OpenCAD in your project:

```typescript
import { OpenCadKernel } from '@open-cad/core-sdk';

const kernel = await OpenCadKernel.create();
const result = kernel.evaluateCdml(xmlString);
```

#### Option C: Unpack the Release SDK Archive
Download `opencad-wasm-sdk.zip` from the latest release. Extract the archive into your project directory.

### 3. Embed 3D Models (Iframe and Web Component)

#### Option A: Embed with an HTML Iframe
Embed the live studio in any web page or documentation site with an `<iframe>` tag:

```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/?embed=true&src=https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/web-app/public/examples/flange_normative.cdml&code=false&params=false"
  width="100%"
  height="500"
  style="border: 1px solid #C8C0B4; border-radius: 6px;"
  loading="lazy"
  title="OpenCAD 3D Model">
</iframe>
```

Use these URL query parameters to control the embedded view:

| Parameter | Values | Effect |
| :--- | :--- | :--- |
| `embed` | `true` / `false` | Hides the code editor pane and renders a full-bleed 3D viewport. |
| `src` or `cdml` | URL or XML string | Loads a CDML model file from an HTTPS URL or inline XML string. |
| `code` or `code-toggle` | `true` / `false` | Hides or shows the Code toggle button and the editor pane. |
| `params` or `gui` | `true` / `false` | Hides or shows the Parameters panel and its toggle button. |
| `params-toggle` | `true` / `false` | Hides or shows the Parameters toggle button in the dock. |
| `vars` | Comma-separated IDs | Filters which variables appear in the Parameters panel. |
| `probes` | Comma-separated IDs | Filters which physical probes appear in the Parameters panel. |
| `exports` | `step`, `stl` | Filters which export buttons appear in the Parameters panel. |

Add `gui=true` and `params-toggle=false` when you want fixed parameter sliders without a hide button:

```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/?embed=true&src=https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/web-app/public/examples/flange_normative.cdml&gui=true&code-toggle=false&params-toggle=false&vars=flange_w,bore_r&exports=stl"
  width="100%"
  height="500"
  style="border: 0;"
  title="OpenCAD Parametric Flange">
</iframe>
```

#### Option B: Embed with the Web Component
Load the custom element from the CDN:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<!-- Embedded 3D viewer -->
<opencad-viewer
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/web-app/public/examples/flange_normative.cdml"
  data-gui="true"
  data-gui-vars="flange_w,flange_h,bore_r"
  data-gui-exports="step,stl">
</opencad-viewer>
```

### 4. Python Usage

#### Option A: Install from GitHub via pip
Install the Python bindings directly from the repository:

```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git#subdirectory=bindings/python"
```

#### Option B: Run Headless with Wasmtime
Download `cad_kernel.wasm` from the GitHub Release page. Use the Python SDK with `wasmtime`:

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
print("Status:", res.status)
print("Volume (mm3):", res.probe("vol"))
step_string = res.to_step()
stl_bytes = res.to_stl()
```

### 5. Offline Single-File Studio

Download `opencad-portable.html` from the release page. Double-click the file to open the CAD studio in your web browser. The file requires no server, no internet connection, and no installation.

---

## Product Roadmap

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             OpenCAD Roadmap                                 │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│ Track 1: Scripting  │ Track 2: 2D Vector  │ Track 3: Section Views          │
│ • Control structures│ • Software renderer │ • CDML section plane tag        │
│ • Loops & functions │ • SVG & DXF export  │ • 3D viewport clipping gizmo    │
├─────────────────────┴─────────────────────┼─────────────────────────────────┤
│ Track 4: Interactive Documentation        │ Track 5: Software Integration   │
│ • Live code examples with WebGL preview   │ • Blender addon                 │
│ • Step-by-step CAD tutorials              │ • FreeCAD and KiCad workflows   │
└───────────────────────────────────────────┴─────────────────────────────────┘
```

### Track 1: Procedural CDML Scripting
- Add procedural elements to CDML: `<for>`, `<while>`, `<if>`, and `<else>`.
- Support user-defined functions and reusable macros.
- Generate repeating mechanical patterns such as gear teeth, heat sinks, and lattices.

### Track 2: 2D Software Renderer and Vector Export
- Build an in-kernel 2D software rasterizer for test snapshot generation without a GPU.
- Export SVG files with semantic line classes for visible edges, hidden edges, and centerlines.
- Export DXF files for manufacturing with separate layers for geometry, dimensions, and annotations.

### Track 3: Dynamic Section Views
- Add a `<section-view>` element to CDML to define cutting planes in technical drawings.
- Add an interactive 3D clipping tool in the web studio to inspect interior geometry.

### Track 4: Interactive Documentation
- Build a documentation website with live code blocks and interactive WebGL viewports.
- Publish guides on constraint optimization, kinematic sweeps, and export formats.

### Track 5: 3D Software Integration
- Develop a Blender addon to import CDML models into Geometry Nodes.
- Develop a FreeCAD workbench to import CDML models into standard feature trees.
- Build an exchange tool for KiCad to generate 3D enclosures from circuit board outline files.

---

## Build and Verification

OpenCAD verifies mathematical precision, memory safety, and code requirements using automated test gates.

### 1. Build the Kernel and Run Native Tests
Compile the Zig kernel and run the unit tests:

```bash
cd kernel-zig
zig build test                        # Runs 198 unit tests with memory leak checks
zig build -Doptimize=ReleaseFast      # Compiles cad_kernel.wasm
```

### 2. Run Verification Gates
Execute all verification gates:

```bash
./scripts/verify_gates.sh all
```

| Gate | Target | Scope |
| :--- | :--- | :--- |
| **Gate 0** | Zero-Primitive Law | Verifies zero hardcoded box or cylinder meshes in the kernel. |
| **Gate 0B**| Anti-Cheat Scan | Scans AST and symbols to prevent hardcoded outputs. |
| **Gate 1** | WebAssembly Geometry | Verifies geometry generation occurs in WASM without JS fallbacks. |
| **Gate 2** | Native Zig Tests | Runs 198 native tests with zero memory leaks. |
| **Gate 3** | C-ABI Verification | Tests the 18 C-ABI functions in Node.js without a browser DOM. |
| **Gate 3B**| CDML Compiler | Tests CDML normative models, assertions, and parameter updates. |
| **Gate 4** | Shared Memory | Verifies data transfer across the single shared memory buffer. |
| **Gate 5** | Python Execution | Verifies the Python builder and headless wasmtime evaluation. |
| **Gate 6** | Browser E2E Tests | Runs Playwright tests for responsive layout and 60-FPS WebGL rendering. |

---

## Documentation Index

- [**ARCHITECTURE.md**](./ARCHITECTURE.md) — Technical description of linear memory, C-ABI functions, constraint solver, and contouring algorithms.
- [**CDML v1.0 Specification**](./docs/CDML%20v1.0%20%E2%80%94%20Computational%20Design%20Markup%20Language%20Format%20Specification.md) — Specification for the Computational Design Markup Language.
- [**Skill Guide (`docs/SKILL.md` / public `skill.md`)**](https://hassaanmaqsood.github.io/opencad/skill.md) — Complete usage, troubleshooting, and code examples for all languages ([repo copy](./docs/SKILL.md)).
- [**API Header (`abi/cad_kernel.h`)**](./abi/cad_kernel.h) — C header file defining kernel functions and data structures.
