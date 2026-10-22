import { loadWasmModule } from './loader.js';
export class OpenCadFeaFlexure {
    exports;
    constructor(exports) {
        this.exports = exports;
    }
    static async create(wasmInput) {
        const { exports } = await loadWasmModule(wasmInput);
        return new OpenCadFeaFlexure(exports);
    }
    generateBoxMesh(dx, dy, dz, nx, ny, nz) {
        const elCount = this.exports.cad_fea_generate_box_mesh
            ? this.exports.cad_fea_generate_box_mesh(dx, dy, dz, nx, ny, nz)
            : 0;
        const nodeCount = this.exports.cad_fea_get_node_count ? this.exports.cad_fea_get_node_count() : 0;
        return { nodeCount, elementCount: elCount };
    }
    calcBladeStiffness(length, width, thickness, youngsModulus) {
        return this.exports.cad_flexure_calc_blade_stiffness
            ? this.exports.cad_flexure_calc_blade_stiffness(length, width, thickness, youngsModulus)
            : 0;
    }
    calcNotchCompliance(width, minThickness, notchRadius, youngsModulus) {
        return this.exports.cad_flexure_calc_notch_compliance
            ? this.exports.cad_flexure_calc_notch_compliance(width, minThickness, notchRadius, youngsModulus)
            : 0;
    }
}
//# sourceMappingURL=fea_flexure.js.map