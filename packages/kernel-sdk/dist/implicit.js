import { loadWasmModule } from './loader.js';
export class OpenCadImplicit {
    exports;
    constructor(exports) {
        this.exports = exports;
    }
    static async create(wasmInput) {
        const { exports } = await loadWasmModule(wasmInput);
        return new OpenCadImplicit(exports);
    }
    evalGyroid(x, y, z, cellSize = 10, wallThickness = 1) {
        return this.exports.cad_implicit_eval_tpms_gyroid
            ? this.exports.cad_implicit_eval_tpms_gyroid(x, y, z, cellSize, wallThickness)
            : 0;
    }
    meshSphere(radius, resolution = 16) {
        return this.exports.cad_implicit_mesh_sphere
            ? this.exports.cad_implicit_mesh_sphere(radius, resolution)
            : 0;
    }
}
//# sourceMappingURL=implicit.js.map