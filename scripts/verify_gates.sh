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

if ! rg -q "shared:\s*true" web-app/src/ packages/ 2>/dev/null; then
  echo "FAIL [GATE 4]: WebAssembly.Memory is not configured with { shared: true }!"
  exit 1
fi

if rg -n "window\.cad\.getStressField" web-app/src/ packages/ 2>/dev/null; then
  echo "FAIL [GATE 4]: Banned global JS heap bus window.cad.getStressField found!"
  exit 1
fi

echo "=== [GATE 5] Surface Wrapper & Python Handle Verification ==="
python3 -c "
import sys; sys.path.insert(0, 'bindings/python')
import opencad as cad
p1 = cad.workplane('XY').sketch().rect(80, 50).circle(10, at=(20, 0)).extrude(20)
p2 = cad.workplane('XY').sketch().rect(120, 50).extrude(10)
assert p1._handle != 1 and p2._handle != 1 and p1._handle != p2._handle, f'Fake handles: {p1._handle}, {p2._handle}'
assert (p1._handle >> 62) in (0, 1), f'Invalid solid_t representation tag bits: {hex(p1._handle)}'
step_str = p1.to_step()
assert 'MANIFOLD_SOLID_BREP' in step_str and '80.' in step_str, 'Invalid STEP output'
stl_bytes = p1.to_stl(binary=True)
assert len(stl_bytes) > 84, 'Invalid binary STL output'
print('Python surface-wrapper-to-math-kernel check PASSED. Handles:', hex(p1._handle), hex(p2._handle))
"

echo "=== ALL SMART-PROOF & FOOL-PROOF GATES PASSED ==="
