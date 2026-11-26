# OpenCAD Architecture & Technical Reference

OpenCAD is an open-source computational engineering and parametric CAD platform. It combines a zero-primitive mathematical kernel, CDML v1.0, a shared WebAssembly memory map, and SDKs for TypeScript, Python, and Rust.

## 1. System Topology & Layered Architecture

```text
+---------------------------------------------------------------------------------------+
|                        User Interfaces & Polyglot Surface SDKs                        |
|   +-------------------------+   +-----------------------+   +---------------------+   |
|   |  Responsive Flex Studio |   |  Minimal Embed Viewer |   |  4-Step Surface SDK |   |
|   |  (Live CDML Editor +    |   |  (<opencad-viewer> &  |   |  TypeScript / Node  |   |
|   |   3D Viewport + lil-gui)|   |   ?embed=true&gui=...) |   |  Python (wasmtime)  |   |
|   +-------------------------+   +-----------------------+   +---------------------+   |
+-------------------------------------------+-------------------------------------------+
                                            |
                         CDML v1.0 Declarative XML & Fast Var RPC
                    (cdml_eval_document, cdml_set_var, cdml_get_probe_value)
                                            |
+-------------------------------------------v-------------------------------------------+
|                     Single Shared WebAssembly Memory (8 MiB–32 MiB)                   |
|   +-------------------------------------------------------------------------------+   |
|   | 0x000000: ControlBlock (64B: Magic "OCAD" 0x4F434144, Version 2, GenCounter)  |   |
|   | 0x001000: Solid Arena        (0x001000 .. 0x0F0000)                           |   |
|   | 0x0F0000: Tessellation Buf   (0x0F0000 .. 0x1F0000: 128B Header + <=1MiB Data)|   |
|   | 0x1F0000: Voxel Field Buffer (0x1F0000 .. 0x3F0000: 3D Scalar/Vec3 FEA Fields)|   |
|   | 0x3F0000: STEP Scratch Buf   (0x3F0000 .. 0x4F0000: Welded AP214 CLOSED_SHELL)|   |
|   | 0x4F0000: STL Scratch Buf    (0x4F0000 .. 0x5F0000: Binary / ASCII STL)       |   |
|   | 0x600000: WASM Global & Heap (>0x600000: Dynamic >1MiB Tess Spillover Heap)   |   |
|   +-------------------------------------------------------------------------------+   |
|                      ^                                         ^                      |
|                      | Zero-Copy Read/Write                    | Zero-Copy Field I/O  |
|                      v                                         v                      |
|   +---------------------------------------+   +-----------------------------------+   |
|   |           cad_kernel.wasm             |   |      ext_field_canary.wasm        |   |
|   |  - 18-Function Pure-Math C-ABI        |   |  - Secondary WASM Extension       |   |
|   |  - CDML v1.0 Compiler & Evaluator     |   |  - Populates 3D Voxel Fields at   |   |
|   |  - Householder QR Constraint Solver   |   |    0x1F0000 in Shared Memory      |   |
|   |  - SE(3) Sweep, NURBS Loft, Shell     |   |  - Sampled via Opcode 0x40        |   |
|   |  - Analytic Region & Rolling Fillet   |   |    field_scalar(slot,x,y,z,def)   |   |
|   |  - Interval Octree QEF Dual Contour   |   +-----------------------------------+   |
|   |  - Straddling-Triangle CSG & TopoIds  |                                           |
|   +---------------------------------------+                                           |
+-------------------------------------------+-------------------------------------------+
                                            |
                      Transferable TypedArrays & Three.js BufferGeometry
                                            |
+-------------------------------------------v-------------------------------------------+
|                                  Three.js Viewport                                    |
|   - Zero-Copy BufferGeometry Binding (Float32Array positions, normals, indices)       |
|   - Deduplicated Feature-Edge Outline Extraction (dot(n_u, n_v) < 0.995)              |
|   - Fault-Tolerant Live Editing (retains last valid mesh on assertion/syntax errors)  |
|   - Declarative lil-gui Filtering (data-gui-vars, data-gui-probes, data-gui-exports)  |
+---------------------------------------------------------------------------------------+
```

## 2. Shared Memory Layout & 18-Function Pure-Math C-ABI

### 2.1 Deterministic Shared Memory Map (`kernel-zig/src/memory_map.zig`)

All WASM modules share a single `WebAssembly.Memory({ initial: 128, maximum: 512, shared: true })` instance. The kernel pins fixed regions below `wasm.global_base = 0x600000`:

