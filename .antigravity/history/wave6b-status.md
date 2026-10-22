# Wave 6B Status History: Extension Host Shell, Dynamic Code-Splitting & Workbench Plugins

## Entry 1: Extension Host Shell, Code-CAD & Git-for-CAD Implementation

- **Timestamp**: 2026-10-22T13:56:00Z
- **Active Agents**:
  - `cad-architect` (ABI & packaging oversight)
  - `threejs-ui-worker` (UI shell, PluginManager, TimelineBar, TopRibbon, Code-CAD & Git-CAD UI)
  - `zig-cam-hlr` (AST parser, formatter, 3-way semantic merge in `cad_ast.wasm`)
  - `oracle-fuzzer-qa` (Bundle analysis, Playwright E2E verification)
- **Files Modified / Created**:
  - `web-app/src/core-shell/PluginTypes.ts` (Core extension plugin contracts & context)
  - `web-app/src/core-shell/PluginManager.ts` (Vite dynamic code-splitting loader & lifecycle)
  - `web-app/src/core-shell/TopRibbon.ts` (Fusion 360 / Onshape top ribbon with 7 workbench tabs)
  - `web-app/src/core-shell/TimelineBar.ts` (Bottom chronological timeline & draggable rollback scrubber)
  - `web-app/src/worker/WorkerPluginBridge.ts` (Worker-side plugin WASM mounter & AST/diff computation)
  - `web-app/src/worker/cad.worker.ts` (Integrated worker plugin message handlers & transferable diffs)
  - `web-app/src/worker/worker_bridge.ts` (Added plugin bridge asynchronous API methods)
  - `web-app/src/renderer/mesh_manager.ts` (Added 3D Boolean visual diff green/red overlay meshes)
  - `web-app/src/renderer/viewer.ts` (Exposed visual diff overlay controller)
  - `web-app/src/plugins/code-cad/index.ts` (Code-CAD side-panel, live AST token inspector, bidirectional sync)
  - `web-app/src/plugins/git-cad/index.ts` (Git-for-CAD commit history, 3D visual diff, 3-way AST merge)
  - `web-app/src/style.css` (Added styling for ribbon, timeline, and plugin side-panels)
  - `web-app/index.html` (Mounted ribbon, timeline, and plugin side-panel containers)
  - `web-app/src/main.ts` (Extension Host bootstrapper, workbench switching, bidirectional sync)
  - `web-app/tests/wave6b_plugins.spec.ts` (7 new Playwright E2E tests for dynamic plugins)
- **Verification Commands & Exit Codes**:
  - `cd web-app && npm run build` -> Exit code 0 (TypeScript compile & Vite production build)
  - `cd kernel-zig && zig build test --summary all` -> Exit code 0 (27/27 steps passed, zero leaks)
  - `cd packages/core-sdk && npm run build` -> Exit code 0 (`@open-cad/core` builds cleanly)
  - `cd packages/kernel-sdk && npm run build` -> Exit code 0 (`@open-cad/kernel-wasm` builds cleanly)
  - `cd web-app && npx playwright test` -> Exit code 0 (**24/24 tests passed** across all suites)
- **Observed Metrics**:
  - Initial load critical path payload: **1,105.6 KiB (1.08 MiB)** (well below < 2.0 MiB limit)
  - Code-CAD dynamic split chunk: **7.3 KiB** (loaded on-demand)
  - Git-for-CAD dynamic split chunk: **8.9 KiB** (loaded on-demand)
  - Companion AST WASM: **60 KiB** (`cad_ast.wasm`)
  - Three.js Viewport Throughput: Steady **>= 55–60 FPS** during multi-workbench switching and history scrubbing
  - Zero memory leaks across native Zig allocators and WebAssembly linear memory
