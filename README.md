# OpenCAD (`open-parametric-cad` v2.0)

> **Pure-Math Computational CAD Kernel, CDML v1.0 Compiler, Responsive Flex Studio & Minimal Embed Viewer.**  
> Powered by Zig (`wasm32-freestanding`), SharedArrayBuffer Zero-Copy Memory, TypeScript, Python (`wasmtime`) & Three.js.

[![Live Studio](https://img.shields.io/badge/Live_Studio-hassaanmaqsood.github.io%2Fopencad-blue?style=for-the-badge&logo=googlechrome)](https://hassaanmaqsood.github.io/opencad/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig Tests](https://img.shields.io/badge/Zig_Unit_Tests-198%2F198_Passed-brightgreen.svg)](./kernel-zig)
[![Verification Gates](https://img.shields.io/badge/Anti--Cheat_Gates-All_9_Passed-success.svg)](./scripts/verify_gates.sh)

---

## 🏛️ Architectural Highlights (v2.0)

1. **Zero-Primitive Pure-Math Kernel (`cad_kernel.wasm`):**
   - No hardcoded `box`, `cylinder`, or `sphere` primitives. All geometry is synthesized through **18 canonical pure-math C-ABI functions**: forward-mode Automatic Differentiation (`autodiff.zig`), Householder QR nonlinear constraint solving (`constraint_sys.zig`), rational NURBS curves & wires (`curve_wire.zig`), $SE(3)$ kinematic sweeps, bivariate tensor-product NURBS lofts, rolling-ball fillets, non-destructive offset shells, analytic inequality regions (`surface_brep.zig`), and interval-pruned octree QEF Dual Contouring (`implicit_field.zig`).
2. **CDML v1.0 (Computational Design Markup Language):**
   - Declarative XML engineering format combining `<imports>`, parametric `<defs>` (`<var>`, `<expr>`, `<field-slot>`, `<assert>`), orthonormal `<chart>` frames, constrained `<sketch>` profiles, `<region>` half-spaces, `<brep>` sweeps/fillets, `<implicit>` TPMS lattices, straddling-triangle `<csg>` booleans, physical `<probe>` queries, and `<exports>` (`<tessellate>`, `<step>`, `<stl>`).
3. **Single `SharedArrayBuffer` Zero-Copy Memory (`0x000000`–`0x5F0000`):**
   - Unified linear memory layout connecting `cad_kernel.wasm`, secondary physics/field WASM extensions (`ext_field_canary.wasm` writing 3D stress voxels at `0x1F0000`), and the Three.js WebGL viewport (`0x0F0000` tessellation buffer with 192-bit SHA-256 `TopoId`s).
4. **Responsive Flex Studio & Minimal Zero-GUI Embed Viewer:**
   - Desktop horizontal (`flex-direction: row`) and mobile vertical (`flex-direction: column`) split studio with fault-tolerant live CDML editing (retaining the last valid 3D mesh when assertions or syntax fail).
   - Embeddable via URL parameters (`?embed=true&cdml=...&gui=true&vars=...&probes=...&exports=...`) or the `<opencad-viewer>` Custom Element.

---

## ⚡ Quick Usage Examples

### 1. Declarative `<opencad-viewer>` Web Component & URL Embed
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<!-- Minimal Zero-GUI 3D Embed -->
<opencad-viewer
  src="/examples/flange_normative.cdml"
  data-gui="false">
</opencad-viewer>

<!-- Filtered Interactive Parameters, Probes & Exports -->
<opencad-viewer
  src="/examples/flange_normative.cdml"
  data-gui="true"
  data-gui-vars="flange_w,bore_r,fillet_r"
  data-gui-probes="housing_volume,max_fillet_stress"
  data-gui-exports="step,stl">
</opencad-viewer>
```

### 2. 4-Step Fluent CDML Surface SDK (Python & TypeScript)

#### Python (`bindings/python/opencad`)
```python
import opencad as cad

doc = (cad.cdml(units="mm")
    .var("W", 80.0, min=40.0, max=120.0)
    .var("H", 20.0)
    .var("R", 10.0)
    .chart_xy("c_xy")
    .sketch("sk1", chart="c_xy")
        .rect_wire("w_out", width="ref(W)", height="50.0", role="outer")
        .circle_wire("w_hole", radius="ref(R)", role="hole")
    .brep("b1")
        .sweep_extrude("sw1", sketch="sk1", z_expr="ref(H) * v")
    .probe("vol", type="volume", target="b1")
    .export_tessellate("b1")
    .export_step("b1")
    .export_stl("b1", binary=True))

res = doc.evaluate()
assert res.status == 0
print("Enclosed Volume (mm³):", res.probe("vol"))
step_str = res.to_step()
stl_bytes = res.to_stl()
```

#### TypeScript (`packages/core-sdk`)
```typescript
import { cdml } from '@open-cad/core-sdk';

const doc = cdml({ units: 'mm' })
  .var('W', 80.0, { min: 40.0, max: 120.0 })
  .var('H', 20.0)
  .var('R', 10.0)
  .chartXY('c_xy')
  .sketch('sk1', 'c_xy')
    .rectWire('w_out', 'ref(W)', '50.0', 'outer')
    .circleWire('w_hole', 'ref(R)', 'hole')
  .brep('b1')
    .sweepExtrude('sw1', 'sk1', 'ref(H) * v')
  .probe('vol', 'volume', 'b1')
  .exportTessellate('b1')
  .exportStep('b1')
  .exportStl('b1', true);

const xml = doc.toCDML();
```

---

## 🔬 Build & Verification Pipeline

### 1. Build Native Zig Kernel, Run 198 Unit Tests & Compile WASM
```bash
cd kernel-zig
zig build test                        # Runs 39 test steps (198 tests) with zero-leak checks
zig build -Doptimize=ReleaseSmall     # Compiles stripped cad_kernel.wasm
```

### 2. Run All 9 Anti-Cheat & E2E Verification Gates
```bash
./scripts/verify_gates.sh all
```
This executes:
- **Gate 0 & Gate 0B:** Enforces the Zero-Primitive Law and scans `kernel-zig/src/` for any hardcoded variable/model names.
- **Gate 1:** Verifies zero client-side JS/Three.js fallback geometry generators.
- **Gate 2:** Compiles the Zig mathematical kernel and runs all 198 native unit tests.
- **Gate 3:** Runs `scripts/test_wasm_blackbox.mjs` against the 18-function pure-math WASM ABI.
- **Gate 3B:** Runs `scripts/test_cdml_compiler.mjs` (CDML §14 normative housing, fault-tolerant assertions, deterministic error codes, and randomized Acid Tests A & B).
- **Gate 4:** Runs `scripts/test_canary_extension.mjs` verifying zero-copy 3D stress field modulation across `SharedArrayBuffer` (`0x1F0000`).
- **Gate 5:** Verifies the Python 4-step CDML builder and `wasmtime` evaluator.
- **Gate 6:** Runs the 6 Playwright Chromium E2E tests (`web-app/tests/studio_and_embed.spec.ts`).

---

## 📚 Documentation

- [**ARCHITECTURE.md**](./ARCHITECTURE.md) — Shared memory layout (`0x000000`–`0x5F0000`), 18-function C-ABI, AD/Interval VM, Householder QR solver, straddling-triangle CSG, and Dual Contouring internals.
- [**CDML v1.0 Specification**](./docs/CDML%20v1.0%20%E2%80%94%20Computational%20Design%20Markup%20Language%20Format%20Specification.md) — Complete normative specification of the Computational Design Markup Language.
- [**.antigravity/CHARTER.md**](./.antigravity/CHARTER.md) — Architectural charter and engineering tenets.
