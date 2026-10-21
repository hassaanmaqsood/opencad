# Workspace Guardrails & Rules

These mandatory rules govern all development, refactoring, and multi-agent operations across the `open-parametric-cad` codebase.

---

### Rule 1 (ABI Lock)
`abi/cad_kernel.h` is the authoritative single source of truth for the CAD kernel binary interface.
- No agent may alter existing struct layouts, member offsets, or function signatures without an approved coordinated change across `kernel-zig`, `oracle-harness`, and `web-app`.
- All geometry transfers between WebAssembly and the Web Worker must use flat, contiguous typed array views (`Float32Array` positions/normals, `Uint32Array` indices, and `triangle_to_face_id` maps).
- **JSON serialization of geometry buffers is strictly prohibited.** Transfer of buffer ownership across threads must always be executed via Transferable Objects (`postMessage(msg, [buffers...])`) in $O(1)$ time.

---

### Rule 2 (Differential Oracle Gate)
No native Zig geometric, topological, or constraint solver module may switch from the C-ABI wrapped C++ oracle fallback to native Zig in the feature-flag router (`kernel-zig/src/router.zig`) until:
1. The differential test harness (`oracle-harness`) verifies that maximum geometric deviation between the Zig implementation and the reference C++ oracle (OpenCASCADE / PlaneGCS) is $\le 1 \times 10^{-7}\text{ mm}$ over randomized fuzzing iterations.
2. The Euler-Poincaré topological manifold law is strictly satisfied:
   $$V - E + F - (L - F) - 2(S - G) = 0$$
   *(where $V$ is vertices, $E$ is edges, $F$ is faces, $L$ is boundary loops/holes, $S$ is closed shells, and $G$ is genus / through-holes).*

---

### Rule 3 (Deterministic Zig Memory)
Every Zig module must adhere to deterministic, leak-free memory management:
- Every public function, struct constructor, and collection must accept an explicit `std.mem.Allocator`.
- Per-feature operations must allocate scratch memory through an isolated `std.heap.ArenaAllocator` that is completely deinitialized when the operation concludes.
- Every unit test must utilize `std.testing.allocator` to assert zero memory leaks. Any test failure due to leaked bytes will immediately block integration.

---

### Rule 4 (Context Protection)
To maintain optimal context window efficiency and prevent agent context flooding:
- Never execute unbounded file dumps, unrestricted directory listings, or recursive greps across large vendor or C++ source trees.
- Always constrain searches using `rg --max-count 150` or targeted file globs.
- For inspecting C++ classes, structs, or functions, always use the targeted AST slicer tool (`scripts/mcp/cpp_ast_slicer.py`) to extract only the isolated symbol definition and its immediate signatures.
