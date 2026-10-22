# Contributing to OpenCAD

Thank you for contributing to OpenCAD! This project adheres to strict concurrency protocols, exclusive directory write locks, and zero-memory-leak invariants.

---

## 1. Prerequisites

- **Zig 0.17** (or latest release compatible with Zig 0.13+)
- **Node.js 20+** and **npm 10+**
- **CMake 3.20+** and **OpenCASCADE Technology (OCCT 7.6+)** (for native oracle differential tests)

---

## 2. Getting Started

### Clone and Install
```bash
git clone https://github.com/open-cad/open-cad.git
cd open-cad
npm install
```

### Build the Zig WebAssembly Modules
```bash
npm run build:kernel
# Builds stripped WASM modules to web-app/public/:
# cad_core.wasm (445 KiB), cad_sheetmetal.wasm (33 KiB), cad_fea_flexure.wasm (49 KiB),
# cad_implicit_ntop.wasm (44 KiB), cad_mfg_cam.wasm (97 KiB), cad_ast.wasm (60 KiB)
```

### Run Kernel Unit & Fuzz Tests
```bash
npm run test:kernel
# Asserts 0 bytes leaked under std.testing.allocator across all 15 test suites
```

### Run Headless SDK Tests
```bash
npm run test:sdk
```

### Launch Interactive Web Application
```bash
npm run dev
# Starts Vite dev server at http://localhost:5173
```

### Run Playwright End-to-End Viewport Verification
```bash
npm run test:web
# Executes all 31 automated Playwright browser tests in headless Chromium
```

---

## 3. Architecture & Coding Invariants

1. **Memory Safety:** Every dynamic allocation in the Zig kernel must be paired with its deallocation under `std.testing.allocator`. Zero byte leaks are permitted.
2. **C ABI Stability:** The signatures in `abi/cad_kernel.h` are frozen. Custom operations must be registered via `CadPluginOpVTable`.
3. **WASM Binary Footprint:** The initial stripped `cad_core.wasm` binary must remain under 2.0 MiB.
4. **Interactive Performance:** The Three.js viewport must maintain steady 60 FPS rendering throughput during camera orbits and timeline scrubbing.
