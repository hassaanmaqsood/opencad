import { loadWasmModule } from './loader.js';
export class OpenCadCore {
    exports;
    constructor(exports) {
        this.exports = exports;
        if (this.exports.cad_kernel_init) {
            this.exports.cad_kernel_init();
        }
    }
    static async create(wasmInput) {
        const { exports } = await loadWasmModule(wasmInput);
        return new OpenCadCore(exports);
    }
    generateBox(width, height, depth) {
        if (!this.exports.cad_wasm_generate_box || !this.exports.cad_wasm_get_positions_ptr)
            return null;
        this.exports.cad_wasm_generate_box(width, height, depth);
        const mem = this.exports.memory.buffer;
        const posPtr = this.exports.cad_wasm_get_positions_ptr();
        const posLen = this.exports.cad_wasm_get_positions_len ? this.exports.cad_wasm_get_positions_len() : 0;
        const nrmPtr = this.exports.cad_wasm_get_normals_ptr ? this.exports.cad_wasm_get_normals_ptr() : 0;
        const nrmLen = this.exports.cad_wasm_get_normals_len ? this.exports.cad_wasm_get_normals_len() : 0;
        const idxPtr = this.exports.cad_wasm_get_indices_ptr ? this.exports.cad_wasm_get_indices_ptr() : 0;
        const idxLen = this.exports.cad_wasm_get_indices_len ? this.exports.cad_wasm_get_indices_len() : 0;
        return {
            positions: new Float32Array(mem, posPtr, posLen).slice(),
            normals: new Float32Array(mem, nrmPtr, nrmLen).slice(),
            indices: new Uint32Array(mem, idxPtr, idxLen).slice(),
        };
    }
}
//# sourceMappingURL=core.js.map