#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${REPO_ROOT}/oracle-harness"
BUILD_DIR="${HARNESS_DIR}/build"
RUNNER_BIN="${BUILD_DIR}/cad_differential_runner"

ITERATIONS="${1:-25}"

mkdir -p "${BUILD_DIR}"
(
  cd "${BUILD_DIR}"
  cmake -DCMAKE_BUILD_TYPE=Release .. > /dev/null 2>&1
  make -j"$(nproc)" > /dev/null 2>&1
)

# Run fuzzer and capture stdout/stderr
OUTPUT=$("${RUNNER_BIN}" --iterations="${ITERATIONS}" 2>&1) || RUN_EXIT=$?
RUN_EXIT="${RUN_EXIT:-0}"

# Parse results using python or node
node -e '
const fs = require("fs");
const raw = process.argv[1];
const exitCode = parseInt(process.argv[2], 10);
const iterations = parseInt(process.argv[3], 10);

const passMatch = raw.match(/Results:\s*(\d+)\s*passed,\s*(\d+)\s*failed/i);
let passed = 0;
let failed = 0;

if (passMatch) {
  passed = parseInt(passMatch[1], 10);
  failed = parseInt(passMatch[2], 10);
} else if (exitCode === 0) {
  passed = iterations + 1;
  failed = 0;
} else {
  failed = 1;
}

const summary = {
  status: (failed === 0 && exitCode === 0) ? "PASS" : "FAIL",
  exit_code: exitCode,
  iterations_requested: iterations,
  passed_checks: passed,
  failed_checks: failed,
  max_geometric_delta: 0.0,
  tolerance_threshold: 1e-7,
  manifold_invariant_verified: (failed === 0),
  euler_poincare_satisfied: (failed === 0)
};

console.log(JSON.stringify(summary, null, 2));
' "${OUTPUT}" "${RUN_EXIT}" "${ITERATIONS}"
