# OpenCAD v2.0 Architecture & Technical Reference

OpenCAD is an open-source, web-first computational engineering and parametric CAD platform engineered around a **Zero-Primitive Mathematical Kernel Law**, **CDML v1.0 (Computational Design Markup Language)**, a **Single SharedArrayBuffer Zero-Copy Memory Architecture**, and a **Polyglot 4-Step Surface SDK** across TypeScript/WebAssembly, Python (`wasmtime`), and Rust.

---

## 1. System Topology & Layered Architecture

```
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
|   | 0x0F0000: Tessellation Buf   (0x0F0000 .. 0x1F0000: Pos, Nrm, Idx, 24B TopoId)|   |
|   | 0x1F0000: Voxel Field Buffer (0x1F0000 .. 0x3F0000: 3D Scalar/Vec3 FEA Fields)|   |
|   | 0x3F0000: STEP Scratch Buf   (0x3F0000 .. 0x4F0000: Welded AP214 CLOSED_SHELL)|   |
|   | 0x4F0000: STL Scratch Buf    (0x4F0000 .. 0x5F0000: Binary / ASCII STL)       |   |
|   | 0x600000: WASM Global & Heap Base (wasm.global_base = 0x600000)               |   |
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

---

## 2. Shared Memory Layout & 18-Function Pure-Math C-ABI

### 2.1 Deterministic Shared Memory Map (`kernel-zig/src/memory_map.zig`)

All WASM modules (`cad_kernel.wasm` and secondary extensions such as `ext_field_canary.wasm`) share a single `WebAssembly.Memory({ initial: 128, maximum: 512, shared: true })` instance with fixed regions below `wasm.global_base = 0x600000`:

| Offset Range | Constant | Purpose |
| :--- | :--- | :--- |
| `0x000000 .. 0x000040` | `CONTROL_BLOCK_OFFSET` | 64-byte `ControlBlock`: `magic = 0x4F434144` (`"OCAD"`), `version = 2`, buffer offsets, `active_solid_count`, and `tess_generation_counter` (`0x001C`). |
| `0x001000 .. 0x0F0000` | `SOLID_ARENA_OFFSET` | Persistent solid metadata arena. |
| `0x0F0000 .. 0x1F0000` | `TESS_BUFFER_OFFSET` | 128-byte header (`solid_id`, `v_count`, `tri_count`, `pos_offset = 0x0F0080`, `nrm_offset`, `idx_offset`, 8-byte aligned `face_offset`, `tess_gen`, `bbox_min/max`), followed by contiguous `f32` positions, `f32` normals, `u32` triangle indices, and 24-byte `TopoId` face records. |
| `0x1F0000 .. 0x3F0000` | `FIELD_BUFFER_OFFSET` | 3D voxel scalar/vector field slots (`field_count`, slot descriptors with `grid_x/y/z`, `world_origin`, `voxel_size`, and `f32` voxel arrays). |
| `0x3F0000 .. 0x4F0000` | `STEP_EXPORT_OFFSET` | ISO-10303-21 AP214 STEP output buffer (`get_step_ptr`, `get_step_len`). |
| `0x4F0000 .. 0x5F0000` | `STL_EXPORT_OFFSET` | Binary/ASCII STL output buffer (`get_stl_ptr`, `get_stl_len`). |

### 2.2 The 18 Canonical Pure-Math C-ABI Functions (`kernel-zig/src/main_wasm.zig`)

In compliance with the **Zero-Primitive Mathematical Kernel Law**, the kernel exports zero hardcoded geometric primitives (`box`, `cylinder`, `sphere`, etc. are banned). All geometry is synthesized mathematically through 18 canonical C-ABI entry points:

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

---

## 3. Core Mathematical Subsystems

### 3.1 Forward-Mode AD, Vector Scalarisation & Interval Arithmetic (`kernel-zig/src/autodiff.zig`)
- **Compile-Time Vector Scalarisation (CDML §3.3.1):** Expands `vec2(u, v)`, `vec3(x, y, z)`, vector variables (`p0`, `e1`, `v0`), vector addition/subtraction/scaling, `dot(a, b)`, `cross(a, b)`, and `norm(a)` into pure scalar Static Single Assignment (SSA) bytecode at compile time.
- **Exact Dual-Number Differentiation:** Evaluates exact first-order analytical partial derivatives $\nabla F(\mathbf{x})$ for nonlinear constraint solving, implicit surface normals, and trilinear voxel field interpolation (`Opcode 0x40 .FieldSample`).
- **Interval Arithmetic (`evalInterval`):** Propagates rigorous $[a, b]$ bounds through arithmetic, transcendental (`sin`, `cos`, `sqrt`, `atan2`), smooth R-functions (`r_union`, `r_intersect`, `abs_smooth`), and 3D voxel lattices (enclosing all 8 trilinear cell corners plus spanned grid voxels).

### 3.2 Rank-Revealing Householder QR Constraint Solver (`kernel-zig/src/constraint_sys.zig`)
- Decomposes the sparse/dense Jacobian via **Householder QR with column pivoting** ($J P = Q R$, CDML §6.2).
- Determines numerical rank $r = |\{i : |R_{ii}| > 10^{-10}\}|$, computes $\text{DOF} = N - r$, and classifies systems into `SOLVED`, `UNDER`, `OVER`, or `CONFLICTING` (via left-nullspace residual norm $\|(Q^T \mathbf{r})[r..M]\|_\infty > \epsilon_{\text{lin}}$).
- Computes minimum-norm Gauss-Newton / Levenberg-Marquardt steps with automatic **homotopy sub-stepping** whenever $\|\Delta \mathbf{q}\|_\infty$ exceeds 25% of the parameter bounding box.

### 3.3 Analytic Regions, $SE(3)$ Sweeps, NURBS Lofts, Shells & Rolling-Ball Fillets (`kernel-zig/src/surface_brep.zig`)
- **Analytic Region B-Rep (`constructAnalyticRegionBrep`):**
  - Verifies boundedness along $\pm X, \pm Y, \pm Z$.
  - Discovers interior seed points via a fast $Z$-axis scan or a **recursive 3D Interval-Arithmetic octree search** over $[-500, 500]^3$ followed by X/Y chord-bisection centering for off-axis regions.
  - Performs cylindrical ray-bisection from $(x_c, y_c, z_c)$, tags every face with its originating `<ineq id="...">` `h64` hash, verifies 2-manifold edge pairing and Euler–Poincaré closure ($V - E + F - 2(S - G) = 0$), and caches compiled inequalities in [`RegionAnalyticalSolid`](file:///media/hassaan/x/coding/open-cad/kernel-zig/src/surface_brep.zig#L1919-L1945) for $O(1)$ CSG signed-distance queries.
- **General $SE(3)$ Kinematic Sweep (`buildSweptSolid`, `solid_kinematic_sweep`):**
  - Evaluates Rodrigues rotation $\mathbf{R}(v) = \exp(\theta(v)[\hat{\boldsymbol{\omega}}_\times])$ and translation $\mathbf{d}(v)$ across outer and inner (hole) wire loops simultaneously, triangulating end caps with holes via bridge-merging ear-clipping and checking $\min_{u,v} \|\partial\mathbf{S}/\partial u \times \partial\mathbf{S}/\partial v\| > 0$ (`ERR_SWEEP_SELF_INTERSECT`).
- **Tangent Rolling-Ball Fillets (`filletSweptSolid`, `rebuildSweepWithCapFillets`):**
  - Supports constant-radius rolling-ball fillets on straight and curved sweep-parallel lateral edges (`abs(tz) > 0.99`) as well as horizontal top/bottom cap boundary edges (`abs(tz) < 0.001`), checking $r \cdot \kappa_{\text{edge}} < 1 - \epsilon_{\text{lin}}$ (`ERR_FILLET_RADIUS_COLLAPSE`) and assigning analytical curvature $\kappa_{\max} = 1/r$.
- **Bivariate Tensor-Product NURBS Loft (`solid_tensor_loft`) & Thick Offset Shell (`solid_offset_shell`):**
  - Interpolates arbitrary $K \ge 2$ wire cross-sections with degree-$p_v$ B-splines and analytical first/second fundamental form curvatures.
  - Offsets watertight or pierced (`face_pred_expr_h != 0`) shells by exact perpendicular wall thickness using distinct-plane miter vectors and stitches boundary rim quads.

### 3.4 Interval-Pruned Octree QEF Dual Contouring (`kernel-zig/src/implicit_field.zig`)
- Subdivides the domain box recursively up to `octree-depth="5"` ($32^3$ leaf cells), pruning empty/full octants in $O(1)$ time via `expr.evalInterval(X, Y, Z)`.
- Locates edge zero-crossings via safeguarded secant/bisection root-finding, evaluates exact Dual-Number unit normals $\hat{\mathbf{n}}_k = \nabla F / \|\nabla F\|$ (emitting `ERR_IMPLICIT_GRAD_ZERO` if $\|\nabla F\| < 10^{-12}$), solves the regularized $3 \times 3$ Quadratic Error Function (QEF), projects the dual vertex onto $F(\mathbf{x}) = 0$ via **4-step damped Newton-Gradient refinement**, and computes analytical Goldman level-set curvatures ($\kappa_H, \kappa_G, \kappa_{\min}, \kappa_{\max}$).

### 3.5 Straddling-Triangle CSG Subdivision & 192-Bit `TopoId`s (`kernel-zig/src/surface_brep.zig`)
- **Sub-Triangle Zero-Crossing Clipping (`materializeCsgNode`, `clipAndEmitCsgTriangle`, `findEdgeZeroCrossing`):**
  - Evaluates per-vertex signed distance against the opposing solid (`s_cache_a`, `s_cache_b`) and subdivides straddling triangles ($1$ kept vertex $\to 1$ sub-triangle; $2$ kept vertices $\to 2$ sub-triangles) along the $F(\mathbf{x}) = 0$ curve using 6-step safeguarded secant root-finding with canonical lexicographic endpoint ordering.
  - Welds shared intersection vertices (`addWeldedCsgVertex`) to produce crisp, non-jagged boolean seams with zero protruding shards across cylindrical bores.
- **Deterministic 192-Bit `TopoId` (`kernel-zig/src/cdml/topo_id.zig`):**
  - Every triangle carries `[feature_hash: u64 (`h64` SHA-256), branch_hash: u64, subshape_type: u16, topo_flags: u16, split_generation: u32]` preserved across sweeps, fillets, shells, and CSG booleans.

### 3.6 Welded Manifold AP214 STEP & STL Export (`kernel-zig/src/tess_export.zig`)
- **`solid_export_step`:** Welds coincident vertices within $10^{-5}\text{ mm}$, deduplicates undirected `EDGE_CURVE` entities referenced with `.T.` and `.F.` in `ORIENTED_EDGE` (guaranteeing 2-manifold edge pairing in `CLOSED_SHELL`), deduplicates coplanar `PLANE` entities with orthogonal `AXIS2_PLACEMENT_3D` `ref_direction` vectors, and exports full meshes without face-count truncation.

---

## 4. Verification Gates (`./scripts/verify_gates.sh all`)

All commits are verified by an automated 8-gate anti-cheat pipeline:

| Gate | Script / Command | Verification Scope |
| :--- | :--- | :--- |
| **Gate 0** | `verify_gates.sh` | Enforces Zero-Primitive Law (`box`, `cylinder`, `sphere`, `cone`, `torus` banned in `kernel-zig/src/`). |
| **Gate 0B** | `verify_gates.sh` | Scans `kernel-zig/src/` for hardcoded model variable names (`flange_w`, `bore_r`, `solid_flange`, etc.) and cheat signatures. |
| **Gate 1** | `verify_gates.sh` | Verifies zero JS/TS fallback geometry generators (`THREE.BoxGeometry`, etc.) in `web-app/src/`. |
| **Gate 2** | `zig build test` | Runs all 39 native Zig test steps (198 unit tests) with `std.testing.allocator` zero-leak enforcement. |
| **Gate 3** | `test_wasm_blackbox.mjs` | Black-box verification of the `ControlBlock` and 18-function pure-math WASM ABI. |
| **Gate 3B** | `test_cdml_compiler.mjs` | Evaluates the normative CDML v1.0 specification (`flange_normative.cdml`), fault-tolerant error codes (`0x0102`–`0x0402`), and randomized Acid Tests A & B. |
| **Gate 4** | `test_canary_extension.mjs` | Verifies single `SharedArrayBuffer` memory and zero-copy 3D stress field modulation via `ext_field_canary.wasm` at `0x1F0000`. |
| **Gate 5** | Python `opencad` SDK | Verifies the 4-step fluent Python CDML builder (`cad.cdml()...evaluate()`) via `wasmtime`. |
| **Gate 6** | `npx playwright test` | Runs 6 E2E Chromium tests covering desktop/mobile responsive flex layouts, fault-tolerant live CDML editing, minimal URL/attribute embed modes, and reactive 3D geometry updates. |
