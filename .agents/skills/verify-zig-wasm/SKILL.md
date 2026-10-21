---
name: verify-zig-wasm
description: Runs zig build test to enforce std.testing.allocator zero-leak checks and compiles cad_kernel.wasm, verifying exported C-ABI symbols match abi/cad_kernel.h.
---

# Skill: verify-zig-wasm

## Overview
This skill compiles and verifies the native Zig kernel and WebAssembly target for `open-parametric-cad`. It guarantees that no memory leaks exist under `std.testing.allocator` and that the compiled WebAssembly binary correctly exposes the zero-copy C ABI interfaces.

## When to Use
- Whenever modifications are made to files in `kernel-zig/` (`src/`, `tests/`, or `build.zig`).
- Prior to updating `.antigravity/history/<wave>-status.md` during handoff.
- Before committing changes that touch the C ABI interface or memory management.

## Procedure
Execute the verification script from the project root:

```bash
bash .agents/skills/verify-zig-wasm/scripts/verify.sh
```

Alternatively, run each phase manually:
1. **Run Unit Tests & Leak Checks:**
   ```bash
   cd kernel-zig && zig build test --summary all
   ```
2. **Build WebAssembly Binary:**
   ```bash
   cd kernel-zig && zig build
   ```
3. **Inspect WASM Binary Footprint & Exports:**
   ```bash
   bash scripts/mcp/wasm_inspector.sh
   ```

## Acceptance Criteria
- `zig build test` reports 100% test success with 0 memory leaks.
- `cad_kernel.wasm` exists in `kernel-zig/zig-out/bin/cad_kernel.wasm`.
- All required zero-copy memory pointer and length helpers (`cad_wasm_get_positions_ptr`, `cad_wasm_get_face_ids_ptr`, etc.) are exported.
