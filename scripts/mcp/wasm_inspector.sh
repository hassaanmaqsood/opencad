#!/usr/bin/env bash
set -euo pipefail

# Find repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KERNEL_DIR="${REPO_ROOT}/kernel-zig"
WASM_BIN="${KERNEL_DIR}/zig-out/bin/cad_kernel.wasm"

echo "[wasm-inspector] Compiling WebAssembly kernel..." >&2
(cd "${KERNEL_DIR}" && zig build) >&2

if [[ ! -f "${WASM_BIN}" ]]; then
    echo "{\"error\": \"WASM binary not found at ${WASM_BIN}\"}"
    exit 1
fi

FILE_SIZE_BYTES=$(stat -c%s "${WASM_BIN}" 2>/dev/null || stat -f%z "${WASM_BIN}")
FILE_SIZE_HUMAN=$(numfmt --to=iec-i --suffix=B "${FILE_SIZE_BYTES}" 2>/dev/null || echo "${FILE_SIZE_BYTES} bytes")

# Extract exported symbols using node WebAssembly parser
EXPORTS_JSON=$(node -e '
const fs = require("fs");
const wasmPath = process.argv[1];
try {
  const buf = fs.readFileSync(wasmPath);
  WebAssembly.compile(buf).then(mod => {
    const exports = WebAssembly.Module.exports(mod);
    const names = exports.map(e => ({ name: e.name, kind: e.kind }));
    console.log(JSON.stringify(names));
  }).catch(err => {
    console.error(err);
    process.exit(1);
  });
} catch (e) {
  console.error(e);
  process.exit(1);
}
' "${WASM_BIN}")

node -e '
const sizeBytes = parseInt(process.argv[1], 10);
const sizeHuman = process.argv[2];
const wasmPath = process.argv[3];
const exports = JSON.parse(process.argv[4]);

const result = {
  status: "OK",
  artifact: wasmPath,
  size_bytes: sizeBytes,
  size_formatted: sizeHuman,
  export_count: exports.length,
  exports: exports
};

console.log(JSON.stringify(result, null, 2));
' "${FILE_SIZE_BYTES}" "${FILE_SIZE_HUMAN}" "${WASM_BIN}" "${EXPORTS_JSON}"
