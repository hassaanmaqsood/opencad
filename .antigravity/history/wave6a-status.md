# Wave 6A Status: Standalone Core Packaging & Universal Plugin Extension ABI

**Timestamp:** 2026-10-22  
**Agent ID:** `cad-architect`, `zig-brep-topo`, `zig-tess-wasm`, `oracle-fuzzer-qa`  
**Status:** Certified & Hardened  

---

## 1. Frozen C ABI & Extension VTable Specification (`abi/cad_kernel.h`)

Core B-Rep, 2D/3D Solver, Feature DAG, Topological Naming, and STEP AP214 signatures are permanently frozen. Future companion workbenches (Sheet Metal, FEA, Flexures, nTop Implicit, CAM/3MF, 2D HLR) extend the DAG without modifying `abi/cad_kernel.h`:

```c
typedef struct cad_kernel_limits_s {
    uint64_t max_wasm_memory_bytes; /**< Max dynamic heap allocation in bytes (default: 256 MiB) */
    uint32_t max_solver_iterations;  /**< Max iterations for 2D/3D non-linear solvers (default: 500) */
    uint32_t max_boolean_faces;      /**< Max faces allowed in boolean intersection operands (default: 100000) */
    uint32_t eval_timeout_ms;        /**< Max execution wall-clock timeout per operation in ms (default: 5000) */
} cad_kernel_limits_t;
typedef cad_kernel_limits_t CadKernelLimits;

typedef struct cad_plugin_op_vtable_s {
    uint32_t op_type_id;             /**< Unique custom operation identifier (>= 1000) */
    const char* op_name;             /**< Human-readable operation name */

    cad_status_t (*evaluate_fn)(
        uint32_t op_type_id,
        const cad_feature_node_t* node,
        const cad_solid_handle_t* input_solids,
        uint32_t input_count,
        cad_solid_handle_t* out_solid
    );

    cad_status_t (*tessellate_fn)(
        cad_solid_handle_t solid,
        double chordal_tol,
        double angular_tol,
        cad_tessellated_solid_slice_t* out_slice
    );

    cad_status_t (*serialize_ast_fn)(
        const cad_feature_node_t* node,
        char* out_buf,
        size_t buf_size,
        size_t* out_written
    );

    void (*free_fn)(cad_solid_handle_t solid);
} cad_plugin_op_vtable_t;
typedef cad_plugin_op_vtable_t CadPluginOpVTable;

cad_status_t cad_register_plugin_op(const cad_plugin_op_vtable_t* vtable);
cad_status_t cad_unregister_plugin_op(uint32_t op_type_id);
cad_status_t cad_execute_plugin_op(...);
cad_status_t cad_set_kernel_limits(const cad_kernel_limits_t* limits);
cad_status_t cad_get_kernel_limits(cad_kernel_limits_t* out_limits);
void* cad_shared_alloc(size_t size);
void cad_shared_free(void* ptr, size_t size);
```

---

## 2. Dynamic Plugin Registry & Resource Sandbox (`kernel-zig/`)

- Implemented dynamic plugin registry in `kernel-zig/src/topo/plugin_registry.zig` supporting up to 128 registered plugin VTables.
- Removed legacy fallback defaults in `kernel-zig/src/router.zig`; all operations initialize natively to `.NativeZig`.
- Exported `cad_shared_alloc` and `cad_shared_free` backed by `std.mem.Allocator` with strict `CadKernelLimits` enforcement.
- Integrated plugin evaluation dispatch directly into `cad_dag_evaluate` for custom node types $\ge 1000$.

---

## 3. Standalone Core SDK (`packages/core-sdk/`)

- **Package:** `@open-cad/core` (v0.1.0)
- **Zero JS Dependencies:** Works natively in Browser, Web Workers, Node.js, Bun, and CLI environments.
- **WASM Footprint:** Compiled with `-Doptimize=ReleaseFast -Dstrip=true` to **442 KiB** (`cad_core.wasm`), well below the 1.8 MiB budget.
- **Artifacts:**
  - `dist/index.js`, `dist/index.d.ts`
  - `dist/kernel.js`, `dist/kernel.d.ts` (Clean OOP wrapper `OpenCadKernel`)
  - `dist/loader.js`, `dist/loader.d.ts` (Universal WebAssembly loader)
  - `dist/types.js`, `dist/types.d.ts` (Full TypeScript definitions)

---

## 4. Adversarial Fuzzing & Hardening (`tests/test_adversarial_fuzz.zig`)

- **Adversarial STEP Fuzzer:** Fed empty strings, corrupted headers, binary garbage, circular entity graphs, and 500 pseudo-random mutated byte streams into `cad_wasm_step_import`.
  - Result: 0 panics, 0 crashes, 0 memory leaks (`std.testing.allocator`). All malformed inputs safely rejected with handle `0`.
- **Degenerate Singular Sketches:** Solved zero-length lines and contradictory horizontal/vertical/distance constraints.
  - Result: Correctly detected `solve_state` as `.Conflicting`/`.OverConstrained` with zero NaNs or division-by-zero crashes.
- **Resource Sandboxing:** Verified memory limit bounds enforcement via `cad_set_kernel_limits`. Allocations exceeding limits safely rejected with `null`.
- **ReleaseSafe Verification:** Certified all 13 test suites running under `ReleaseSafe` optimization with integer overflow and bounds checks enabled.
