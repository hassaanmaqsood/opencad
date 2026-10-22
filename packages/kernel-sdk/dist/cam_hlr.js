import { loadWasmModule } from './loader.js';
export class OpenCadCamHlr {
    exports;
    constructor(exports) {
        this.exports = exports;
    }
    static async create(wasmInput) {
        const { exports } = await loadWasmModule(wasmInput);
        return new OpenCadCamHlr(exports);
    }
    projectIsometric(x, y, z) {
        const cos30 = 0.86602540378;
        const sin30 = 0.5;
        return [(x - z) * cos30, y + (x + z) * sin30];
    }
}
//# sourceMappingURL=cam_hlr.js.map