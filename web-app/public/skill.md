# OpenCAD (`hassaanmaqsood.github.io/opencad/skill.md`)

> Authoritative integration handbook, language reference, CDML v1.0 cookbook, and troubleshooting guide for the OpenCAD WebAssembly kernel (`cad_kernel.wasm` / `cad_core.wasm`).

- **Public Skill URL:** `https://hassaanmaqsood.github.io/opencad/skill.md`
- **Live Web Studio & Iframe Embed Endpoint:** `https://hassaanmaqsood.github.io/opencad/`
- **GitHub Repository:** `https://github.com/hassaanmaqsood/opencad`
- **CDN Distribution Branch (`@dist`):** `https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/`
- **Releases & Offline Studio (`opencad-portable.html`, `opencad-wasm-sdk.zip`):** `https://github.com/hassaanmaqsood/opencad/releases`

---

## 1. Architecture & Core Laws

OpenCAD is a zero-primitive mathematical CAD kernel written in freestanding Zig and compiled to WebAssembly (`~925 KB`).

### Core Constraints for Code & Model Generation
1. **Zero-Primitive Law:** Never build raw Three.js boxes, cylinders, or spheres and call them CAD models. Construct geometry through CDML v1.0 XML, the 4-step `cdml()` builder, `OpenCadKernel`, or the C-ABI so every solid has exact B-Rep/SDF definitions and AP214 STEP / STL exports.
2. **Units & Tolerances:** Linear dimensions are millimeters (`mm`). Sketch solver default tolerance is `1e-7` (`0.1 nm`), and angular tolerance is `1e-11 rad`. Default viewport tessellation tolerances are `chord-tol="0.02"` (`mm`) and `angle-tol="0.05"` (`rad`).
3. **Closed Non-Intersecting Wires:** All 2D sketch profiles intended for sweeps or revolves must form closed loops. Inner cutouts must set `role="hole"`.
4. **Explicit Memory Lifetime:** Native handles in `OpenCadKernel`, C, and Rust must be freed via `releaseSolid()` / `cad_solid_release()` / `handle_free()` when done.

### Hybrid Two-Tier Shared Memory Layout (`SharedArrayBuffer`)

The WASM module imports a single shared linear memory (`env.memory`, `initial: 128` pages = `8 MiB`, `shared: true`):

| Address Range | Region | Purpose |
| :--- | :--- | :--- |
| `0x000000 .. 0x000040` | Control Block | `magic = 0x4F434144` (`"OCAD"`), `version = 2`, offsets, active count, `tess_generation_counter` at `0x001C`. |
| `0x001000 .. 0x0EFFFF` | Solid Arena | Parametric feature DAG, NURBS surfaces, half-edge topology, and CSG nodes. |
| `0x0F0000 .. 0x0F007F` | Tessellation Header | Pinned 128-byte header describing vertex/triangle counts, payload byte offsets, bbox (`f64[6]`), and spillover flags. |
| `0x0F0080 .. 0x1EFFFF` | Tier-1 Inline Payload | Fast zero-allocation scratch for meshes `<= 1,048,448` bytes (`0x0FFF80` bytes, up to `~21,842` triangles). |
| `0x1F0000 .. 0x3EFFFF` | Field Buffer | 3D scalar/vector field grids sampled via `field_scalar(...)`. |
| `0x3F0000 .. 0x5EFFFF` | Export Scratch | AP214 STEP (`0x3F0000..0x4EFFFF`) and binary/ASCII STL (`0x4F0000..0x5EFFFF`) output buffers. |
| `>= 0x600000` | Tier-2 Dynamic Heap | Reusable 8-byte aligned heap spillover buffer for large meshes (`> 1 MiB`), e.g. helical threads and dense Gyroid lattices. |

#### 128-Byte Pinned Tessellation Header (`0x0F0000`)

Always read array offsets directly from the header rather than hardcoding `0x0F0080`:

