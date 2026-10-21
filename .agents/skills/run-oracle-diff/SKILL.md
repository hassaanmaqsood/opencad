---
name: run-oracle-diff
description: Executes the C++ differential test runner in oracle-harness/ to validate that geometric error against OpenCASCADE/PlaneGCS is <= 1e-7 mm and Euler-Poincaré invariants hold.
---

# Skill: run-oracle-diff

## Overview
This skill executes the differential testing harness comparing candidate Zig geometry, topology, and constraint solver implementations against the reference C++ OpenCASCADE and PlaneGCS oracles. It enforces the mandatory **Rule 2 (Differential Oracle Gate)** before any CAD operation can be enabled in `router.zig`.

## When to Use
- Whenever new CAD operations, primitives, booleans, or solver routines are implemented or modified.
- Prior to flipping a backend flag in `kernel-zig/src/router.zig` from `COracle` to `NativeZig`.
- As a prerequisite gate before finalizing any wave handoff.

## Procedure
Execute the verification script from the project root:

```bash
bash .agents/skills/run-oracle-diff/scripts/verify.sh
```

Alternatively, use the MCP wrapper tool:
```bash
bash scripts/mcp/oracle_fuzzer.sh 50
```

## Acceptance Criteria
- 100% of differential test cases pass.
- Maximum geometric deviation across solids and tessellated buffers is $\le 1 \times 10^{-7}\text{ mm}$.
- Euler-Poincaré invariant satisfies $V - E + F - (L - F) - 2(S - G) = 0$.
- PlaneGCS 2D constraint solver converges within tolerance ($< 10^{-6}$).
