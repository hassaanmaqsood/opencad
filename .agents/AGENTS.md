# Multi-Agent Coordination, File-Lock Manifest & Routing Rules

This document establishes the concurrency protocols, exclusive directory write locks, and handoff procedures governing parallel `gemini-3.8-flash` agents collaborating on `open-parametric-cad`.

---

## 1. Directory Write Locks & Mutual Exclusion Matrix

To prevent merge conflicts, data corruption, and race conditions during parallel agent execution, every file and directory has a single designated owner. **No agent may write, edit, or delete files outside its assigned write scope.**

| Agent ID | Thinking Level | Exclusive Write Scope | Description & Primary Responsibilities |
| :--- | :--- | :--- | :--- |
| **`cad-architect`** | `high` | `abi/cad_kernel.h`<br>`.antigravity/`<br>`package.json`<br>`README.md` | Single source of truth for C ABI layout, system architecture, mission playbooks, and cross-boundary interface review. |
| **`zig-solver-math`** | `high` | `kernel-zig/src/solver/`<br>`kernel-zig/src/geom/`<br>`kernel-zig/src/math/` | Native 2D/3D geometric constraint solver (sparse Jacobian, Newton-Raphson, QR DOF analysis), Shewchuk adaptive predicates, and SIMD NURBS evaluators. |
| **`zig-brep-topo`** | `high` | `kernel-zig/src/topo/`<br>`kernel-zig/src/ops/`<br>`kernel-zig/src/brep/`<br>`kernel-zig/src/primitives/`<br>`kernel-zig/src/router.zig` | SoA Half-Edge B-Rep topology store, Parametric Feature Tree DAG, Persistent Topological Naming resolver, and Strangler-Fig operation router. |
| **`zig-tess-wasm`** | `medium` | `kernel-zig/src/tessellation/`<br>`kernel-zig/src/tess/`<br>`kernel-zig/src/main.zig`<br>`kernel-zig/build.zig`<br>`web-app/public/cad_kernel.wasm` | Adaptive B-Rep surface triangulation, zero-copy flat memory slice WASM exports, and WASM binary footprint optimization. |
| **`oracle-fuzzer-qa`** | `medium` | `oracle-harness/`<br>`kernel-zig/tests/`<br>`scripts/mcp/oracle_fuzzer.sh` | Continuous differential fuzzing against OpenCASCADE & PlaneGCS, invariant checking ($V - E + F - (L - F) - 2(S - G) = 0$), and counterexample minimization. |
| **`threejs-ui-worker`** | `medium` | `web-app/` *(excluding public wasm binary)* | Three.js WebGL/WebGPU CAD viewport, sub-shape face/edge picking via `triangle_to_face_id`, Feature Tree UI, Rollback Bar, and Playwright 60-FPS tests. |

---

## 2. Shared File Coordination & Conflict Resolution

If a task requires changes spanning multiple scopes (e.g. adding a new primitive that touches `abi/cad_kernel.h`, `kernel-zig/src/main.zig`, and `web-app/src/types/cad.ts`):
1. **`cad-architect`** first defines and commits the C ABI specification in `abi/cad_kernel.h`.
2. **`zig-brep-topo`** or **`zig-solver-math`** implements the internal algorithmic logic.
3. **`zig-tess-wasm`** exposes the zero-copy C-ABI/WASM export and compiles `cad_kernel.wasm`.
4. **`oracle-fuzzer-qa`** validates the implementation against the differential oracle.
5. **`threejs-ui-worker`** binds the transferred typed array buffers to Three.js `BufferGeometry`.

---

## 3. Standardized Agent Handoff Protocol

Whenever an agent finishes an assigned task or reaches a milestone:
1. **Execute Pre-Yield Verification Skill:**
   - Zig kernel changes $\rightarrow$ Run `.agents/skills/verify-zig-wasm/` (asserts zero memory leaks and clean compilation).
   - Algorithmic or solver changes $\rightarrow$ Run `.agents/skills/run-oracle-diff/` (asserts $\Delta \le 10^{-7}\text{ mm}$ and Euler-Poincaré invariants).
   - Web application or worker changes $\rightarrow$ Run `.agents/skills/verify-web-viewport/` (asserts 60 FPS and sub-shape picking).
2. **Update Status History:**
   - Append a structured entry to `.antigravity/history/<wave>-status.md` documenting:
     - Timestamp and Agent ID
     - Files modified
     - Verification command and exit code
     - Observed metrics (memory leaks, geometric delta, frame times)
3. **Yield with Summary:**
   - Emit a structured summary message back to the orchestrator before terminating.