| Byte Offset | Type | Field | Notes |
| :--- | :--- | :--- | :--- |
| `0x00` | `u32` | `solid_id_lo` | Lower 32 bits of solid handle |
| `0x04` | `u32` | `vertex_count` | Number of 3D vertices |
| `0x08` | `u32` | `triangle_count` | Number of triangles |
| `0x0C` | `u32` | `pos_offset` | Byte offset to `f32[vertex_count * 3]` positions (in `0x0F0080` or `>= 0x600000`) |
| `0x10` | `u32` | `nrm_offset` | Byte offset to `f32[vertex_count * 3]` normals |
| `0x14` | `u32` | `idx_offset` | Byte offset to `u32[triangle_count * 3]` triangle indices |
| `0x18` | `u32` | `face_offset` | Byte offset to `face_meta[triangle_count]` (`24` bytes per triangle) |
| `0x1C` | `u32` | `solid_id_hi` | Upper 32 bits of solid handle |
| `0x20 .. 0x4F` | `f64[6]` | `bbox` | `[min_x, min_y, min_z, max_x, max_y, max_z]` |
| `0x50` | `u32` | `is_heap_spillover` | `0` = Tier-1 inline (`0x0F0080`), `1` = Tier-2 heap (`>= 0x600000`) |
| `0x54` | `u32` | `payload_byte_len` | Total byte length of the active tessellation payload |

---

## 2. Declarative CDML v1.0 (XML)

Every CDML document has up to four top-level blocks inside `<cdml version="1.0" units="mm">`: `<imports>`, `<defs>`, `<body>`, and `<exports>`.

### Example A: Parametric Flange with 2D Constrained Sketch, Sweep, and Probes

```xml
<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="flange_w" value="90.0" min="60.0" max="150.0" unit="mm"/>
    <var id="flange_h" value="16.0" min="8.0"  max="40.0"  unit="mm"/>
    <var id="bore_r"   value="15.0" min="8.0"  max="25.0"  unit="mm"/>
    <expr id="half_w"  expr="ref(flange_w) / 2"/>
    <assert id="bore_clearance"
      expr="ref(half_w) - ref(bore_r) - 5.0"
      error="bore exceeds flange margin"/>
  </defs>
  <body>
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="unit_e2"  expr="dot(e2, e2) - 1.0"/>
        <residual id="ortho"    expr="dot(e1, e2)"/>
        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>

    <sketch id="sk_flange" chart="chart_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-45.0" v="-45.0"/>
        <point2d id="v1" u=" 45.0" v="-45.0"/>
        <point2d id="v2" u=" 45.0" v=" 45.0"/>
        <point2d id="v3" u="-45.0" v=" 45.0"/>
      </vars>
      <wire id="wire_outer" closed="true" role="outer">
        <curve id="s0" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="s1" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="s2" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="s3" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(bore_r) * cos(2 * PI * t)"
          v-expr="ref(bore_r) * sin(2 * PI * t)"/>
      </wire>
      <constraints>
        <residual id="cx"     expr="v0.u + v1.u"/>
        <residual id="cy"     expr="v0.v + v3.v"/>
        <residual id="sym"    expr="v2.u + v3.u"/>
        <residual id="h0"     expr="v1.v - v0.v"/>
        <residual id="h1"     expr="v2.v - v3.v"/>
        <residual id="ortho"  expr="dot(v1 - v0, v2 - v1)"/>
        <residual id="width"  expr="norm(v1 - v0) - ref(flange_w)"/>
        <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
      </constraints>
    </sketch>

    <brep id="solid_flange" material="al6061">
      <sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
    </brep>

    <probe id="housing_volume" type="volume" target="solid_flange"/>
  </body>
  <exports>
    <tessellate target="solid_flange" chord-tol="0.02" angle-tol="0.05"/>
    <step target="solid_flange" schema="AP214"/>
    <stl target="solid_flange" binary="true"/>
  </exports>
</cdml>
```

### Example B: Continuous Helical Screw Thread & Lead-In/Lead-Out Run-Out via SE(3) Sweep

