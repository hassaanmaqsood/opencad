/**
 * @file loader.ts
 * Universal WebAssembly Loader supporting Web, Web Workers, Node.js, and Bun.
 */
import type { CadCoreWasmExports } from './types.js';
export type WasmBinarySource = string | URL | ArrayBuffer | Uint8Array | WebAssembly.Module;
export interface WasmInstanceBundle {
    instance: WebAssembly.Instance;
    module: WebAssembly.Module;
    exports: CadCoreWasmExports;
}
/**
 * Loads and instantiates the cad_core WebAssembly binary across runtime environments.
 */
export declare function loadCoreWasm(source?: WasmBinarySource, importObject?: WebAssembly.Imports): Promise<WasmInstanceBundle>;
//# sourceMappingURL=loader.d.ts.map