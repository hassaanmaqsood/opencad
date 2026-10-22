import type { CadWasmMemoryBuffers } from './types.js';
export interface CoreKernelExports {
    memory: WebAssembly.Memory;
    cad_kernel_init?: () => number;
    cad_primitive_box?: (dx: number, dy: number, dz: number, outHandle: number) => number;
    cad_wasm_generate_box?: (dx: number, dy: number, dz: number) => number;
    cad_wasm_get_positions_ptr?: () => number;
    cad_wasm_get_positions_len?: () => number;
    cad_wasm_get_normals_ptr?: () => number;
    cad_wasm_get_normals_len?: () => number;
    cad_wasm_get_indices_ptr?: () => number;
    cad_wasm_get_indices_len?: () => number;
}
export declare class OpenCadCore {
    private exports;
    constructor(exports: CoreKernelExports);
    static create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadCore>;
    generateBox(width: number, height: number, depth: number): CadWasmMemoryBuffers | null;
}
//# sourceMappingURL=core.d.ts.map