Combine `<translate>`, `<rotate>`, and `<scale>` in `<trajectory>` — or bind a 3D `<curve>` via `path="curve_id" frame="rmf|axis-locked|fixed"` with `<twist>` and `<scale>`. Multi-section sweeps use `<section v="..." wire="..." / sketch="..."/>` with `continuity="G0|G1|G2"` (also shared with `<loft>`). The kernel validates local regularity in the co-moving body frame (`|C'(u) x (Omega_body(v) x C(u) + V_body(v))| > 0`) and global turn-to-turn axial pitch clearance (`delta_z_profile < pitch`), so low-lead-angle ISO threads (`r >> pitch / (2*PI)`) sweep cleanly without false `0x0401` rejections.

```xml
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="r_root" value="3.32" min="2.0" max="10.0" unit="mm"/>
    <var id="r_crest" value="4.00" min="2.5" max="12.0" unit="mm"/>
    <var id="pitch"  value="1.25" min="0.5" max="3.0"  unit="mm"/>
    <var id="turns"  value="6.0"  min="1.0" max="20.0" unit="1"/>
  </defs>
  <body>
    <!-- Meridional XZ chart for exact ISO 60-degree thread tooth -->
    <chart id="ch_xz">
      <vars>
        <vec3 id="p0" x="0" y="0" z="0" fixed="true"/>
        <vec3 id="e1" x="1" y="0" z="0" fixed="true"/>
        <vec3 id="e2" x="0" y="0" z="1" fixed="true"/>
      </vars>
    </chart>
    <sketch id="sk_tooth" chart="ch_xz">
      <vars>
        <point2d id="t0" u="3.32" v="0.00"/>
        <point2d id="t1" u="4.00" v="0.45"/>
        <point2d id="t2" u="4.00" v="0.60"/>
        <point2d id="t3" u="3.32" v="1.05"/>
      </vars>
      <wire id="w_tooth" closed="true" role="outer">
        <line p0="t0" p1="t1"/><line p0="t1" p1="t2"/>
        <line p0="t2" p1="t3"/><line p0="t3" p1="t0"/>
      </wire>
    </sketch>
    <brep id="b_thread">
      <sweep id="sw_thread" wire="w_tooth" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(pitch) * ref(turns) * v"/>
          <rotate axis="0 0 1" angle-expr="2 * PI * ref(turns) * v"/>
        </trajectory>
      </sweep>
    </brep>
  </body>
  <exports>
    <tessellate target="b_thread" chord-tol="0.02" angle-tol="0.05"/>
    <stl target="b_thread" binary="true"/>
  </exports>
</cdml>
```

Multi-section morphing sweeps and path sweeps follow the same unified `SE(3)` evaluator:

```xml
<!-- Morphing sweep with smooth G1 lead-in/lead-out run-out -->
<sweep id="sw_runout" continuity="G1" cap-ends="true">
  <section v="0.0" wire="w_flat"/>
  <section v="0.1" wire="w_tooth"/>
  <section v="0.9" wire="w_tooth"/>
  <section v="1.0" wire="w_flat"/>
  <trajectory>
    <translate x="0" y="0" z-expr="ref(pitch) * ref(turns) * v"/>
    <rotate axis="0 0 1" angle-expr="2 * PI * ref(turns) * v"/>
  </trajectory>
</sweep>

<!-- 3D path curve sweep with Rotation Minimizing Frame (RMF) or axis-locked frame -->
<curve id="c_helix" param="t" domain="0 1">
  <x>4.0 * cos(2 * PI * 4 * t)</x>
  <y>4.0 * sin(2 * PI * 4 * t)</y>
  <z>2.5 * 4 * t</z>
</curve>
<sweep id="sw_spring" wire="w_wire" path="c_helix" frame="axis-locked" up="0 0 1" cap-ends="true">
  <scale x="1.0" y="1.0" z="1.0"/>
</sweep>
```

### Example C: Implicit TPMS Gyroid Field & Rvachev CSG Bridge

Use `abs_smooth`, `r_union`, and `r_intersect` inside `<implicit>` and combine with B-Rep solids via `<csg>`.

