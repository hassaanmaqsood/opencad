#!/usr/bin/env bash
set -euo pipefail

PHASE="${1:-all}"
echo "=== Running OpenCAD Anti-Cheat Verification Gates (Mode: $PHASE) ==="

echo "=== [GATE 0] Enforcing Zero-Primitive Mathematical Kernel Law ==="
if rg -n "pub export fn .*(box|cylinder|sphere|rect|circle|tpms|gyroid|wp_xy|wp_yz|wp_xz|extrude|revolve)" kernel-zig/src/ 2>/dev/null; then
  echo "FAIL [GATE 0]: Primitive or special-case geometric export detected in kernel-zig/src/!"
  echo "The kernel may ONLY export pure mathematical equation, constraint, NURBS, SE(3) sweep, and field operators."
  exit 1
fi

if find kernel-zig/src -name "router.zig" | grep -q .; then
  echo "FAIL [GATE 0]: Banned C++ fallback router.zig still exists in kernel-zig/src/!"
  exit 1
fi

echo "=== [GATE 0B] Anti-Hardcoding & Cheat-Signature Scan in Kernel ==="
if rg -n '"(flange_w|flange_h|bore_r|wall_margin|fillet_r|mean_bore_stress|max_fillet_stress|housing_volume|solid_flange|solid_gyroid|solid_mask|solid_final|c_bore|sk_flange|W|H|R)"' kernel-zig/src/ 2>/dev/null; then
  echo "FAIL [GATE 0B]: Hardcoded test variable or element ID string literal detected in kernel-zig/src/!"
  echo "The kernel must evaluate arbitrary user-defined XML IDs generically."
  exit 1
fi

if rg -n "12500\.0|4096\s*\+\s*32|node\.left\s*//|stack\[sp\]\s*=\s*40\.0" kernel-zig/src/ 2>/dev/null; then
  echo "FAIL [GATE 0B]: Detected hardcoded probe formula or stubbed FieldSample/CSG in kernel-zig/src/!"
  exit 1
fi

if rg -n 'subprocess\.run.*node|_eval_runner\.mjs' bindings/python/ 2>/dev/null; then
  echo "FAIL [GATE 0B]: Python binding is shelling out to Node.js instead of running native Python wasmtime!"
  exit 1
fi

echo "=== [GATE 1] Checking for Banned JS Geometry Generators & Fallbacks ==="
if find web-app packages -name "dag_evaluator.ts" -o -name "geometry_generator.ts" 2>/dev/null | grep -q .; then
  echo "FAIL [GATE 1]: Banned JS geometry generator files (dag_evaluator.ts / geometry_generator.ts) still exist!"
  exit 1
fi

if rg -n "BoxGeometry|CylinderGeometry|SphereGeometry|ExtrudeGeometry|TorusGeometry|generateBoxBuffers|wasmBuffers\s*\?\?" web-app/src/ packages/ 2>/dev/null; then
  echo "FAIL [GATE 1]: Detected Three.js primitive geometry synthesis or silent WASM fallback in TypeScript!"
  exit 1
fi

echo "=== [GATE 2] Compiling Zig Mathematical Kernel & Native Unit Tests ==="
cd kernel-zig
zig build test
zig build -Doptimize=ReleaseFast
cd ..

if [ "$PHASE" = "phase1" ]; then
  echo "=== PHASE 1 GATES PASSED (Zero-Primitive Auto-Diff & Constraint Solver Verified) ==="
  exit 0
fi

echo "=== [GATE 3] Black-Box Pure-Math WASM Verification (Zero Frontend) ==="
node scripts/test_wasm_blackbox.mjs

if [ "$PHASE" = "phase2" ]; then
  echo "=== PHASE 2 GATES PASSED (Pure-Math WASM Kernel & Shared Memory Verified) ==="
  exit 0
fi

echo "=== [GATE 4] Checking Single SharedArrayBuffer Memory Architecture ==="
MEM_COUNT=$(rg -c "new WebAssembly\.Memory" web-app/src/ packages/ 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$MEM_COUNT" -ne 1 ]; then
  echo "FAIL [GATE 4]: Found $MEM_COUNT WebAssembly.Memory allocations across web-app/ and packages/ (Expected EXACTLY 1 shared memory instance)!"
  exit 1
fi

# --- Replace everything after the phase2 exit block in scripts/verify_gates.sh with: ---

echo "=== [GATE 3B] CDML v1.0 Compiler, Fault Tolerance & §14 Normative Document Check ==="
node scripts/test_cdml_compiler.mjs

if [ "$PHASE" = "phase3" ]; then
  echo "=== PHASE 3 GATES PASSED (Fault-Tolerant CDML v1.0 Kernel Compiler Verified) ==="
  exit 0
fi

echo "=== [GATE 4] Checking Single SharedArrayBuffer & Zero-Copy Extension Canary ==="
MEM_COUNT=$(rg -c "new WebAssembly\.Memory" web-app/src/ packages/ 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
if [ "$MEM_COUNT" -ne 1 ]; then
  echo "FAIL [GATE 4]: Found $MEM_COUNT WebAssembly.Memory allocations across web-app/ and packages/ (Expected EXACTLY 1 shared memory instance)!"
  exit 1
fi

if ! rg -q "shared:\s*true" web-app/src/ packages/ 2>/dev/null; then
  echo "FAIL [GATE 4]: WebAssembly.Memory is not configured with { shared: true }!"
  exit 1
fi

node scripts/test_canary_extension.mjs

echo "=== [GATE 5] CDML-Backed 4-Step Surface API (TS & Python) Verification ==="
python3 -c "
import sys; sys.path.insert(0, 'bindings/python')
import opencad as cad
doc = (cad.cdml(units='mm')
  .var('W', 80.0, min=40.0, max=120.0)
  .var('H', 20.0)
  .var('R', 10.0)
  .chart_xy('c_xy')
  .sketch('sk1', chart='c_xy')
    .rect_wire('w_out', width='ref(W)', height='50.0', role='outer')
    .circle_wire('w_hole', radius='ref(R)', role='hole')
  .brep('b1')
    .sweep_extrude('sw1', sketch='sk1', z_expr='ref(H) * v')
  .probe('vol', type='volume', target='b1')
  .export_tessellate('b1')
  .export_step('b1')
  .export_stl('b1', binary=True))

xml_str = doc.to_cdml()
assert '<cdml version=\"1.0\"' in xml_str and '<chart id=\"c_xy\">' in xml_str, 'Invalid CDML emission'
res = doc.evaluate()
assert res.status == 0, f'CDML eval failed: {res.diagnostic}'
assert res.probe('vol') > 60000.0, f'Unexpected volume: {res.probe(\"vol\")}'
assert len(res.to_stl()) > 84 and 'MANIFOLD_SOLID_BREP' in res.to_step()
print('Python 4-step CDML builder & evaluation PASSED. Volume:', res.probe('vol'))
"

if [ "$PHASE" = "phase4" ]; then
  echo "=== PHASE 4 GATES PASSED (CDML Surface SDK & Canary Shared-Memory Extension Verified) ==="
  exit 0
fi

echo "=== [GATE 6] Responsive Flex Studio & Minimal URL/Data-Attr Embed E2E Check ==="
cd web-app && npx playwright test && cd ..

echo "=== ALL OPEN-CAD & CDML v1.0 GATES PASSED ==="
