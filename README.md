# Open Parametric CAD (`open-parametric-cad`)

High-performance, browser-based parametric B-Rep CAD engine designed around a **Zig WebAssembly Kernel**, a **C++ Differential Oracle Harness (OpenCASCADE + PlaneGCS)**, and a **Three.js Web Worker Client**.

---

## Architecture Overview

```
                                      +---------------------------------------------+
                                      |          Differential Oracle Harness        |
                                      |     (OpenCASCADE Technology + PlaneGCS)     |
                                      +---------------------------------------------+
                                                             |
                                           abi/cad_kernel.h (Zero-Copy C ABI)
                                                             |
+------------------------------------+-----------------------+---------------------+
|        Browser Frontend            |                  Zig CAD Kernel             |
|   (Three.js + Dedicated Worker)    |        (Native Test Suite + wasm32 Target)  |
|                                    |                                             |
|  - Zero-Copy Buffer Transfers      |  - Strict std.testing.allocator leak checks |
|  - O(1) Sub-Shape Face/Edge Picking|  - Dynamic Feature-Flag Router              |
|  - 60 FPS Viewport Render Loop     |  - Direct flat memory slice export          |
+------------------------------------+---------------------------------------------+
```

### Key Subsystems

1. **`abi/cad_kernel.h`**:
   Zero-copy C ABI specification. Geometry is represented as flat memory slices:
   - `positions`: `float*` (`Float32Array` $[x, y, z]$)
   - `normals`: `float*` (`Float32Array` $[nx, ny, nz]$)
   - `indices`: `uint32_t*` (`Uint32Array` $[i0, i1, i2]$)
   - `triangle_to_face_id`: `uint32_t*` (`Uint32Array` sub-shape Face ID per triangle)
   - `edge_vertices`: `float*` (`Float32Array` line segment pairs)
   - `segment_to_edge_id`: `uint32_t*` (`Uint32Array` Edge ID per segment)

2. **`kernel-zig/`**:
   Zig 0.17 CAD kernel targeting native tests and `wasm32-freestanding`.
   - All unit tests run against `std.testing.allocator` guaranteeing 0 memory leaks.
   - Built-in feature-flag router (`router.zig`) dynamically switches individual operations between C++ Oracle and Native Zig.

3. **`oracle-harness/`**:
   C++ Differential Oracle pairing OpenCASCADE Technology (OCCT) and PlaneGCS constraint solver with automated fuzzing, Hausdorff distance, volume divergence, and Euler characteristic ($V - E + F = 2$) validation.

4. **`web-app/`**:
   Vite + TypeScript + Three.js application.
   - Geometry generation offloaded to a dedicated Web Worker loading `cad_kernel.wasm`.
   - Zero-copy transferable buffers eliminate JSON serialization overhead.
   - Sub-shape face and edge picking via raycasting and O(1) `triangle_to_face_id` lookup.
   - Automated Playwright end-to-end test suite.

---

## Quick Start

### 1. Build and Test Zig Kernel
```bash
cd kernel-zig
zig build test --summary all   # Run leak-checked unit tests
zig build                      # Compile wasm32-freestanding binary
```

### 2. Build and Run Differential Oracle Harness
```bash
cd oracle-harness
mkdir -p build && cd build
cmake ..
make -j$(nproc)
./cad_differential_runner --iterations=50
```

### 3. Run Web Application
```bash
cd web-app
npm install
npm run dev                    # Start local Vite development server
npm run test                   # Run Playwright E2E test suite
```