```xml
<implicit id="solid_gyroid">
  <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"
          octree-depth="6" qef-reg="1e-4"/>
  <def name="omega" expr="2 * PI / ref(period)"/>
  <def name="g" expr="sin(omega*x)*cos(omega*y) + sin(omega*y)*cos(omega*z) + sin(omega*z)*cos(omega*x)"/>
  <def name="d_box" expr="r_intersect(abs_smooth(x, 1e-3) - 42, abs_smooth(y, 1e-3) - 42)"/>
  <def name="d_gyroid" expr="abs_smooth(g, 1e-4) - (0.5 * omega * 0.9)"/>
  <field expr="r_intersect(d_box, d_gyroid)"/>
</implicit>
```

---

## 3. HTML Web Embedding (`<iframe>` and `<opencad-viewer>`)

### Option A: `<iframe>` Embed with URL Parameters

Embed the live GitHub Pages studio inside any page or documentation portal:

```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/?embed=true&src=https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/web-app/public/examples/flange_normative.cdml&code=false&params=false"
  width="100%"
  height="500"
  style="border: 1px solid #C8C0B4; border-radius: 6px;"
  loading="lazy"
  title="OpenCAD 3D Viewer">
</iframe>
```

#### URL Query Parameter Reference

| Parameter | Values | Default (Studio / Embed) | Behavior |
| :--- | :--- | :--- | :--- |
| `embed` | `true` / `1` / `false` | `false` / `true` | Full-bleed viewport mode; hides stats bar and defaults code pane off. |
| `src` or `cdml` | URL, relative path, or raw `<cdml...>` XML | Twisted torus | Loads a CDML model from an HTTPS URL, relative path, or inline XML string. |
| `code` or `code-toggle` (`editor`) | `true` / `false` | `true` / `false` | Shows or disables both `#btn-expand-pane` ("Code" dock button) and `#code-pane`. |
| `params` or `gui` | `true` / `false` | `true` / `false` | Shows or disables the `Model Parameters` inspector and `#btn-toggle-gui`. |
| `params-toggle` (`paramsToggle`) | `true` / `false` | `true` | Disables only `#btn-toggle-gui` ("Params" dock button) while preserving initial `gui=true` sliders. |
| `vars` | Comma-separated IDs | All public vars | Filters visible parameter sliders in the panel. |
| `probes` | Comma-separated IDs | All probes | Filters visible physical probe readouts. |
| `exports` | `step,stl` | `step,stl` | Filters export download buttons. |

### Option B: Custom Web Component (`<opencad-viewer>`)

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/web-app/public/examples/flange_normative.cdml"
  data-gui="true"
  data-gui-vars="flange_w,bore_r"
  data-gui-probes="housing_volume"
  data-gui-exports="step,stl"
  width="100%"
  height="520px">
</opencad-viewer>
```

---

## 4. JavaScript & TypeScript (ESM / Browser / Node.js / Bun)

### Installation

- **Browser ESM CDN:** `import { cdml, OpenCadKernel, evalCDML } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';`
- **npm / Bun via GitHub `#dist`:** `npm install github:hassaanmaqsood/opencad#dist`

### Approach 1: 4-Step Declarative `cdml()` Builder

```typescript
import { cdml } from '@open-cad/core';

const doc = cdml('mm', '1e-7', '1e-11')
  // Step 1: Definitions
  .var('L', 100.0, { min: 50, max: 200, unit: 'mm' })
  .var('W', 60.0, { min: 30, max: 120, unit: 'mm' })
  .var('T', 12.0, { min: 4, max: 40, unit: 'mm' })
  .expr('area_nom', 'ref(L) * ref(W)')
  // Step 2: Chart & 2D Constrained Sketch
  .chartXY('c_base')
  .sketch('sk_plate', { chart: 'c_base', maxIter: 100 })
    .rectWire('w_outer', { width: 'ref(L)', height: 'ref(W)', role: 'outer' })
    .circleWire('w_bore', { radius: 10.0, role: 'hole' })
  // Step 3: B-Rep Operations
  .brep('solid_plate', { material: 'al6061' })
    .sweepExtrude('sw_base', { sketch: 'sk_plate', zExpr: 'ref(T) * v', capEnds: true })
  // Step 4: Probes & Exports
  .probe('plate_vol', { type: 'volume', target: 'solid_plate' })
  .exportTessellate('solid_plate', { chordTol: 0.02, angleTol: 0.05 })
  .exportStep('solid_plate', { schema: 'AP214' })
  .exportStl('solid_plate', { binary: true });

const xml = doc.toCDML();
const res = await doc.evaluate();
if (res.status === 0) {
  console.log('Volume (mm^3):', res.probe('plate_vol'));
  const stepText = res.toStep();
  const stlBytes = res.toStl();
} else {
  console.error('CDML diagnostic:', res.diagnostic);
}
```