| Offset Range | Constant | Purpose |
| :--- | :--- | :--- |
| `0x000000 .. 0x000040` | `CONTROL_BLOCK_OFFSET` | 64-byte `ControlBlock` with `magic = 0x4F434144` (`"OCAD"`), `version = 2`, buffer offsets, and `tess_generation_counter`. |
| `0x001000 .. 0x0F0000` | `SOLID_ARENA_OFFSET` | Persistent solid metadata arena. |
| `0x0F0000 .. 0x1F0000` | `TESS_BUFFER_OFFSET` | 128-byte header at `0x0F0000` plus inline payload at `0x0F0080..0x1F0000`. Payloads over $1\text{ MiB}$ spill onto the heap above `0x600000`. |
| `0x1F0000 .. 0x3F0000` | `FIELD_BUFFER_OFFSET` | 3D voxel scalar and vector field slots (`field_count`, grid dimensions, world origin, voxel size, and `f32` arrays). |
| `0x3F0000 .. 0x4F0000` | `STEP_EXPORT_OFFSET` | ISO-10303-21 AP214 STEP output buffer (`get_step_ptr`, `get_step_len`). |
| `0x4F0000 .. 0x5F0000` | `STL_EXPORT_OFFSET` | Binary and ASCII STL output buffer (`get_stl_ptr`, `get_stl_len`). |
| `>= 0x600000` | `HEAP_BASE_OFFSET` | WASM global base and Tier 2 dynamic tessellation spillover heap (`dynamic_tess_buf`) for meshes above `21,842` triangles. |

### 2.2 The 18 Canonical Pure-Math C-ABI Functions (`kernel-zig/src/main_wasm.zig`)

The Zero-Primitive Mathematical Kernel Law forbids hardcoded primitive exports such as `box` or `cylinder`. The kernel synthesizes all geometry through 18 C-ABI entry points:

1. **Lifecycle & Expressions (`autodiff.zig`):**
   - `kernel_init() -> void`
   - `expr_compile(src_ptr, src_len) -> u64`
   - `expr_eval(expr_h, vars_ptr, var_count, grad_out_ptr) -> f64`
   - `expr_free(expr_h) -> void`
2. **Nonlinear Constraint Solver (`constraint_sys.zig`):**
   - `sys_create() -> u32`
   - `sys_add_var(sys_h, initial_val) -> u32`
   - `sys_add_residual(sys_h, expr_h) -> void`
   - `sys_solve(sys_h, tol, max_iter) -> u32`
   - `sys_get_dof(sys_h) -> i32`
3. **Parametric Curves & Wires (`curve_wire.zig`):**
   - `curve_nurbs_eval(deg, ctrl_ptr, n_ctrl, knots_ptr, u, out_pt_ptr) -> void`
   - `wire_assemble(curve_handles_ptr, count) -> u64`
4. **Differential & Implicit Solid Operators (`surface_brep.zig`, `implicit_field.zig`):**
   - `solid_kinematic_sweep(wire_h, se3_expr_h, cap_ends) -> u64`
   - `solid_tensor_loft(wire_handles_ptr, count, deg_v) -> u64`
   - `solid_envelope_fillet(solid_h, edge_pred_expr_h, radius_expr_h) -> u64`
   - `solid_offset_shell(solid_h, face_pred_expr_h, offset_dist) -> u64`
   - `solid_implicit_field(scalar_expr_h, bbox_ptr) -> u64`
   - `solid_boolean(bool_op, solid_a, solid_b) -> u64`
   - `solid_free(solid_h) -> void`
5. **Zero-Copy Tessellation, Export & Telemetry (`tess_export.zig`):**
   - `solid_tessellate(solid_h, chord_tol, angle_tol) -> void`
   - `solid_export_step(solid_h) -> usize`
   - `solid_export_stl(solid_h, binary) -> usize`
   - `solid_eval_probe(solid_h, probe_type, pred_expr_h, qty_expr_h) -> f64`

## 3. Core Mathematical Subsystems

### 3.1 Forward-Mode AD, Vector Scalarisation & Interval Arithmetic (`kernel-zig/src/autodiff.zig`)
- **Compile-Time Vector Scalarisation:** The compiler expands `vec2`, `vec3`, `dot`, `cross`, and `norm` into scalar Static Single Assignment (SSA) bytecode.
- **Exact Dual-Number Differentiation:** The evaluator computes exact first-order partial derivatives $\nabla F(\mathbf{x})$ for constraint solving, surface normals, and trilinear voxel interpolation.
- **Interval Arithmetic (`evalInterval`):** The evaluator propagates $[a, b]$ bounds through arithmetic, transcendental functions, R-functions, and 3D voxel lattices.

### 3.2 Rank-Revealing Householder QR Constraint Solver (`kernel-zig/src/constraint_sys.zig`)
- Decomposes the Jacobian matrix via Householder QR with column pivoting ($J P = Q R$, CDML §6.2).
- Computes numerical rank $r = |\{i : |R_{ii}| > 10^{-10}\}|$ and $\text{DOF} = N - r$.
- Classifies each constraint system into `SOLVED`, `UNDER`, `OVER`, or `CONFLICTING`.
- Computes minimum-norm Gauss-Newton steps with homotopy sub-stepping when step size exceeds 25% of the bounding box.

### 3.3 Analytic Regions, $SE(3)$ Sweeps, Lofts, Shells & Fillets (`kernel-zig/src/surface_brep.zig`)
- **Analytic Region B-Rep (`constructAnalyticRegionBrep`):**
  - Checks boundedness along $\pm X, \pm Y, \pm Z$ and finds interior seed points via an interval-arithmetic octree search.
  - Performs cylindrical ray-bisection, tags every face with its `<ineq>` `h64` hash, and checks Euler–Poincaré closure ($V - E + F - 2(S - G) = 0$).
