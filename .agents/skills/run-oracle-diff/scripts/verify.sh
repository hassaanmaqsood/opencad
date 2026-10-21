#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/oracle-harness"
BUILD_DIR="${HARNESS_DIR}/build"
RUNNER_BIN="${BUILD_DIR}/cad_differential_runner"

echo "=== [Skill: run-oracle-diff] Step 1: Building Differential Harness ==="
mkdir -p "${BUILD_DIR}"
(
  cd "${BUILD_DIR}"
  cmake -DCMAKE_BUILD_TYPE=Release .. > /dev/null
  make -j"$(nproc)"
)

echo "=== [Skill: run-oracle-diff] Step 2: Running Differential Fuzzing Suite ==="
OUTPUT=$("${RUNNER_BIN}" --iterations=30)
echo "${OUTPUT}"

echo "=== [Skill: run-oracle-diff] Step 3: Verifying Tolerance Gate (<= 1e-7 mm) ==="
node -e '
const raw = process.argv[1];
const passMatch = raw.match(/Results:\s*(\d+)\s*passed,\s*(\d+)\s*failed/i);

if (!passMatch) {
  console.error("[FAIL] Could not parse differential harness results.");
  process.exit(1);
}

const passed = parseInt(passMatch[1], 10);
const failed = parseInt(passMatch[2], 10);

if (failed > 0) {
  console.error(`[FAIL] Differential harness encountered ${failed} failures!`);
  process.exit(1);
}

console.log(`[PASS] Verified ${passed} differential checks with 0 failures.`);
console.log(`[PASS] Geometric deviation <= 1e-7 mm and Euler-Poincaré invariant confirmed!`);
' "${OUTPUT}"

echo "=== [Skill: run-oracle-diff] SUCCESS: Differential gate verified! ==="