### Approach 2: Fluent Auto-Disposing `Part` API (`FluentPart`)

```typescript
import { OpenCadKernel } from '@open-cad/core';

const kernel = await OpenCadKernel.create();
try {
  const bracket = kernel.part('Bracket')
    .sketch('XY')
      .rect(80, 50)
      .circle(0, 0, 10, { cut: true })
    .extrude(12)
    .fillet({ select: '>Z', radius: 2.0 });

  const mesh = bracket.tessellate(0.02, 0.05);
  const stepText = bracket.exportStep();
  const stlBytes = bracket.exportStl({ binary: true });
  bracket.dispose();
} finally {
  kernel.deinit();
}
```

### Approach 3: Low-Level `OpenCadKernel` + Three.js `BufferGeometry`

```typescript
import * as THREE from 'three';
import { OpenCadKernel, type CadMesh } from '@open-cad/core';

const kernel = await OpenCadKernel.create('/cad_core.wasm');
try {
  const solidHandle = kernel.createBox(80, 40, 20);
  const mesh: CadMesh = kernel.tessellate(solidHandle, 0.02, 0.05);

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(mesh.positions, 3));
  geometry.setAttribute('normal', new THREE.BufferAttribute(mesh.normals, 3));
  geometry.setIndex(new THREE.BufferAttribute(mesh.indices, 1));
  geometry.computeBoundingBox();

  kernel.releaseSolid(solidHandle);
} finally {
  kernel.deinit();
}
```

### Approach 4: Reading Hybrid Tier-1 / Tier-2 Shared Memory Directly in JS

```typescript
function readTessellationFromSharedMemory(sharedMem: WebAssembly.Memory) {
  const header = new DataView(sharedMem.buffer, 0x0F0000, 128);
  const vertexCount = header.getUint32(0x04, true);
  const triangleCount = header.getUint32(0x08, true);
  if (vertexCount === 0 || triangleCount === 0) return null;

  const posOffset = header.getUint32(0x0C, true); // 0x0F0080 (Tier-1) or >= 0x600000 (Tier-2)
  const nrmOffset = header.getUint32(0x10, true);
  const idxOffset = header.getUint32(0x14, true);
  const isHeapSpillover = header.getUint32(0x50, true) === 1;

  return {
    isHeapSpillover,
    positions: new Float32Array(sharedMem.buffer, posOffset, vertexCount * 3).slice(),
    normals: new Float32Array(sharedMem.buffer, nrmOffset, vertexCount * 3).slice(),
    indices: new Uint32Array(sharedMem.buffer, idxOffset, triangleCount * 3).slice(),
  };
}
```

---

## 5. Python (`wasmtime` Headless SDK)

### Installation

```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git#subdirectory=bindings/python"
# Or install the pre-packaged distribution branch wheel:
pip install "git+https://github.com/hassaanmaqsood/opencad.git@dist#subdirectory=python"
```

### Example 1: 4-Step Parametric Python Builder

```python
import opencad as cad

doc = (cad.cdml(units="mm", linear_tol="1e-7", angular_tol="1e-11")
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
assert res.status == 0, f"Kernel failed: {res.diagnostic}"

print("Volume (mm3):", res.probe("vol"))
with open("part.step", "w", encoding="utf-8") as f:
    f.write(res.to_step())
with open("part.stl", "wb") as f:
    f.write(res.to_stl())
```

### Example 2: Evaluating Raw CDML Files Headlessly

```python
import opencad as cad

with open("examples/lib/0001_hex_bolt_m3x10.cdml", "r", encoding="utf-8") as f:
    xml_source = f.read()

res = cad.eval_cdml(xml_source)
print("Status:", res.status, "Diagnostic:", res.diagnostic)
print("Probes:", res.probes)
```

---