- **General $SE(3)$ Kinematic Sweep (`buildSweptSolid`):**
  - Evaluates Rodrigues rotation $\mathbf{R}(v)$ and translation $\mathbf{d}(v)$ across outer and hole wire loops simultaneously.
  - Triangulates end caps with holes via ear-clipping and checks $\min_{u,v} \|\partial\mathbf{S}/\partial u \times \partial\mathbf{S}/\partial v\| > 0$ (`ERR_SWEEP_SELF_INTERSECT`).
- **Tangent Rolling-Ball Fillets (`filletSweptSolid`):**
  - Sweeps constant-radius rolling-ball fillets along lateral and cap boundary edges.
  - Checks $r \cdot \kappa_{\text{edge}} < 1 - \epsilon_{\text{lin}}$ (`ERR_FILLET_RADIUS_COLLAPSE`) and assigns analytical curvature $\kappa_{\max} = 1/r$.
- **Bivariate Tensor-Product NURBS Loft & Thick Offset Shell:**
  - Interpolates $K \ge 2$ wire cross-sections with degree-$p_v$ B-splines and analytical surface curvatures.
  - Offsets watertight or pierced shells by perpendicular wall thickness using plane miter vectors.

### 3.4 Interval-Pruned Octree QEF Dual Contouring (`kernel-zig/src/implicit_field.zig`)
- Subdivides the domain box recursively up to `octree-depth="5"`, pruning empty or full octants via `expr.evalInterval(X, Y, Z)`.
- Finds edge zero-crossings via secant and bisection root-finding and evaluates exact Dual-Number unit normals $\hat{\mathbf{n}}_k = \nabla F / \|\nabla F\|$.
- Solves the regularized $3 \times 3$ Quadratic Error Function (QEF) and projects the dual vertex onto $F(\mathbf{x}) = 0$ via damped Newton-Gradient refinement.

### 3.5 Straddling-Triangle CSG Subdivision & 192-Bit `TopoId`s (`kernel-zig/src/surface_brep.zig`)
- **Sub-Triangle Zero-Crossing Clipping (`materializeCsgNode`):**
  - Evaluates per-vertex signed distance against the opposing solid and subdivides straddling triangles along $F(\mathbf{x}) = 0$ using 6-step secant root-finding.
  - Welds shared intersection vertices (`addWeldedCsgVertex`) to produce watertight boolean seams across cylindrical bores.
- **Deterministic 192-Bit `TopoId` (`kernel-zig/src/cdml/topo_id.zig`):**
  - Every triangle carries `[feature_hash: u64, branch_hash: u64, subshape_type: u16, topo_flags: u16, split_generation: u32]` across sweeps, fillets, shells, and booleans.

### 3.6 Welded Manifold AP214 STEP & STL Export (`kernel-zig/src/tess_export.zig`)
- **`solid_export_step`:** Welds coincident vertices within $10^{-5}\text{ mm}$ and deduplicates undirected `EDGE_CURVE` entities in `CLOSED_SHELL`.
- Deduplicates coplanar `PLANE` entities with orthogonal `AXIS2_PLACEMENT_3D` vectors and exports full meshes without face-count truncation.

## 4. Verification Gates (`./scripts/verify_gates.sh all`)

An automated 8-gate pipeline checks every commit:

| Gate | Script / Command | Verification Scope |
| :--- | :--- | :--- |
| **Gate 0** | `verify_gates.sh` | Enforces Zero-Primitive Law (`box`, `cylinder`, `sphere`, `cone`, `torus` forbidden in `kernel-zig/src/`). |
| **Gate 0B** | `verify_gates.sh` | Scans `kernel-zig/src/` for hardcoded model variable names (`flange_w`, `bore_r`, `solid_flange`) and cheat signatures. |
| **Gate 1** | `verify_gates.sh` | Checks for zero JS/TS fallback geometry generators (`THREE.BoxGeometry`) in `web-app/src/`. |
| **Gate 2** | `zig build test` | Runs all 39 native Zig test steps (199 unit tests) with `std.testing.allocator` zero-leak checks. |
| **Gate 3** | `test_wasm_blackbox.mjs` | Black-box test of the `ControlBlock` and 18-function pure-math WASM ABI. |
| **Gate 3B** | `test_cdml_compiler.mjs` | Evaluates `flange_normative.cdml`, fault-tolerant error codes (`0x0102`–`0x0402`), and randomized Acid Tests A & B. |
| **Gate 4** | `test_canary_extension.mjs` | Checks single `SharedArrayBuffer` memory and zero-copy 3D stress field modulation at `0x1F0000`. |
| **Gate 5** | Python `opencad` SDK | Checks the 4-step Python CDML builder (`cad.cdml()...evaluate()`) via `wasmtime`. |
| **Gate 6** | `npx playwright test` | Runs 6 E2E Chromium tests covering responsive layouts, fault-tolerant live CDML editing, URL embed modes, and reactive 3D updates. |
