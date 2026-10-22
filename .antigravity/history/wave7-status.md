# Wave 7 Status Report: Sheet Metal, 2D GD&T Drawings, & Production CAM/3MF

**Date:** 2026-10-22  
**Status:** COMPLETED & VERIFIED  
**Collaborating Agents:** `@cad-architect`, `@zig-fea-flexure`, `@zig-cam-hlr`, `@threejs-ui-worker`, `@oracle-fuzzer-qa`

---

## 1. Executive Summary

Wave 7 introduces production manufacturing capabilities to OpenCAD:
1. **Sheet Metal Workbench (`kernel-zig/src/sheetmetal/`, `web-app/src/plugins/sheetmetal/`)**:
   - Exact DIN 6935 neutral axis bend allowance formula: $BA = \theta \cdot (R + K \cdot T)$.
   - Outside Setback ($OSSB = \tan(\theta/2) \cdot (R + T)$) and Bend Deduction ($BD = 2 \cdot OSSB - BA$).
   - Base tab, edge flange with automatic 45° corner miter trimming, hems (`closed`, `open`, `teardrop`, `rolled`), and corner reliefs (`tear`, `obround`, `rectangular`).
   - Unfolded 2D flat-pattern blank computation with bend centerline annotations (UP/DOWN, angle, radius, BA), perimeter cut length, and total blank surface area.
2. **2D GD&T Engineering Drawings Workbench (`kernel-zig/src/cam_hlr/`, `web-app/src/plugins/drawing/`)**:
   - Hidden-Line Removal (HLR) projection supporting Front, Top, Right, Isometric, and Section $A-A$ views.
   - ANSI31 45° cross-hatching for section cuts.
   - Vector exporters for AutoCAD DXF (R12/AC1009 group codes with `VISIBLE`, `HIDDEN`, `CENTERLINE`, `HATCH` layers) and W3C SVG with ISO 128 / ASME Y14.5 title blocks and borders.
   - Interactive GD&T feature control frames (Flatness, Position, Perpendicularity) and linear/radial dimensioning.
3. **Additive & Subtractive CAM Workbench (`kernel-zig/src/cam_hlr/`, `web-app/src/plugins/cam-hlr/`)**:
   - 2.5D contouring with cutter radius compensation offset $R_{\text{tool}} + \text{stock}$, stepdown passes, and non-gouging invariant preservation.
   - Concentric pocketing, adaptive trochoidal clearing, and G83 peck drilling cycles.
   - Standard ISO RS-274 G-code post-processing.
   - Multi-body 3MF Production packaging conforming to 3MF Core XML specification.
   - 2D build-plate (FDM/CNC) and 3D sinter-box (SLS) bin packing optimizer with density percentage tracking.

---

## 2. Directory Locks & Files Modified

| Component | Scope | Primary Files |
| :--- | :--- | :--- |
| **C ABI Specification** | `@cad-architect` | `abi/cad_kernel.h`, `kernel-zig/src/c_abi.zig` |
| **Sheet Metal Kernel** | `@zig-fea-flexure` | `kernel-zig/src/sheetmetal/kfactor.zig`<br>`kernel-zig/src/sheetmetal/flange.zig`<br>`kernel-zig/src/sheetmetal/unfold.zig`<br>`kernel-zig/src/sheetmetal/wasm.zig`<br>`kernel-zig/src/sheetmetal/c_types.zig`<br>`kernel-zig/src/sheetmetal/mod.zig` |
| **CAM, 2D HLR & Nesting** | `@zig-cam-hlr` | `kernel-zig/src/cam_hlr/hlr.zig`<br>`kernel-zig/src/cam_hlr/section.zig`<br>`kernel-zig/src/cam_hlr/dxf.zig`<br>`kernel-zig/src/cam_hlr/svg.zig`<br>`kernel-zig/src/cam_hlr/threemf.zig`<br>`kernel-zig/src/cam_hlr/nest.zig`<br>`kernel-zig/src/cam_hlr/cnc_cam.zig`<br>`kernel-zig/src/cam_hlr/wasm.zig`<br>`kernel-zig/src/cam_hlr/c_types.zig`<br>`kernel-zig/src/cam_hlr/mod.zig` |
| **Web Shell & Workbenches** | `@threejs-ui-worker` | `web-app/src/main.ts`<br>`web-app/src/core-shell/TopRibbon.ts`<br>`web-app/src/worker/cad.worker.ts`<br>`web-app/src/plugins/sheetmetal/index.ts`<br>`web-app/src/plugins/drawing/index.ts`<br>`web-app/src/plugins/cam-hlr/index.ts`<br>`web-app/public/cad_sheetmetal.wasm`<br>`web-app/public/cad_mfg_cam.wasm` |
| **QA Verification Suites** | `@oracle-fuzzer-qa` | `kernel-zig/tests/test_wave7_manufacturing.zig`<br>`web-app/tests/wave7_manufacturing.spec.ts` |

---

## 3. Verification Commands & Observed Metrics

### 1. Zig Kernel Unit & Fuzz Verification (`verify-zig-wasm`)
```bash
cd kernel-zig && zig build test
# Result: 13/13 test suites passed, 0 failures, exit code 0
# Memory Leaks: 0 bytes leaked under std.testing.allocator
```

### 2. Standalone Kernel SDK Verification (`packages/kernel-sdk`)
```bash
npm run test:sdk
# Result: 6/6 tests passed, exit code 0
# Duration: ~160 ms
```

### 3. WASM Compilation & Artifact Footprints
```bash
cd kernel-zig && zig build
# Outputs verified in web-app/public/:
# - cad_sheetmetal.wasm: 860 KiB
# - cad_mfg_cam.wasm:    1.1 MiB
```

### 4. Playwright End-to-End Test Suite (`verify-web-viewport`)
```bash
cd web-app && npx playwright test
# Result: 27/27 tests passed, exit code 0
# Viewport throughput: 60 FPS verified across all workbenches and timeline scrubbing
```

### 5. Numerical Accuracy & Manufacturing Invariants
- **DIN 6935 Bend Allowance Delta:** $\Delta \le 10^{-9}\text{ mm}$ against analytical arc length.
- **Outside Setback & Deduction:** Exact match across 90° bends and 180° hem profiles.
- **CNC Toolpath Boundary Invariant:** Cutter radius compensation strictly offsets toolpath centerlines by $R_{\text{tool}} + \text{stock}$, asserting non-gouging boundary condition.
- **Vector Drawing Validity:** AutoCAD DXF R12 structure syntax and W3C SVG XML conformance confirmed.
- **3MF Production Packaging:** 3MF Core XML geometry specification validated.
- **Web App Bundle Size:** Main chunk is 604 kB; total initial bundle < 1.1 MB (well under 2.0 MiB ceiling).
