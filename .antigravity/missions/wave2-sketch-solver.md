# Mission Playbook: Wave 2 — Native Zig PlaneGCS 2D Constraint Solver & Interactive Sketcher

## Objective
Implement a fully native Zig 2D geometric constraint solver mirroring PlaneGCS, paired with an interactive Three.js 2D sketch plane overlay and constraint HUD in `web-app`.

## Responsible Agents
- **`zig-solver-math`**: Implements sparse Jacobian matrix, Newton-Raphson / Levenberg-Marquardt solver, and Rank-Revealing QR for Degrees-of-Freedom (DOF) analysis in `kernel-zig/src/solver/`.
- **`cad-architect`**: Extends `abi/cad_kernel.h` with `cad_sketch_*` C ABI methods.
- **`oracle-fuzzer-qa`**: Writes differential fuzzing suites comparing native Zig solver convergence against `oracle-harness/src/planegcs_oracle.cpp`.
- **`threejs-ui-worker`**: Implements 2D sketch plane interaction, snap grid, geometric constraint glyphs (coincident, parallel, perpendicular, tangent, distance, angle), and real-time DOF indicators in `web-app/`.

## Architectural Requirements
1. **Solver Core (`kernel-zig/src/solver/`)**:
   - Error function residuals: Points, Lines, Circles, Arcs.
   - Constraints: Coincident, Horizontal, Vertical, Parallel, Perpendicular, Tangent, Distance, Angle, Radius.
   - Solver convergence criteria: Residual norm $|F(x)| < 10^{-7}$ within 50 iterations.
   - Diagnostic DOF tracking: Under-constrained, Well-constrained, Over-constrained, Inconsistent.
2. **C ABI Contract (`abi/cad_kernel.h`)**:
   - `cad_sketch_create()`, `cad_sketch_add_point()`, `cad_sketch_add_segment()`, `cad_sketch_add_arc()`.
   - `cad_sketch_add_constraint()`, `cad_sketch_solve()`, `cad_sketch_get_dof()`.
   - Flat memory export of solved 2D wire geometry for zero-copy extrusion into 3D B-Rep solids.
3. **Verification Gate**:
   - Must pass `run-oracle-diff` comparing 100+ randomized constraint systems against PlaneGCS with $\le 10^{-7}$ coordinate deviation.
   - `verify-zig-wasm` zero-leak check via `std.testing.allocator`.
   - `verify-web-viewport` verifying interactive sketching at 60 FPS.