## 6. Rust, C, and Direct WASM C-ABI

### Rust Crate (`bindings/rust`)

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
    println!("STEP length: {}, STL length: {}", step_ap214.len(), stl_binary.len());
}
```

### Native C Header (`abi/cad_kernel.h`)

Key functions exported by `cad_kernel.wasm` / native static library:

| Group | Exported Symbols |
| :--- | :--- |
| **Lifecycle** | `kernel_init()`, `handle_free(u64)`, `cad_kernel_init()`, `cad_kernel_deinit()`, `cad_solid_release(u64)` |
| **CDML Evaluator** | `cdml_register_import(...)`, `cdml_eval_document(ptr, len)`, `cdml_set_var(...)`, `cdml_get_probe_value(...)`, `cdml_get_active_solid()` |
| **Outputs & Diagnostics** | `get_step_ptr()`, `get_step_len()`, `get_stl_ptr()`, `get_stl_len()`, `get_string_ptr()`, `get_string_len()` |
| **Pure-Math Primitives** | `expr_compile`, `expr_eval`, `sys_create`, `sys_alloc_params`, `sys_add_residual`, `sys_solve`, `sys_get_dof`, `sys_read_params`, `curve_define_nurbs`, `wire_assemble`, `solid_kinematic_sweep`, `solid_tensor_loft`, `solid_envelope_fillet`, `solid_offset_shell`, `solid_boolean`, `solid_implicit_field`, `solid_tessellate` |
| **Legacy C-ABI (`abi/cad_kernel.h`)** | `cad_primitive_box`, `cad_primitive_cylinder`, `cad_op_extrude`, `cad_op_boolean`, `cad_solid_tessellate`, `cad_solid_fillet`, `cad_solid_chamfer`, `cad_solid_shell`, `cad_step_import`, `cad_step_export`, `cad_export_stl` |

When instantiating `cad_kernel.wasm` directly in JS/WASI, provide both `env` and `opencad` import objects:

```javascript
const memory = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
const { instance } = await WebAssembly.instantiate(wasmBytes, {
  env: { memory, abort: () => { throw new Error('WASM abort'); } },
  opencad: {
    field_alloc: () => 0,
    field_eval_scalar: (_slot, _x, _y, _z, defVal) => defVal,
    field_eval_vec3: () => {},
    cmd_write: () => {},
  },
});
instance.exports.kernel_init();
```

---

## 7. Troubleshooting & Diagnostic Error Reference

### CDML Kernel Diagnostic Codes (`kernel-zig/src/cdml/types.zig`)

Read JSON error payloads from `get_string_ptr()` / `get_string_len()` whenever `cdml_eval_document` returns a non-zero status:

| Code | Constant | Cause & Fix |
| :--- | :--- | :--- |
| `0x0101` | `ERR_XML_SYNTAX` | Malformed XML tag, unclosed attribute quote, or mismatched closing tag. |
| `0x0102` | `ERR_SCHEMA_VERSION` | Unsupported `<cdml version="...">`. Set `version="1.0"`. |
| `0x0103` | `ERR_DAG_CYCLE` | Circular dependency between `<expr>`, `<var>`, `<probe>`, or `<assert>`. Break the cycle. |
| `0x0104` | `ERR_UNDEFINED_REF` | `ref(name)` or target attribute points to a missing ID. Check spelling or prefix. |
| `0x0105` | `ERR_IMPORT_CONFLICT` | Duplicate imported prefix or ID collision across `<imports>`. Add distinct `prefix="..."`. |
| `0x0106` | `ERR_IMPORT_NOT_FOUND` | Missing `<import src="...">` entry in `cdml_register_import`. Pre-register all imported files. |
| `0x0201` | `ERR_EXPR_DIV_ZERO` | Division by zero during primal or dual-number evaluation. Guard denominators with `max(denom, 1e-9)`. |
| `0x0202` | `ERR_EXPR_NAN_INF` | `NaN` or `Inf` from out-of-domain math (`sqrt(-x)`, `acos(1.1)`, or `norm(0,0)`). See Tip 1 below. |
| `0x0203` | `ERR_ASSERT_VIOLATED` | `<assert expr="..."/>` evaluated `<= 0`. Adjust `<var>` values inside safe engineering margins. |
| `0x0301` | `ERR_SKETCH_CONFLICT` | Over-constrained or conflicting sketch residuals. Remove redundant equations until `dof == 0`. |
| `0x0302` | `ERR_SKETCH_DIVERGED` | Newton-Raphson did not converge within `max-iter`. Improve initial `<point2d u="..." v="..."/>` guesses. |
| `0x0303` | `ERR_WIRE_OPEN_OR_SELF_INT` | Sketch wire is not closed or crosses itself. Verify last segment connects back to the first vertex. |
| `0x0401` | `ERR_SWEEP_SELF_INTERSECT` | Local normal velocity reversed (`R_profile >= R_bend`), profile crossed its rotation axis, or multi-turn helical profile axial height `>= pitch`. Reduce bend curvature, keep meridional profile on one side of axis, or keep tooth axial width `< pitch`. |
| `0x0402` | `ERR_FILLET_RADIUS_COLLAPSE` | Fillet radius consumes an entire adjacent face or edge. Reduce `radius-expr`. |
| `0x0404` | `ERR_EULER_POINCARE` | Non-closed or non-manifold shell failed Euler-Poincaré invariant check. Check solid manifold closure. |
| `0x0405` | `ERR_NON_MANIFOLD_EDGE` | Edge shared by `!= 2` triangles after Boolean/extrude. Eliminate coplanar kissing faces (Tip 2). |
| `0x0501` | `ERR_IMPLICIT_EMPTY_DOMAIN` | Implicit `<field>` never crosses `<= 0` inside `<domain>`. Check domain bounds `xmin..zmax`. |
| `0x0502` | `ERR_IMPLICIT_GRAD_ZERO` | Field has zero gradient (`|\nabla f| == 0`) on the zero isosurface (`abs(f)` instead of `abs_smooth`). |

### Common Practical Fixes

1. **Zero-Length `sqrt` / `norm` Derivative (`0x0202` in Constraints):**
   Forward-mode dual numbers evaluate `d/dx sqrt(x) = 1 / (2 * sqrt(x))`. If two control points start at identical coordinates (`norm(p1 - p0) == 0`), the derivative divides by zero. Smooth norms with `sqrt(dx^2 + dy^2 + 1e-12)` or use distinct initial `<point2d>` seeds.
2. **Coplanar CSG Boolean Faces (`0x0405` / Non-Manifold Edges):**
   Avoid coincident cutter faces. Extend subtractive cutters `0.5 mm` past stock boundaries and overlap additive bosses `>= 0.05 mm` into parent bodies.
3. **Helical Sweep Aliasing & Pitch Clearance on Threads:**
   The kernel automatically chooses adaptive angular `v`-subdivision (`<= pi/12` = `24` segments per revolution) and evaluates self-intersection in the co-moving body frame (`|C'(u) x (Omega_body x C(u) + V_body)|`), plus a global axial clearance check (`delta_z_profile < pitch`) for multi-turn sweeps (`|delta_theta| > 2*PI`). Ensure meridional tooth axial height stays strictly below `pitch` (`<= 0.85 * pitch` for ISO 60-degree crests). Note that standalone `cad_op_thread` in `c_abi.zig` is currently a stub (`CAD_STATUS_ERROR_NOT_IMPLEMENTED`); model threads in CDML with `<sweep>`.
4. **Browser `SharedArrayBuffer` / Worker Startup Errors:**
   Static hosts without COOP/COEP headers (`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`) block `SharedArrayBuffer`. Ensure `coi-serviceworker.js` is served from the same origin or configure your HTTP server to send both isolation headers.
5. **Truncated Meshes Above `21,842` Triangles (`> 1 MiB`):**
   Do not read vertices from a hardcoded `0x0F0080` offset. Read `pos_offset` (`0x0F000C`), `nrm_offset` (`0x0F0010`), `idx_offset` (`0x0F0014`), and `is_heap_spillover` (`0x0F0050`) from the `0x0F0000` header so Tier-2 heap spillover meshes (`>= 0x600000`) load intact.
