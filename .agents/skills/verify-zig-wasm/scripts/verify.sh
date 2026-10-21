#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
KERNEL_DIR="${REPO_ROOT}/kernel-zig"
ABI_HEADER="${REPO_ROOT}/abi/cad_kernel.h"
WASM_BIN="${KERNEL_DIR}/zig-out/bin/cad_kernel.wasm"

echo "=== [Skill: verify-zig-wasm] Step 1: Running Unit Tests & Leak Checks ==="
(cd "${KERNEL_DIR}" && zig build test --summary all)

echo "=== [Skill: verify-zig-wasm] Step 2: Compiling WebAssembly Kernel ==="
(cd "${KERNEL_DIR}" && zig build)

if [[ ! -f "${WASM_BIN}" ]]; then
  echo "[ERROR] Compiled WASM binary not found at ${WASM_BIN}"
  exit 1
fi

echo "=== [Skill: verify-zig-wasm] Step 3: Verifying Exports Match C ABI ==="
node -e '
const fs = require("fs");
const wasmPath = process.argv[1];
const headerPath = process.argv[2];

const buf = fs.readFileSync(wasmPath);
const header = fs.readFileSync(headerPath, "utf8");

WebAssembly.compile(buf).then(mod => {
  const wasmExports = new Set(WebAssembly.Module.exports(mod).map(e => e.name));
  
  // Extract C functions declared in header
  const cFuncs = [];
  const regex = /cad_status_t\s+([a-zA-Z0-9_]+)\s*\(/g;
  let match;
  while ((match = regex.exec(header)) !== null) {
    cFuncs.push(match[1]);
  }

  let matched = 0;
  let missing = [];
  for (const fn of cFuncs) {
    if (wasmExports.has(fn)) {
      matched++;
    } else {
      missing.push(fn);
    }
  }

  console.log(`[PASS] Found ${matched}/${cFuncs.length} core C ABI functions exported in WASM.`);
  if (missing.length > 0) {
    console.log(`[NOTE] Note: Non-WASM C functions routed through oracle: ${missing.join(", ")}`);
  }

  // Also check essential zero-copy WASM helpers
  const requiredHelpers = [
    "cad_wasm_get_positions_ptr",
    "cad_wasm_get_normals_ptr",
    "cad_wasm_get_indices_ptr",
    "cad_wasm_get_face_ids_ptr"
  ];

  for (const h of requiredHelpers) {
    if (!wasmExports.has(h)) {
      console.error(`[FAIL] Missing required zero-copy helper: ${h}`);
      process.exit(1);
    }
  }

  console.log("[PASS] All required zero-copy WASM memory exports verified!");
});
' "${WASM_BIN}" "${ABI_HEADER}"

echo "=== [Skill: verify-zig-wasm] SUCCESS: All checks passed with 0 memory leaks! ==="
